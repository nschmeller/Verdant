import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Verdant

/// The two places the app used to leave the Neural Engine idle while the CPU worked:
///
///  - `AnalysisSubstrate` computed each scan lazily, *inside* the first tool call that needed it —
///    so a live generation stalled on years of rollups. It now starts every scan up front, off the
///    actor and in parallel (`precompute()`).
///  - The deep run collected HealthKit data *at* the refresh boundary, with nothing generating. It
///    now prefetches that collection a pass early so the ingest runs underneath a pass of reasoning.
///
/// These tests pin the properties that make those two changes safe: identical results either way,
/// one computation per scan no matter who asks first, and exactly one collection per boundary.
struct SubstratePrecomputeTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// Two metrics with 180 days of related-but-noisy history — enough for every scan to have real
    /// work to do (correlations, regimes, volatility, records, unusual days, coverage).
    private func series() -> [DailySeries] {
        let anchor = calendar.startOfDay(for: now)
        var steps: [Date: Double] = [:]
        var energy: [Date: Double] = [:]
        for i in 1...180 {
            let day = calendar.date(byAdding: .day, value: -i, to: anchor)!
            // A baseline step at day 90 plus a deterministic wobble, so regimes/volatility fire.
            let base = i > 90 ? 7000.0 : 10000.0
            let wobble = Double((i * 37) % 11) * 120
            steps[day] = base + wobble
            energy[day] = base / 20 + wobble / 25
        }
        // A handful of extreme days so the unusual-days pool is non-empty.
        for daysBack in [3, 17, 44] {
            steps[calendar.date(byAdding: .day, value: -daysBack, to: anchor)!] = 40000
        }
        return [
            DailySeries(metric: .stepCount, values: steps),
            DailySeries(metric: .activeEnergyBurned, values: energy)
        ]
    }

    private func makeSubstrate(_ container: ModelContainer, _ series: [DailySeries]) -> AnalysisSubstrate {
        AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: container),
            series: series,
            now: now
        )
    }

    /// Two INDEPENDENTLY built fixtures on purpose. `series()` returns dictionaries, and Swift's
    /// dictionary iteration order is not stable across separately-built dictionaries holding the
    /// same pairs — so this also pins that the scans read their days chronologically rather than in
    /// whatever order the dictionary hands them. Before that fix this comparison failed on
    /// `volatility()`: identical data, last-ULP-different standard deviations.
    @Test func `precomputing produces exactly the results lazy access would have`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let eager = makeSubstrate(container, series())
        let lazySubstrate = makeSubstrate(container, series())

        // The whole point of the change is that WHEN a scan runs must not change WHAT it returns.
        await eager.precompute()

        #expect(await eager.unusualDays() == lazySubstrate.unusualDays())
        #expect(await eager.coverage() == lazySubstrate.coverage())
        #expect(await eager.volatility() == lazySubstrate.volatility())
        #expect(await eager.milestones() == lazySubstrate.milestones())
        #expect(await eager.regimes() == lazySubstrate.regimes())
        #expect(await eager.seasonality() == lazySubstrate.seasonality())
        let eagerScan = await eager.correlationScan()
        let lazyScan = await lazySubstrate.correlationScan()
        #expect(eagerScan.pairsTested == lazyScan.pairsTested)
        #expect(eagerScan.correlations.map(\.pairKey) == lazyScan.correlations.map(\.pairKey))
        // And the fixture is actually exercising the scans, not comparing two empty lists.
        #expect(await !(eager.unusualDays()).isEmpty)

        // Seasonality needs years, so it gets its own substrate — otherwise the equality above
        // compares two empty arrays and proves nothing about the newest scan.
        let longEager = makeSubstrate(container, multiYearSeries())
        let longLazy = makeSubstrate(container, multiYearSeries())
        await longEager.precompute()
        #expect(await !(longEager.seasonality()).isEmpty)
        #expect(await longEager.seasonality() == longLazy.seasonality())
    }

    @Test func `precompute is idempotent and safe to race against a tool call`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let substrate = makeSubstrate(container, series())

        // What this DOES verify: racing a tool call against two precomputes is safe and every caller
        // sees the identical result, so no caller can observe a half-built scan.
        //
        // What it does NOT verify, despite an earlier version of this comment implying otherwise:
        // that only ONE scan ran. Memoizing the `Task` rather than the value is what makes a racing
        // caller JOIN the in-flight scan instead of starting a second, and that is the property the
        // substrate exists for — a duplicated scan is pure CPU spent while the Neural Engine waits.
        // But the scans are deterministic and pure, so a duplicate produces an identical result and
        // equality cannot tell the two apart. Nor can timing: unmemoized scans would run
        // concurrently, so wall-clock would barely move.
        //
        // Observing it would need a counter inside the substrate, i.e. test-only state in production
        // code — worse than the gap. Recorded here rather than papered over.
        async let first = substrate.unusualDays()
        await substrate.precompute()
        await substrate.precompute()
        async let second = substrate.unusualDays()
        async let third = substrate.unusualDays()

        let results = await [first, second, third]
        #expect(results[0] == results[1])
        #expect(results[1] == results[2])
        #expect(!results[0].isEmpty)
    }

    /// Three years of one metric with a real January/July swing. The 180-day fixture above is
    /// deliberately short, and `SeasonalityScan` needs two years before it will speak at all — so
    /// reusing it would have made every seasonal assertion below quietly vacuous.
    private func multiYearSeries() -> [DailySeries] {
        let anchor = calendar.startOfDay(for: now)
        var values: [Date: Double] = [:]
        for i in 1...1100 {
            let day = calendar.date(byAdding: .day, value: -i, to: anchor)!
            let month = calendar.component(.month, from: day)
            let seasonal = month == 1 ? 8.0 : (month == 7 ? -8.0 : 0)
            values[day] = 60 + seasonal + Double(i % 3) - 1
        }
        return [DailySeries(metric: .restingHeartRate, values: values)]
    }

    /// Every anchored scan must use the SUBSTRATE'S clock, not the wall clock.
    ///
    /// `now` is defaulted to `.now` on every scan signature, so omitting it at one of the ten call
    /// sites in `AnalysisSubstrate` compiles silently. The consequence is not a crash: that one
    /// detector anchors on today while the rest anchor on the run's `now`, so a deep run whose
    /// context is hours old — or any run at all, once the two cross a midnight — reports days-ago
    /// figures from two different calendars. The agent then reads "3 days ago" and "20 days ago"
    /// about the same day and has no way to tell.
    ///
    /// Observable rather than scanned: the fixture's `now` is a fixed past date, so a scan that
    /// reached for the wall clock would place these days weeks further back.
    @Test func `every scan anchors on the substrate's clock, not today`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let substrate = makeSubstrate(container, series())
        await substrate.precompute()

        let days = await substrate.unusualDays()
        #expect(!days.isEmpty, "no strange days — the anchor check would be vacuous")
        // The fixture's extremes sit 3, 17 and 44 days before the INJECTED now. Anchored on the real
        // clock they would all be far older, since `now` here is a hard-coded past date.
        let newest = days.map(\.daysAgo).min() ?? .max
        #expect(newest < 10, "newest strange day is \(newest) days ago — anchored on the wall clock?")

        // For the window-based detectors, "it fired at all" is too weak to notice a slipped anchor:
        // a wall clock only a couple of weeks ahead still overlaps this fixture, so they fire either
        // way. `n` is the sensitive figure — the count of observations inside the 30-day recent
        // window, which is full only when the window sits over the data.
        let volatility = await substrate.volatility()
        #expect(!volatility.isEmpty, "volatility saw an empty recent window")
        let observations = volatility.map(\.n).min() ?? 0
        #expect(observations >= 25, "recent window held only \(observations) days — slipped anchor?")
        #expect(await !(substrate.regimes()).isEmpty, "regimes saw an empty recent window")
        #expect(await !(substrate.coverage()).isEmpty)
    }

    /// The engines must be a pure function of the DATA, not of how a dictionary happened to lay it
    /// out. Anything order-sensitive here (float summation, and the unstable rank sorts whose tie
    /// order follows input order) would otherwise make the same history yield different numbers —
    /// and a different set of candidates past the tools' caps — between two runs.
    @Test func `the scans are deterministic across independently built series`() {
        let a = series()
        let b = series()
        #expect(a == b) // equal by value…
        // …yet their dictionaries genuinely iterate differently, which is what makes this a real test.
        #expect(a[0].values.map(\.value) != b[0].values.map(\.value))

        #expect(VolatilityScan().scan(a, now: now) == VolatilityScan().scan(b, now: now))
        #expect(UnusualDaysScan.scan(series: a, now: now) == UnusualDaysScan.scan(series: b, now: now))
        #expect(RegimeShiftScan().scan(a, now: now) == RegimeShiftScan().scan(b, now: now))
        #expect(MilestoneScan().scan(a, now: now) == MilestoneScan().scan(b, now: now))
        #expect(CoverageScan.scan(series: a, now: now) == CoverageScan.scan(series: b, now: now))
        #expect(DeviceSwapFilter.suspectDays(in: a) == DeviceSwapFilter.suspectDays(in: b))
        // Seasonality buckets by (year, month) through dictionaries and picks extremes with
        // `max(by:)` — the order-sensitive shape this test exists for. Its own multi-year fixture,
        // because the 180-day one cannot produce a rhythm at all.
        //
        // Honest limitation: this asserts the property but does not currently DISTINGUISH the
        // scan's `keys.sorted()` calls from unordered iteration. Removing them was tried and the
        // test still passed — the year and (year, month) keys are Ints, and two Int-keyed
        // dictionaries built the same way iterate the same way, unlike the `[Date: Double]` series
        // above (which is why that one is asserted to differ). The sorts stay as defence against a
        // hashing or capacity change making that untrue; they are not proven necessary here.
        let yearsA = multiYearSeries()
        let yearsB = multiYearSeries()
        #expect(yearsA[0].values.map(\.value) != yearsB[0].values.map(\.value))
        let seasonalA = SeasonalityScan().scan(yearsA, now: now)
        let seasonalB = SeasonalityScan().scan(yearsB, now: now)
        #expect(!seasonalA.isEmpty, "the multi-year fixture produced no rhythm — check would be vacuous")
        #expect(seasonalA == seasonalB)
        let scanA = CorrelationEngine().scan(in: a)
        let scanB = CorrelationEngine().scan(in: b)
        #expect(scanA.correlations.map(\.pairKey) == scanB.correlations.map(\.pairKey))
        #expect(scanA.correlations.map(\.r) == scanB.correlations.map(\.r))
    }
}

