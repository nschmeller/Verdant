import Foundation
import OSLog
import SwiftData

/// The per-run context threaded through every discovery track — bundles the values shared by all of
/// them so each track's signature stays to (context, limit, series).
nonisolated struct DiscoveryContext {
    let jobID: UUID
    /// `var`: an indefinite deep run refreshes its substrate (and this anchor) every
    /// `DeepAnalysisPolicy.substrateRefreshPasses` passes, so hours-long runs don't reason over a
    /// frozen snapshot or a stale day boundary.
    var now: Date
    let deadline: ContinuousClock.Instant?
    let progress: ProgressReporter?
    /// Per-run stat cache shared by the investigator's tools, so a tool call reuses a scan instead of
    /// re-crunching years of rollups every pass (keeps the Neural Engine reasoning, not idling). `nil`
    /// only in the test-only scrutiny context, which never runs discovery.
    var substrate: AnalysisSubstrate?
    /// When true — always, in production — every surfaced finding must additionally survive a panel
    /// of skeptic subagents before it is persisted. The flag exists only so tests can isolate the
    /// rest of the pipeline from the skeptic gate; no production path turns it off.
    var adversarial = false
    /// The run's rejected-hypothesis memory (`let` with a default, so the memberwise init callers
    /// don't name it; the actor reference is shared by every copy of this context).
    let ledger = RunLedger()
}

