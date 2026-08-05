import Foundation

/// A per-run cache of the expensive stat computations the agent's tools depend on. The daily rollups
/// don't change during a run, so every scan is computed **at most once** and reused across every tool
/// call and every deep-run pass.
///
/// This is what keeps the on-device compute saturated. Two separate wins, both about idle gaps:
///
/// 1. **Memoization.** Without it, each `correlationScan` / `patternScan` / `metricsOverview` call
///    re-fetches the user's entire rollup history and re-runs the engines on the CPU while the
///    Neural Engine sits idle — and the investigator calls them every pass, up to hundreds of times.
/// 2. **Off-actor, parallel, pre-started work.** Each scan runs in its own detached task rather than
///    inline on this actor, so (a) the ten independent scans occupy every CPU core instead of one,
///    (b) the actor never blocks — a tool call for an *already-computed* scan is answered while
///    another scan is still crunching, and (c) `precompute()` can start them all BEFORE the first
///    generation, so the CPU work overlaps the model's warm-up and first tokens instead of stalling
///    a generation mid-flight. Lazily computing a scan inside the tool call that first needs it is
///    exactly the stall this exists to remove.
///
/// Memoizing the `Task` rather than the value is what makes both safe together: a lazy caller and
/// the precompute converge on the *same* run of a scan, so nothing is ever computed twice, no
/// matter which arrives first.
///
/// An `actor` so the memoization is safe under the (serial, but still async) tool calls.
actor AnalysisSubstrate {
    /// Immutable, so `nonisolated` — readable without hopping onto the actor.
    nonisolated let now: Date
    /// The shared daily series every detector runs on — WHOLE, including suspected device-swap days
    /// (see `suspectDays()`), which are flagged rather than deleted. Computed once by the
    /// orchestrator and handed in, so it isn't re-fetched here either.
    nonisolated let series: [DailySeries]
    private let provider: MetricStatsProvider

    /// The in-flight-or-finished run of each scan. `Task` rather than the bare value so concurrent
    /// callers share one computation instead of racing to duplicate it (see the type's doc).
    private var correlationJob: Task<CorrelationEngine.Scan, Never>?
    private var volatilityJob: Task<[VolatilityShift], Never>?
    private var milestonesJob: Task<[Milestone], Never>?
    private var regimesJob: Task<[RegimeShift], Never>?
    private var seasonalityJob: Task<[SeasonalSwing], Never>?
    private var allStatsJob: Task<[MetricStat], Never>?
    private var unusualDaysJob: Task<[UnusualDay], Never>?
    private var coverageJob: Task<[MetricCoverage], Never>?
    private var suspectDaysJob: Task<[Date: Int], Never>?
    private var provenanceJob: Task<[SourceChange], Never>?

    /// Scans run at the same priority as the reasoning they feed: they are on this run's critical
    /// path (a tool call waits on one), so letting them drift to background QoS would trade a CPU
    /// stall for a *longer* CPU stall.
    private static let scanPriority = TaskPriority.userInitiated

    init(provider: MetricStatsProvider, series: [DailySeries], now: Date) {
        self.provider = provider
        self.series = series
        self.now = now
    }

    /// Start every scan now, in parallel, and return immediately — the whole point is that the CPU
    /// work proceeds *while* the Neural Engine warms up and generates. Call it right after building
    /// the substrate, before the first agent session. Idempotent: a scan already started (or done)
    /// is left alone, and any tool call that beats the precompute simply joins the same task.
    func precompute() {
        _ = correlationTask()
        _ = volatilityTask()
        _ = milestonesTask()
        _ = regimesTask()
        _ = seasonalityTask()
        _ = allStatsTask()
        _ = unusualDaysTask()
        _ = coverageTask()
        _ = suspectDaysTask()
        _ = provenanceTask()
    }

    /// The days each metric changed hands between recording sources — see `ProvenanceScan`.
    ///
    /// The ground truth behind `suspectDays()`, which INFERS recalibration from several Watch vitals
    /// jumping together. That inference is a good guess and stays (it catches a firmware change that
    /// leaves the source name identical), but it is a guess; this reads what HealthKit recorded.
    func provenance() async -> [SourceChange] {
        await provenanceTask().value
    }

    /// Days on which several Watch vitals jumped at once — the device-recalibration signature.
    /// These days are **not** removed from `series`: they are a fact the agents judge (is this the
    /// body or the hardware?), surfaced on the `unusualDays` leads that carry them.
    func suspectDays() async -> [Date: Int] {
        await suspectDaysTask().value
    }

    func correlationScan() async -> CorrelationEngine.Scan {
        await correlationTask().value
    }

    func volatility() async -> [VolatilityShift] {
        await volatilityTask().value
    }

    func milestones() async -> [Milestone] {
        await milestonesTask().value
    }

    func regimes() async -> [RegimeShift] {
        await regimesTask().value
    }

    /// Annual rhythms — months that reliably run high or low against their own year. The only scan
    /// that reads the calendar rather than a rolling window, and the slowest to become answerable:
    /// it needs two years of history before it can say anything at all.
    func seasonality() async -> [SeasonalSwing] {
        await seasonalityTask().value
    }

    /// The full metric × comparison cross-product behind the overview digest (memoized `scanAll`).
    func allStats() async -> [MetricStat] {
        await allStatsTask().value
    }

    /// The every-data-point sweep: every day of every metric tested against its own robust baseline;
    /// the strangest days become the investigator's hypothesis seeds. Caches the FULL |z|-ranked
    /// pool (down to 2σ) — the tool layer bounds and pages each call's slice, so nothing is
    /// pre-truncated here.
    func unusualDays() async -> [UnusualDay] {
        await unusualDaysTask().value
    }

    /// The map of the territory itself — per-metric footprint (span, density, gaps) behind the
    /// scout's `coverage` tool.
    func coverage() async -> [MetricCoverage] {
        await coverageTask().value
    }

    // MARK: - Job accessors

    // `Task.detached` on purpose: a plain `Task {}` inside an actor inherits this actor's isolation,
    // which would run every scan *on* the actor — serializing them onto one core and blocking every
    // other tool call for the duration. Detached puts each scan on the cooperative pool, which is
    // what makes them parallel with each other and with the actor staying responsive.
    //
    // They inherit no cancellation, and — being synchronous loops with no suspension points, plus a
    // `scanAll` whose body runs straight through on the provider actor — there is nothing a
    // cancellation could interrupt even if they did. So a run stopped mid-`precompute` leaves up to
    // ten scans running to completion on a substrate nobody will read. That is a few seconds of
    // wasted CPU after a Stop, bounded by the data size, and adding cancellation machinery that
    // cannot actually stop any of them would only look like a fix. Stated plainly rather than
    // papered over: if these ever gain real suspension points, they should gain cancellation too.

    private func correlationTask() -> Task<CorrelationEngine.Scan, Never> {
        if let correlationJob { return correlationJob }
        let series = series
        let job = Task.detached(priority: Self.scanPriority) { CorrelationEngine().scan(in: series) }
        correlationJob = job
        return job
    }

    private func volatilityTask() -> Task<[VolatilityShift], Never> {
        if let volatilityJob { return volatilityJob }
        let series = series
        let now = now
        let provenance = provenanceTask()
        let job = Task.detached(priority: Self.scanPriority) {
            await VolatilityScan().scan(series, now: now, sourceChanges: provenance.value)
        }
        volatilityJob = job
        return job
    }

    private func milestonesTask() -> Task<[Milestone], Never> {
        if let milestonesJob { return milestonesJob }
        let series = series
        let now = now
        let provenance = provenanceTask()
        let job = Task.detached(priority: Self.scanPriority) {
            await MilestoneScan().scan(series, now: now, sourceChanges: provenance.value)
        }
        milestonesJob = job
        return job
    }

    private func regimesTask() -> Task<[RegimeShift], Never> {
        if let regimesJob { return regimesJob }
        let series = series
        let now = now
        let provenance = provenanceTask()
        let job = Task.detached(priority: Self.scanPriority) {
            await RegimeShiftScan().scan(series, now: now, sourceChanges: provenance.value)
        }
        regimesJob = job
        return job
    }

    private func seasonalityTask() -> Task<[SeasonalSwing], Never> {
        if let seasonalityJob { return seasonalityJob }
        let series = series
        let now = now
        let job = Task.detached(priority: Self.scanPriority) { SeasonalityScan().scan(series, now: now) }
        seasonalityJob = job
        return job
    }

    private func allStatsTask() -> Task<[MetricStat], Never> {
        if let allStatsJob { return allStatsJob }
        let provider = provider
        let now = now
        let job = Task.detached(priority: Self.scanPriority) {
            await (try? provider.scanAll(now: now)) ?? []
        }
        allStatsJob = job
        return job
    }

    private func suspectDaysTask() -> Task<[Date: Int], Never> {
        if let suspectDaysJob { return suspectDaysJob }
        let series = series
        let job = Task.detached(priority: Self.scanPriority) { DeviceSwapFilter.suspectDayVitals(in: series) }
        suspectDaysJob = job
        return job
    }

    private func unusualDaysTask() -> Task<[UnusualDay], Never> {
        if let unusualDaysJob { return unusualDaysJob }
        let series = series
        let now = now
        let suspects = suspectDaysTask()
        let job = Task.detached(priority: Self.scanPriority) {
            await UnusualDaysScan.scan(series: series, now: now, suspectDays: suspects.value)
        }
        unusualDaysJob = job
        return job
    }

    /// The one scan other scans wait on — volatility, milestone and regime all take its transitions
    /// so their findings can carry a device-swap caveat.
    ///
    /// It costs each of them the wait for a single indexed fetch (this scan does no arithmetic), and
    /// buys the caveat that can invalidate their finding outright. All four start inside
    /// `precompute`, so the wait overlaps the model's warm-up rather than stalling a tool call.
    ///
    /// Said once here rather than three times at the dependents: the note used to live on
    /// `regimesTask` claiming to be "the ONE scan with a dependency", which stopped being true the
    /// same day, when the caveat was extended to the other two kinds.
    private func provenanceTask() -> Task<[SourceChange], Never> {
        if let provenanceJob { return provenanceJob }
        let provider = provider
        let now = now
        let job = Task.detached(priority: Self.scanPriority) {
            // A failed fetch yields no changes, not a crash: provenance is corroborating evidence,
            // and a run must not die because the extra read failed.
            await ProvenanceScan.scan((try? provider.sourceHistory(now: now)) ?? [])
        }
        provenanceJob = job
        return job
    }

    private func coverageTask() -> Task<[MetricCoverage], Never> {
        if let coverageJob { return coverageJob }
        let series = series
        let now = now
        let job = Task.detached(priority: Self.scanPriority) {
            CoverageScan.scan(series: series, now: now)
        }
        coverageJob = job
        return job
    }

    /// The metrics with enough real history to hypothesize about — the roster the deep run's
    /// per-metric investigator rotation draws from. Order follows `series` (registry order), so the
    /// rotation is stable across passes.
    nonisolated func metricsWithData(minDays: Int = UnusualDaysScan.minSamples) -> [MetricKey] {
        series.filter { $0.values.count >= minDays }.map(\.metric)
    }
}