/// The deep run's collection arm. Separate struct so the (slower) multi-pass integration run
/// doesn't sit alongside the fast pure-substrate checks above.
struct DeepRunCollectionTests {
    @Test func `the refresh boundary joins the prefetched collection instead of collecting again`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let collections = Mutex(0)
        let sawRefresh = Mutex(false)
        let runBox = Mutex<Task<Void, Never>?>(nil)

        var orchestrator = Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: FakeSubagents(),
            capability: { .available }
        )
        orchestrator.collector = { _ in collections.withLock { $0 += 1 } }

        // End the indefinite loop the instant it finishes its FIRST refresh boundary, so exactly one
        // boundary is crossed and the collection count is unambiguous.
        let reporter = ProgressReporter { snapshot in
            guard snapshot.activity.hasPrefix("Refreshed the substrate") else { return }
            sawRefresh.withLock { $0 = true }
            runBox.withLock { $0 }?.cancel()
        }
        let run = Task {
            _ = await orchestrator.runDiscovery(
                now: now,
                // A generous backstop only — the reporter above is what actually ends the run.
                deadline: ContinuousClock.now.advanced(by: .seconds(60)),
                exhaustive: true,
                progress: reporter
            )
        }
        runBox.withLock { $0 = run }
        await run.value

        #expect(sawRefresh.withLock { $0 }) // the run really did cross a boundary
        // Exactly one: the prefetch launched a pass early and the boundary JOINED it. Two would mean
        // the boundary re-collected and threw the prefetch away; zero would mean the refresh rebuilt
        // the substrate from rollups nothing had refreshed.
        #expect(collections.withLock { $0 } == 1)
    }

    /// The prefetch is an UNSTRUCTURED task, so the enclosing run's cancellation does not reach it —
    /// the loop's `defer` has to tear it down by hand. Nothing else in the suite would notice if
    /// that `defer` were dropped, and the consequence is a HealthKit ingest still running after the
    /// user pressed Stop.
    @Test func `stopping the run tears down its prefetched collection`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let probe = CollectionProbe()
        var orchestrator = Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: FakeSubagents(),
            capability: { .available }
        )
        orchestrator.collector = { _ in await probe.runUntilCancelled() }

        let run = Task {
            _ = await orchestrator.runDiscovery(
                deadline: ContinuousClock.now.advanced(by: .seconds(60)), exhaustive: true
            )
        }
        // Wait for the prefetch to actually launch (it fires on the pass before the first refresh
        // boundary), then stop the run the way the user's Stop button does.
        var waited = 0
        while !probe.started, waited < 600 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(probe.started)
        run.cancel()
        await run.value

        // Cancelled AND joined: `narrate` promises the run gate is released only once the work has
        // truly stopped, so the loop must not return while a cancelled ingest is still unwinding.
        // `runDiscovery` has returned by now, so a still-running probe would mean it did.
        #expect(probe.cancelled)
        #expect(probe.finished)
    }
}

/// Stands in for the HealthKit ingest: reports when it started and whether it was cancelled.
private final class CollectionProbe: Sendable {
    private struct State {
        var started = false
        var cancelled = false
        var finished = false
    }

    private let state = Mutex(State())

    var started: Bool {
        state.withLock { $0.started }
    }

    var cancelled: Bool {
        state.withLock { $0.cancelled }
    }

    /// Whether it actually finished unwinding — the run must have waited for this.
    var finished: Bool {
        state.withLock { $0.finished }
    }

    /// Blocks like a long backfill would, and records the cancellation when it arrives.
    func runUntilCancelled() async {
        state.withLock { $0.started = true }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            state.withLock { $0.cancelled = true }
        }
        state.withLock { $0.finished = true }
    }
}