/// The thin launcher for an **agentic workflow that calls logical tools** — not a logical workflow
/// that calls agents. It owns **no** `LanguageModelSession`; every session is an ephemeral leaf inside
/// a `Subagents` call, keeping the whole machine inside the ~4k-token reality.
///
/// Every finding is a product of on-device intelligence, and every DECISION is the agent's — there are
/// no deterministic worth/materiality/safety guards, only deterministic *stats* the agent reads via
/// tools. One run, in order:
///  1. **Cross-source correlations** — the `CorrelationEngine` produces the numbers; the model judges
///     whether each is worth telling and phrases it. The premium finding type.
///  2. **Agentic investigation** — one investigator agent drives the stat tools (`metricStats`,
///     `correlationScan`, `patternScan`, `metricsOverview`) itself and proposes single-metric findings;
///     the AUDITABLE numbers are resolved from source at persist time — the agent names a metric and
///     a comparison, never a figure, so the verified line under a card cannot be invented. Its PROSE
///     is free text and does state figures: that is the app's live hallucination surface, which is
///     why `NumericFidelity` reparses every figure in the prose against the verified values and
///     hands the mismatches to the skeptics. This line used to read "the agent never states a
///     number", which would have retired a worry that two subsystems exist to handle.
///  3. **Curation** — keep the feed to a bounded budget (`maxActiveFindings`).
///
/// Every surfaced finding still passes the agent safety panel and the adversarial skeptic panel. If the
/// model is unavailable, the feed simply stays as-is until it can reason again.
nonisolated struct Orchestrator {
    let provider: MetricStatsProvider
    let writer: StoreWriter
    let embeddings: Embeddings
    let subagents: any SubagentRunning
    /// Indirection over `LLMCapability.current` so tests can force availability without a device.
    var capability: @Sendable () -> LLMCapability = { LLMCapability.current }
    /// The deep run's DATA-COLLECTION hook, called at every substrate-refresh boundary BEFORE the
    /// rebuild — wired by the composition root to a real HealthKit delta ingest + history deepening.
    /// Without it a refresh only re-reads rollups that cannot have changed mid-run (observer ingests
    /// skip while the run holds the gate), so "fold in new data" would only be true across day
    /// boundaries. `nil` for bounded/background runs, which stay as-is.
    var collector: (@Sendable (ProgressReporter?) async -> Void)?

    private static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "Orchestrator")

    /// Warm the on-device model ahead of a long, model-free stretch — the composition root calls this
    /// before the launch ingest/backfill, which is minutes of pure HealthKit and CPU work on a first
    /// run. `runDiscovery` prewarms too, but that happens *after* the collection, so without this the
    /// model would load cold at the exact moment reasoning is meant to begin. Warming across the
    /// collection turns that cold load into overlap.
    func prewarm() {
        subagents.prewarm()
    }

    // MARK: Discovery loop (background + foreground catch-up)

    /// One full discovery pass — the single job shared by the background task and the user-triggered
    /// Deep Analysis. Every finding is produced by on-device intelligence: there is no deterministic
    /// finding path. `deadline` bounds LLM work; when a `progress` reporter is attached (Deep
    /// Analysis), each step emits a snapshot. Returns the count of new findings.
    @discardableResult
    func runDiscovery(
        now: Date = .now,
        deadline: ContinuousClock.Instant? = nil,
        exhaustive: Bool = false,
        adversarial: Bool = true,
        progress: ProgressReporter? = nil
    ) async -> Int {
        let jobID = UUID()
        await progress?.apply { $0.phase = .scanning }

        // Every finding requires the model to reason and phrase it (no template fallback, no
        // deterministic findings), so there's nothing to do when the model is unavailable. Set an honest
        // closing note rather than letting the UI imply a completed "0 findings" run: nothing was
        // reasoned, so this is NOT a clean bill (same principle as the wholesale-inference-failure note).
        guard capability().isAvailable, !shouldStop(deadline) else {
            let note = capability().isAvailable
                ? "Analysis stopped before it could finish — your findings are unchanged."
                : "Couldn't run: on-device intelligence isn't available right now. Your findings are "
                + "unchanged — try again once Apple Intelligence is ready."
            await progress?.apply { $0.phase = .finished; $0.note = note }
            return 0
        }

        // Warm the model now, so it loads while we compute the (CPU-bound) series/scans below and the
        // first generation starts hot rather than cold — one fewer idle gap.
        subagents.prewarm()

        // Read every metric's daily series ONCE — WHOLE, including the days the device-swap detector
        // finds suspicious. Those days used to be deleted here before any agent could see them; now
        // they stay and the detector's verdict rides along as a flag on the `unusualDays` leads that
        // carry them, so "body event or hardware event?" is the agent's call (and the skeptic panel's
        // "measurement artifact?" lens) rather than a filter's. The substrate memoizes every scan for
        // the whole run, so the agent's tools return cached numbers instead of re-crunching each pass.
        let loaded = await Self.loadSeries(provider, now: now)
        let series = loaded.series
        let substrate = AnalysisSubstrate(provider: provider, series: series, now: now)
        // Start every scan NOW, in parallel, and don't wait: they run on the CPU while the model
        // finishes warming and generates its first tokens. Computing them lazily inside the first
        // tool call that needs one stalls a live generation on the CPU instead — the exact idle gap
        // this run exists to avoid. Returns as soon as the tasks are launched.
        await substrate.precompute()
        Self.reportPairsTested(substrate, to: progress)
        await progress?.log(loaded.note)
        // Every user-visible finding — not only deep-run ones — must clear the skeptic panel, since
        // the model's own `worthTelling` self-judgment runs over-eager.
        let ctx = DiscoveryContext(
            jobID: jobID,
            now: now,
            deadline: deadline,
            progress: progress,
            substrate: substrate,
            adversarial: adversarial
        )

        let produced: Int = if exhaustive {
            // The user-triggered Deep Analysis: reason hard and broadly, for as long as it takes.
            await runExhaustiveDiscovery(ctx)
        } else {
            // Bounded foreground/background pass — one agentic investigation over the full tool surface.
            await runInvestigation(ctx)
        }

        // Curate to the bounded, high-quality budget.
        await progress?.apply { $0.phase = .synthesizing }
        await progress?.log("Keeping only the few findings worth your attention…")
        await curate(now: now)
        // Tell a genuine clean pass apart from a wholesale inference failure (model "available" at the
        // guard, but every subsequent call errored on rate-limit/contention): `produced == 0` happens in
        // BOTH, yet only the former is a clean bill. Recording a failed run as "analyzed" or telling the
        // user their data is clean when nothing was actually reasoned is the worst failure here.
        let inferenceFailed = await progress?.inferenceWhollyFailed ?? false
        if !inferenceFailed {
            // The agent records its own state on every real (reasoning) pass, so "last analyzed" and
            // any future cross-run logic always reflect the latest genuine run.
            try? await writer.recordRun(
                mode: exhaustive ? .deep : .standard,
                findingCount: produced,
                now: now
            )
        }
        // A clean bill is only claimable when the reasoning actually ran. Wholly-failed is the
        // obvious case; a run where a quarter of the calls never answered is the quiet one, and it
        // used to read identically to a thorough pass that found nothing.
        let degraded = await progress?.inferenceWasDegraded ?? false
        // The third way `produced == 0` happens, and the one this note could not previously see.
        let unvetted = await progress?.droppedForTime ?? 0
        let closing = if inferenceFailed {
            "Couldn't finish reasoning this pass — the on-device model wasn't responding. "
                + "Your findings are unchanged; try again when your device is idle or charging."
        } else if produced > 0 {
            "\(produced) surfaced — only what cleared the bar."
        } else if unvetted > 0 {
            "\(unvetted) finding\(unvetted == 1 ? " was" : "s were") proposed but the pass ran out "
                + "of time to check them — not a clean bill. They aren't recorded as rejected, so "
                + "the next run can pick them up."
        } else if degraded {
            "Nothing new cleared the bar, but some of this pass's reasoning didn't complete — "
                + "the model was busy. Not a clean bill; it'll pick up where it left off."
        } else {
            "Nothing new rose above the noise this pass — that's a clean bill, not an empty one."
        }
        await progress?.apply { $0.phase = .finished; $0.note = closing }
        return produced
    }

    /// The inverted discovery path: launch ONE agentic investigator that drives the logical stat tools
    /// itself and returns the single-metric findings it judges worth telling; then resolve, vet, and
    /// persist each. This replaces the old Discovery → Analyst → Verify → Phrase chain — a *logical
    /// workflow that called agents* — with an *agentic workflow that calls logical tools*. Internal
    /// (not private) because the focused drill-down (`Orchestrator+Focus`) runs it with its own lenses.
    func runInvestigation(
        _ ctx: DiscoveryContext,
        lenses: [String] = Instructions.investigationLenses,
        learnable: Set<String> = []
    ) async -> Int {
        guard let substrate = ctx.substrate else { return 0 }
        await ctx.progress?.apply {
            $0.phase = .enhancing
            $0.note = "Fanning out \(lenses.count) specialist investigators — each hunting one deep angle."
        }
        // Cross-RUN steering from the persistent research journal, fetched once per investigation:
        // dead ends from PRIOR runs (the in-memory ledger only remembers this one). This is what
        // makes the research program iterate day over day instead of starting amnesiac.
        let priorRuns = await (try? writer.journalSteering(excludingRun: ctx.jobID, now: ctx.now)) ?? []
        let available = Self.availableMetricsLine(substrate)
        // Fan out a FLEET of lens-specialized investigators (serial: each at full power). Together they
        // cover far more ground than one generalist; each is blind to the others, so overlap is expected
        // and deduped below before we spend a safety+skeptic panel on any finding.
        let perLens = await concurrentMap(
            Array(lenses.enumerated()),
            maxConcurrent: EnhancementPolicy.maxConcurrentSubagents
        ) { index, lens -> (lens: String, findings: [ProposedFinding])? in
            // Honor the deadline/Stop BEFORE each session is issued (backoff only re-checks between
            // retries): a background window that expires mid-pass must yield and bank what it has,
            // not spend the rest of the OS grant on sessions whose proposals the persist gate will
            // discard anyway — and a foreground Stop must not keep starting new investigators.
            // `nil` means this angle was never actually chased, which is not the same as chasing it
            // and finding nothing — only the latter is evidence about the angle (see `barren`).
            guard !shouldStop(ctx.deadline) else { return nil }
            await ctx.progress?.log("Investigator \(index + 1)/\(lenses.count): \(lens)…")
            // Steer with what THIS run already rejected or retired (fetched fresh — execution is
            // serial, so earlier investigators' dead ends reach later ones): iterate, don't
            // re-litigate. Retired findings stay their own category — the novelty guards ignore
            // tombstoned rows, so this steering is the only brake on re-surfacing one.
            //
            // The ANGLE and the AVOID-LIST travel separately now, because the two passes inside
            // `investigate` need different things: the explore pass measures and proposes nothing,
            // so a list of things not to propose was 230 of its 480 characters spent on a job it
            // does not have. See `AvoidList` for what printing the assembled prompt showed.
            let avoid = await AvoidList(
                rejectedThisRun: ctx.ledger.recentRejections(),
                retiredThisRun: ctx.ledger.retirements(),
                priorRunDeadEnds: priorRuns
            )
            var angle = lens
            if let available { angle += "\n" + available }
            let rendered = await llm(ctx.deadline, progress: ctx.progress) {
                try await subagents.investigate(
                    lens: angle, avoid: avoid, substrate: substrate, now: ctx.now
                )
            }
            let found = rendered ?? []
            await ctx.progress?.log(
                found.isEmpty
                    ? "· Investigator \(index + 1) came back empty-handed"
                    : "· Investigator \(index + 1) proposes \(found.count): "
                    + found.map(\.title).joined(separator: " · ")
            )
            // A session that never rendered (rate limit, model blip) says nothing about the angle,
            // so it is reported as "not chased" rather than as an empty result.
            guard rendered != nil else { return nil }
            // Paired with the lens that produced it: a finding's provenance starts with WHICH of
            // the two dozen specialists saw it, and after the dedup below that is unrecoverable.
            // The lens is carried even when it produced nothing — that is the barren signal.
            return (lens: lens, findings: found)
        }
        let sessions = perLens.compactMap(\.self)
        await recordBarrenAngles(sessions.filter(\.findings.isEmpty).map(\.lens), learnable: learnable, ctx)
        // Dedup across lenses by (kind, metric, secondaryMetric) so the same finding isn't vetted twice.
        var seen = Set<String>()
        var collected: [(lens: String, finding: ProposedFinding)] = []
        for candidate in sessions.flatMap({ session in
            session.findings.map { (lens: session.lens, finding: $0) }
        }) {
            let finding = candidate.finding
            let key = "\(finding.kind)|\(finding.metric)|\(finding.secondaryMetric)"
            if seen.insert(key).inserted { collected.append(candidate) }
        }
        let unique = collected
        await ctx.progress?.apply { $0.candidatesTotal += unique.count }
        let results = await concurrentMap(
            unique,
            maxConcurrent: EnhancementPolicy.maxConcurrentSubagents
        ) { candidate in
            let inserted = await persistProposed(candidate.finding, lens: candidate.lens, ctx)
            await ctx.progress?.apply { $0.candidatesAnalyzed += 1; if inserted { $0.newInsights += 1 } }
            return inserted
        }
        return results.count(where: { $0 })
    }

    /// The run's daily series, plus the line to tell the user about it.
    ///
    /// Every caller used `(try? provider.dailySeries()) ?? []`, which makes a FAILED read and an
    /// empty store the same value. The run then said "Read 0 metrics across your logged history" —
    /// blaming the user's history for a fetch that may never have succeeded, in an app whose stated
    /// rule for the live feed is that every line says literally what is happening. A read that threw
    /// is also the one case worth a person's attention: an empty store fills itself on the next
    /// ingest, a failing one does not.
    ///
    /// The series is still empty on failure and the run still proceeds. That is deliberate — the
    /// agents find nothing and say so, which is honest, where refusing to start would need a
    /// judgment about whether the failure is transient.
    /// The daily series, the line describing it, and whether the read FAILED.
    ///
    /// A named type rather than a tuple: `failed` has to be separate from an empty `series` because
    /// the prose cannot carry it and callers that already hold data must act on the difference — the
    /// deep run's boundary refresh keeps what it has rather than replacing it with nothing.
    nonisolated struct SeriesLoad {
        let series: [DailySeries]
        let note: String
        let failed: Bool
    }

    static func loadSeries(_ provider: MetricStatsProvider, now: Date) async -> SeriesLoad {
        do {
            let series = try await provider.dailySeries(now: now)
            guard !series.isEmpty else {
                return SeriesLoad(
                    series: [],
                    note: "No logged history yet — there is nothing to analyse until Health data arrives.",
                    failed: false
                )
            }
            return SeriesLoad(
                series: series,
                note: "Read \(series.count) metrics across your logged history",
                failed: false
            )
        } catch {
            return SeriesLoad(
                series: [],
                note: "Couldn't read your stored history, so this pass has nothing to work from.",
                failed: true
            )
        }
    }

    /// Fill in the live card's "Relationships tested" once the correlation scan finishes.
    ///
    /// That chip, and "Cross-signal links" beside it, were displayed and never written to — declared
    /// on `AnalysisProgress`, rendered on every run, incremented by nothing. So the card told a
    /// person that zero relationships had been tested while the engine was judging every computable
    /// pair in their history and the app's premium finding is a cross-signal link. A plausible-looking
    /// zero is the hardest kind of wrong number to notice, and it was found by looking at the running
    /// app rather than at the code.
    ///
    /// Detached, deliberately: `correlationScan()` awaits the scan, and blocking the run's start on it
    /// would trade a live counter for the CPU/generation overlap `precompute` exists to create. The
    /// chip stays at zero until the number is real, which is the honest order.
    static func reportPairsTested(_ substrate: AnalysisSubstrate, to progress: ProgressReporter?) {
        guard let progress else { return }
        Task.detached(priority: .utility) {
            let tested = await substrate.correlationScan().pairsTested
            await progress.apply { $0.correlationsTested = tested }
        }
    }

    /// How many barren angles one pass may journal. The journal prunes to a bounded row count
    /// globally, so an unbounded dry pass — two dozen investigators, none proposing anything — could
    /// evict the confirmed/rejected history that actually steers the fleet. A few are plenty: this is
    /// one input to a strategy decision, not a ledger.
    static let maxBarrenPerPass = 4

    /// Record the angles this pass genuinely CHASED and that produced nothing, so the journal's
    /// cross-run memory stops being positive-only. Only `learnable` angles are recorded — the scout
    /// leads and director-composed angles, which are invented fresh each pass and whose yield is
    /// therefore worth learning. The fixed thematic rotation is excluded on purpose: it comes back
    /// empty constantly and by design, and journaling it would drown the signal in its own noise.
    ///
    /// Nothing consumes this as a prohibition. `journalSteering`'s do-not-repeat list stays
    /// rejected/retired only; barren angles reach the research director as a FACT it can weigh,
    /// because ground that was barren before a month of new data is not barren now, and only an
    /// agent reading the run's state can judge that.
    private func recordBarrenAngles(
        _ barren: [String], learnable: Set<String>, _ ctx: DiscoveryContext
    ) async {
        for lens in barren.filter({ learnable.contains($0) }).prefix(Self.maxBarrenPerPass) {
            try? await writer.recordJournal(
                // No reason recorded: it would be the same constant on every barren row, and the
                // one line that reads them already says "Chased with no yield". A journal entry that
                // repeats its own heading spends prompt on nothing and dilutes the lens text beside
                // it — the part the director is actually meant to weigh.
                kind: .barren, text: lens,
                jobRunID: ctx.jobID, now: ctx.now
            )
        }
    }

    /// The most findings the feed will show under "Worth your attention". Mirrors the curator's
    /// `.count(0...3)` guide so the two cannot drift apart silently.
    static let maxHighlights = 3

    /// Curate the feed to the bounded high-quality budget. Curation is an AGENT decision: the
    /// curator reads the numbered roster — every active finding with its computed quality, age,
    /// shared-metric and near-duplicate FACTS — and chooses what keeps its slot; everything it
    /// leaves out is retired. The deterministic greedy trim (`curateFindings`) remains ONLY as the
    /// fallback when the model can't render a decision — the feed must stay bounded even then.
    /// Internal (not private) because the focused drill-down (`Orchestrator+Focus`) closes its run
    /// with the same curation.
    func curate(now: Date) async {
        let budget = EnhancementPolicy.maxActiveFindings
        guard capability().isAvailable else {
            try? await writer.curateFindings(maxActive: budget, now: now)
            return
        }
        let roster = await (try? writer.curationRoster(now: now)) ?? []
        guard roster.count > 1 else { return }
        let decision = await llm(nil) {
            try await subagents.curate(
                roster: roster.map(\.line).joined(separator: "\n"), budget: budget
            )
        }
        guard let decision else {
            try? await writer.curateFindings(maxActive: budget, now: now)
            return
        }
        // Numbers outside the roster are ignored (the closed-roster boundary), and keeps beyond
        // the budget are trimmed in roster order (strongest-first) — plumbing that bounds the
        // feed, not a worth judgment.
        let keep = Set(decision.keep.filter { $0 >= 0 && $0 < roster.count }.prefix(budget))
        for candidate in roster where !keep.contains(candidate.index) {
            try? await writer.retire(candidate.target)
        }
        // The feed's "Worth your attention" section is this line and nothing else — no score
        // threshold, no "only once there are 5 findings", no top-3 slice. A highlight exists only
        // because the curator named it; a highlight it didn't renew is cleared. Same closed-roster
        // boundary as `keep`, and a promotion for something the curator retired is ignored.
        // Capped as well as roster-bounded, matching how `keep` is treated: the `.count(0...3)`
        // guide is structurally enforced by constrained decoding, but "a handful" is a product
        // promise and the feed should not depend on a model honouring a schema to keep it.
        let highlight = decision.highlight.filter { keep.contains($0) }.prefix(Self.maxHighlights)
        try? await writer.setHighlights(Set(highlight.map { roster[$0].target }))
        // Curation is where findings become tombstones, so it is where the tombstones are bounded —
        // the same placement `pruneJournal` has next to `recordJournal`. An indefinite run retires
        // findings for days, and the only other thing that removes a retired row is the user's
        // delete-all, which is not a bound.
        try? await writer.pruneRetiredFindings()
    }

    /// Stop LLM work when the wall-clock budget is spent OR the enclosing task was cancelled
    /// (e.g. a BGTask expiration handler fired). Observing cancellation cooperatively keeps us from
    /// running past the OS deadline and completing the task late.
    func shouldStop(_ deadline: ContinuousClock.Instant?) -> Bool {
        if Task.isCancelled { return true }
        guard let deadline else { return false }
        return ContinuousClock.now >= deadline
    }

    /// Run one LLM operation through rate-limit backoff; any failure (including rate-limit
    /// exhaustion) returns `nil`, and every caller treats `nil` as "produce no finding" — there is no
    /// template fallback, so a candidate the model can't reason about is simply dropped rather than
    /// shown as generic prose. The failure is logged so a silent drop is diagnosable — but ONLY via
    /// `error.localizedDescription` (a curated, PHI-free message). `String(describing:)` on a
    /// `GenerationError` reflects its associated `Context.debugDescription` verbatim, which echoes the
    /// model's prompt/output — and our prompts carry health values — so it must never be logged.
    func llm<T>(
        _ deadline: ContinuousClock.Instant?,
        progress: ProgressReporter? = nil,
        _ operation: () async throws -> T
    ) async -> T? {
        // Book the generation in/out so the resource meter can show live inference activity — the
        // honest ANE-load proxy (there is no public Neural Engine utilization API).
        InferenceActivity.shared.begin()
        defer { InferenceActivity.shared.end() }
        do {
            let result = try await RateLimitBackoff.run(deadline: deadline, operation: operation)
            await progress?.noteLLMOutcome(success: true)
            return result
        } catch {
            // Record the failure so the run can tell a genuine "nothing notable" pass apart from a
            // wholesale inference failure (every call errored) — the two must not share a closing note.
            await progress?.noteLLMOutcome(success: false)
            // localizedDescription only — never String(describing:), which echoes prompt PHI (see doc).
            Self.log.debug("LLM subagent step skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
