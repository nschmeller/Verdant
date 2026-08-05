import Foundation

// MARK: - The indefinite deep-run loop

nonisolated extension Orchestrator {
    /// The INDEFINITE research program behind the user-triggered Deep Analysis: it keeps working
    /// for as long as the app stays open, ending only by cancellation (Stop, or the app leaving the
    /// foreground) — never on its own. Every arm of the loop is as deep as the reasoning it feeds:
    ///
    /// - **COLLECT** (each substrate-refresh boundary): actually pull the HealthKit deltas that
    ///   arrived while reasoning (the `collector` hook — observer ingests skip while this run holds
    ///   the gate, so without it a refresh re-reads rollups that cannot have changed), deepen any
    ///   still-shallow history to the full analysis horizon, then rebuild the substrate.
    /// - **VERIFY, standing** (same boundary): re-audit the feed's strongest findings against the
    ///   fresh data with the armed replication panel — a finding must keep earning its slot as data
    ///   arrives, and one that no longer holds is retired.
    /// - **DISCOVER** (every pass): rotating scout surveyors read the map — coverage, strange days,
    ///   deep time, missed links, data quality — and hand testable leads to the same pass's fleet.
    /// - **REASON + VERIFY, new** (every pass): the thematic + per-metric investigator fleet,
    ///   widened by the scouts' leads; each kept finding clears the safety panel, the prose-skeptic
    ///   panel, AND the armed replication panel.
    ///
    /// When breadth runs dry the run directs its OWN depth (focused drill-downs into its strongest
    /// findings) and its scouts are pushed into unvisited ground. Quality gates never loosen —
    /// unbounded compute deepens coverage without lowering the bar.
    func runExhaustiveDiscovery(_ context: DiscoveryContext) async -> Int {
        var ctx = context
        var produced = 0
        var dryStreak = 0
        var pass = 0
        // The per-metric hypothesis roster: across passes, EVERY metric with real data gets an
        // investigator of its own (a rotating slice per pass), on top of the thematic angles.
        var hypothesisMetrics = ctx.substrate?.metricsWithData() ?? []
        // The prefetched COLLECT (see `startCollection`): launched one pass BEFORE the boundary that
        // consumes it, so the HealthKit/CPU ingest runs underneath a full pass of generation instead
        // of stalling the engine at the boundary. Held here so the boundary can join it — and so an
        // exiting run (Stop, deadline, cancellation) tears it down instead of stranding it.
        var pendingCollection: Task<Void, Never>?
        // Which refresh this is — rotates the standing-finding audit's docket through the feed.
        var refreshRound = 0
        // `maxPasses` is a runaway backstop (days of compute), not a stop condition — cancellation
        // is the only intended exit.
        while pass < DeepAnalysisPolicy.maxPasses, !Task.isCancelled, !shouldStop(ctx.deadline) {
            pass += 1
            let currentPass = pass
            if currentPass > 1, (currentPass - 1).isMultiple(of: DeepAnalysisPolicy.substrateRefreshPasses) {
                hypothesisMetrics = await refreshBoundary(
                    &ctx, joining: pendingCollection, round: refreshRound
                )
                refreshRound += 1
                pendingCollection = nil
            }
            // PREFETCH the next boundary's collection: this is the last pass before one, so launch
            // the ingest NOW and let it run underneath everything below. A pass is many generations
            // long, so by the time the boundary joins it the data is already in — the engine never
            // waits on HealthKit.
            if currentPass.isMultiple(of: DeepAnalysisPolicy.substrateRefreshPasses),
               pendingCollection == nil
            {
                pendingCollection = startCollection(ctx.progress)
            }
            await ctx.progress?.apply { $0.phase = .enhancing; $0.passes = currentPass }
            // The STRATEGY decision is the research director's: it reads the run's state — pass
            // yield, dry streak, feed contents, this run's rejections, prior runs' dead ends — and
            // picks the next move. The old dry-streak arithmetic survives ONLY as the fallback
            // when the director can't render a plan (a model blip must not stall the loop).
            let state = await directorState(ctx, pass: currentPass, produced: produced, dryStreak: dryStreak)
            let plan = await llm(ctx.deadline, progress: ctx.progress) {
                try await subagents.direct(state: state, now: ctx.now)
            }
            let directed = plan.flatMap { PassStrategy(rawValue: $0.strategy) }
            // Whether the strategy is the DIRECTOR's or the fallback's decides what the feed may
            // claim about it — see `drillIntoOwnFindings`.
            let strategy = directed
                ?? (dryStreak >= DeepAnalysisPolicy.dryStreakToStop ? .drill : .breadth)
            if let plan {
                await ctx.progress?.log(
                    "Director: \(strategy.rawValue) — \(String(plan.directive.prefix(140)))"
                )
            }
            switch strategy {
            case .drill:
                // Self-directed depth; a drill pass resets the dry streak so the fallback doesn't
                // immediately re-drill if the director goes quiet next pass.
                dryStreak = 0
                produced += await drillIntoOwnFindings(ctx, breadthExhausted: directed == nil)
            case .breadth, .frontier:
                await ctx.progress?.log("Pass \(currentPass): scouting for leads, then investigating…")
                // DISCOVER: rotating scouts survey the map and hand over testable leads; a frontier
                // pass (or a dry streak) pushes them explicitly into unvisited ground.
                let leads = await runScoutSweep(
                    ctx, pass: currentPass,
                    exhaustedBreadth: strategy == .frontier || dryStreak > 0
                )
                // REASON: the thematic + per-metric fleet, widened by the scouts' leads AND by any
                // angles the director composed itself — and led by its directive, which the fleet
                // chases as its first lens.
                //
                // The director's lenses are ADDED, never substituted: the thematic roster is a
                // fixed rotation, so anything it structurally cannot ask is what the director is
                // for — but a pass must never come out narrower because the director was terse.
                // The invented angles — scout leads and the director's own — as opposed to the fixed
                // thematic rotation. These are the ones whose yield is worth remembering across
                // runs, so they are the ones a barren result gets journaled for.
                let invented = Self.leadLenses(leads) + Self.directorLenses(plan?.extraLenses ?? [])
                var lenses = Instructions.deepLenses(pass: currentPass, metrics: hypothesisMetrics)
                    + invented
                if let directive = plan?.directive, !directive.isEmpty {
                    lenses.insert(
                        "the director's directive for this pass: \(PromptText.clamped(directive, to: 200))",
                        at: 0
                    )
                }
                let newCount = await runInvestigation(ctx, lenses: lenses, learnable: Set(invented))
                produced += newCount
                dryStreak = newCount == 0 ? dryStreak + 1 : 0
                await ctx.progress?.log(
                    newCount > 0
                        ? "Pass \(currentPass) done — \(newCount) new finding\(newCount == 1 ? "" : "s") kept "
                        + "(\(produced) total this run)"
                        : "Pass \(currentPass) done — nothing cleared the bar (\(dryStreak) dry in a row)"
                )
            }
        }
        // Tear the prefetch down before returning, and WAIT for it. Cancelling alone was not enough:
        // `narrate` promises the run gate is released only once the work has genuinely stopped — the
        // property that stops a catch-up overlapping a still-unwinding deep run — and a cancelled
        // ingest is still writing until it reaches its next suspension point. This is the single
        // exit from the loop, so an explicit join is both possible and clearer than a `defer` (which
        // could not await anyway).
        if let pendingCollection {
            pendingCollection.cancel()
            await pendingCollection.value
        }
        return produced
    }

    /// The substrate-refresh boundary: join the prefetched collection, rebuild the substrate on the
    /// new day boundary with its scans already started, then re-verify and re-curate the standing
    /// feed against the fresh data. Returns the refreshed per-metric hypothesis roster.
    private func refreshBoundary(
        _ ctx: inout DiscoveryContext,
        joining pendingCollection: Task<Void, Never>?,
        round: Int
    ) async -> [MetricKey] {
        // COLLECT: join the ingest that has been running throughout the previous pass, then rebuild
        // on the new day boundary. Re-prewarm first: the model may have been evicted if the
        // collection outlasted the pass, and the warm-up then overlaps the tail of it.
        subagents.prewarm()
        if let pendingCollection {
            // `await task.value` ignores the AWAITING task's cancellation, so a plain join here made
            // Stop (and backgrounding) block until the whole ingest finished — minutes on a first
            // run, during which the run gate stays held and the UI still says it is working. The
            // handler forwards the cancellation to the collection so the join ends promptly, and we
            // still await it afterwards: the run must not release the gate while an ingest it owns
            // is mid-write.
            await withTaskCancellationHandler {
                await pendingCollection.value
            } onCancel: {
                pendingCollection.cancel()
            }
        } else {
            // No prefetch was in flight (the run started mid-cycle, or a previous prefetch was
            // cancelled) — fall back to collecting inline rather than skipping the data.
            await collector?(ctx.progress)
        }
        let reread = await Orchestrator.loadSeries(provider, now: .now)
        // A FAILED re-read must not replace the run's data with nothing. This substrate is swapped in
        // for the rest of an indefinite run, so a transient fetch error here used to leave every
        // later pass reasoning over an empty history — hours of the engine's time spent on nothing,
        // under a line announcing that fresh data had been folded in. An empty-but-successful read is
        // different and IS adopted: the store really is empty (a delete-all), and carrying on with
        // rollups the user has just erased would be worse.
        guard !reread.failed else {
            await ctx.progress?.log(
                "Couldn't re-read your history just now — carrying on with the data this run already has."
            )
            // The roster the run already had — unchanged, because the data is unchanged.
            return ctx.substrate?.metricsWithData() ?? []
        }
        let fresh = reread.series
        ctx.now = .now
        let refreshed = AnalysisSubstrate(provider: provider, series: fresh, now: ctx.now)
        // Start the new substrate's scans immediately: they crunch on the CPU while the audit and
        // curation below are generating, so the first tool call of the next pass reads a finished
        // scan instead of stalling on one.
        await refreshed.precompute()
        ctx.substrate = refreshed
        await ctx.progress?
            .log("Refreshed the substrate — folding in data that arrived while reasoning")
        // VERIFY (standing): the feed must keep earning its place against the fresh data.
        await auditStandingFindings(ctx, round: round)
        // CURATE: an indefinite run's feed must keep earning its shape as findings accumulate —
        // not only when the run finally ends.
        await curate(now: ctx.now)
        return refreshed.metricsWithData()
    }

    /// Launch the data collection as a side task so it overlaps a pass's generation instead of
    /// stalling the Neural Engine at the refresh boundary. Collection is HealthKit I/O plus CPU
    /// rollup work — it never touches the model — so the two genuinely run at once rather than
    /// competing: the whole point is that the engine keeps reasoning while the data arrives.
    ///
    /// **Why concurrent ingest is safe here.** Every `insert`/`delete`/`save` in the app lives on
    /// `StoreWriter`, a single-writer `@ModelActor` (`Ingestor` writes only through it, and
    /// `MetricStatsProvider` never writes at all), so an ingest landing mid-pass serializes against
    /// the pass's own persists rather than racing them. The run gate is untouched: the deep run
    /// still holds it throughout, so no other run can interleave.
    ///
    /// **What the pass does and doesn't see.** Every stat tool reads the memoized
    /// `AnalysisSubstrate` built before the collection started, so the agent reasons over a fixed
    /// snapshot and the *next* substrate picks the new data up. Two reads are deliberately live and
    /// can therefore see the fresh rows: `metricsOverview`'s `recentInsightKinds` (about the feed,
    /// not the health data), and the per-kind number resolution at persist time, which re-reads the
    /// provider on purpose — that is the anti-hallucination boundary, and newer numbers are the more
    /// correct ones to show. The visible edge: a proposal can be dropped as "couldn't be resolved
    /// confidently" because the data moved underneath it mid-pass. Rare, benign, and it re-surfaces
    /// next pass.
    ///
    /// Unstructured on purpose, and therefore NOT auto-cancelled by the enclosing task — the caller
    /// owns it, cancelling AND joining it on the way out of `runExhaustiveDiscovery`, with a
    /// cancellation handler around the mid-loop join in `refreshBoundary`. Joining matters as much
    /// as cancelling: the run gate must not be released while an ingest this run started is still
    /// unwinding, or the next run can interleave with it.
    private func startCollection(_ progress: ProgressReporter?) -> Task<Void, Never>? {
        guard let collector else { return nil }
        return Task(priority: .userInitiated) { await collector(progress) }
    }

    /// The director's closed strategy vocabulary. `PassPlan.strategy`'s `.anyOf` is DERIVED from
    /// this rather than mirroring it by hand: the loop switches exhaustively over these cases, so a
    /// hand-copied list that gained a strategy the switch never handles would route silently to the
    /// fallback. Declaration order is the order the model sees.
    enum PassStrategy: String, CaseIterable {
        case breadth, drill, frontier

        static let allRawValues = allCases.map(\.rawValue)
    }

    /// The director's briefing: the run's state as compact FACTS — pass number, yield, dry streak,
    /// what the feed holds, what this run rejected/retired, what prior runs ruled out, and which
    /// angles have been chased for no yield.
    /// Every line is clamped; the whole briefing rides in one 4k prompt.
    /// Internal, not private, so the assembled size can be measured. Six independently-clamped
    /// sources are concatenated here and nothing looked at the sum — the same gap that
    /// `BasisLengthTests` closed for the panel claims, and one this method acquired a seventh line
    /// on the same day the gap was written up.
    func directorState(
        _ ctx: DiscoveryContext, pass: Int, produced: Int, dryStreak: Int
    ) async -> String {
        let feed = await (try? writer.activeInvestigationFoci(limit: 5)) ?? []
        let rejections = await ctx.ledger.recentRejections(limit: 4)
        let retired = await ctx.ledger.retirements(limit: 3)
        let prior = await (try? writer.journalSteering(excludingRun: ctx.jobID, limit: 3, now: ctx.now)) ?? []
        // Angles that were CHASED and yielded nothing — including this run's, which the in-memory
        // ledger does not track. Offered as evidence, not as a ban: the director is the agent whose
        // job is deciding where to look, and barren ground can bear fruit once more data lands.
        let barren = await (try? writer.journalEntries(kind: .barren, limit: 3, now: ctx.now)) ?? []
        var lines = ["Pass \(pass). Kept this run: \(produced). Consecutive dry passes: \(dryStreak)."]
        if !feed.isEmpty {
            lines.append("Feed holds: "
                + feed.map { PromptText.clamped($0.title, to: 50) }.joined(separator: "; ") + ".")
        }
        if !rejections.isEmpty {
            lines.append("Rejected this run: " + rejections.joined(separator: "; ") + ".")
        }
        if !retired.isEmpty {
            lines.append("Retired this run: " + retired.joined(separator: "; ") + ".")
        }
        if !prior.isEmpty {
            lines.append("Prior runs ruled out: " + prior.joined(separator: "; ") + ".")
        }
        if !barren.isEmpty {
            lines.append("Chased with no yield (not a ban — judge whether new data changes it): "
                + barren.joined(separator: "; ") + ".")
        }
        if let untouched = await Self.untouchedMetricsLine(ctx, feed: feed) {
            lines.append(untouched)
        }
        return lines.joined(separator: "\n")
    }

    /// Metrics with real history that nothing currently on the feed covers.
    ///
    /// The director chose between breadth, drilling and FRONTIER — "push into unvisited ground" —
    /// while being told nothing whatever about the ground. It saw yield, dry streaks, what the feed
    /// holds by title, and what has been ruled out; the shape of the data itself reached the scouts
    /// (via `coverage`) and the scouts run AFTER the strategy is picked. So the one agent choosing
    /// where to look next could not name a single unexplored metric, and "frontier" meant little more
    /// than "try harder".
    ///
    /// Stated precisely, because it is weaker than "never investigated": a finding can be retired or
    /// curated off the feed, so a metric here may well have been looked at. It is a fact for the
    /// director to weigh, not a work list — which is why nothing acts on it automatically.
    ///
    /// Costs no computation: `metricsWithData` reads the already-built substrate, and the feed foci
    /// were fetched for the line above.
    static func untouchedMetricsLine(
        _ ctx: DiscoveryContext, feed: [InvestigationFocus]
    ) async -> String? {
        guard let substrate = ctx.substrate else { return nil }
        var covered = Set(feed.map(\.metric))
        covered.formUnion(feed.compactMap(\.secondaryMetric))
        let untouched = substrate.metricsWithData().filter { !covered.contains($0) }
        guard !untouched.isEmpty else { return nil }
        let named = untouched.prefix(maxUntouchedNamed).map(\.displayName).joined(separator: ", ")
        let rest = untouched.count - min(untouched.count, maxUntouchedNamed)
        let more = rest > 0 ? " (and \(rest) more)" : ""
        return "Has usable history but nothing on the feed right now: \(named)\(more)."
    }

    /// Named in the director's state before the count takes over. Five is what fits beside the other
    /// five lines without crowding a prompt that must stay well inside the 4k window.
    static let maxUntouchedNamed = 5

    /// Self-directed depth: point the focused lens fleet at the run's own strongest current
    /// findings — what leads them, their long arcs, their day shapes, and a deliberate attempt to
    /// knock each one down.
    /// The feed line for one drill, as a pure function so both branches can be asserted directly.
    ///
    /// It was first pinned with a source scan, which was vacuous: replacing the conditional with the
    /// unconditional claim left the parameter in place and the phrase present exactly once, so every
    /// assertion still held. A scan can see that a string exists; it cannot see what guards it.
    static func drillNote(title: String, breadthExhausted: Bool) -> String {
        breadthExhausted
            ? "Breadth exhausted for now — drilling into “\(title)”…"
            : "Drilling into “\(title)”…"
    }

    /// `breadthExhausted` says whether this drill is the FALLBACK's — the dry-streak arithmetic that
    /// runs only when the director could not render a plan — or the director's own choice.
    ///
    /// The feed used to announce "Breadth exhausted for now" on every drill. That was true when a dry
    /// streak was the only way to get here, and stopped being true when the strategy became the
    /// director's decision: it may drill on pass two with nothing dry behind it, having judged a
    /// standing finding worth deepening. The line asserted a reason the app no longer had, on the
    /// surface whose stated rule is that every line is literally what is happening. When the director
    /// chose, its own directive is already logged above this — so the honest thing is to say less.
    private func drillIntoOwnFindings(_ ctx: DiscoveryContext, breadthExhausted: Bool) async -> Int {
        let foci = await (try? writer.activeInvestigationFoci(limit: 2)) ?? []
        guard !foci.isEmpty else { return 0 }
        var produced = 0
        for focus in foci {
            if Task.isCancelled || shouldStop(ctx.deadline) { break }
            await ctx.progress?.log(
                Self.drillNote(title: focus.title, breadthExhausted: breadthExhausted)
            )
            produced += await runInvestigation(ctx, lenses: Self.focusedLenses(focus))
        }
        return produced
    }
}
