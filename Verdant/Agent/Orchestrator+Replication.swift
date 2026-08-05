import Foundation

// MARK: - The armed replication panel (verification that re-tests the data)

extension Orchestrator {
    /// The three distinct ways a true-LOOKING finding fails on re-test — each analyst runs its own
    /// queries against the data instead of reasoning about the prose (that's the skeptic panel's
    /// job). Diversity over redundancy, same as every other panel.
    static let replicationLenses = [
        "re-test it OUTSIDE its own window: compute the same relationship or level over a different "
            + "span (an earlier period, or a much longer window) with analyze — does the effect "
            + "exist beyond the window that produced it?",
        "outlier-robustness: check the metric's unusualDays near the claim and re-compute with "
            + "analyze using median instead of mean — does the effect survive when a few extreme "
            + "days can't carry it?",
        "structure check: test whether day-of-week or lag structure explains it — analyze with "
            + "dayFilter (weekdays vs weekends) or the zero/reversed lag; a schedule or ordering "
            + "artifact fails"
    ]

    /// Armed verification: where the skeptic panel reasons about a finding's PROSE, this panel
    /// re-tests it against the DATA — each analyst drives analyze/unusualDays itself and judges
    /// whether the claim replicates in views that didn't produce it. Aggregation mirrors the
    /// skeptic panel exactly (`panelHolds`): strict majority of RENDERED verdicts, tie rejects,
    /// falls open only when nothing rendered — so a wholly rate-limited run keeps its
    /// skeptic-passed finding rather than losing it to infra. Deadline-spent fails CLOSED before
    /// any session is issued, mirroring `survivesScrutiny` — that guard is what makes the
    /// background run's deadline discipline govern this panel's cost too.
    func survivesReplication(
        _ claim: String,
        subject: String,
        metrics: [MetricKey],
        substrate: AnalysisSubstrate,
        _ ctx: DiscoveryContext,
        lenses: [String] = Orchestrator.replicationLenses
    ) async -> PanelOutcome {
        guard ctx.adversarial else { return .notConvened }
        guard !shouldStop(ctx.deadline) else { return .outOfBudget }
        // The same shortlist the investigator fleet gets. An analyst that re-tests against a metric
        // the person has no data for cannot replicate anything, and reads that as the claim failing.
        //
        // Observed: asked to re-test a resting-heart-rate step, an analyst queried "Heart rate" — a
        // real registry key with no data in that library — and returned "No data for Heart rate." as
        // its verdict. The panel scored 0 of 5 and the finding was rejected, on a claim whose own
        // basis had just stated the numbers. The steering added for investigators did not reach here.
        let available = Orchestrator.availableMetricsLine(substrate)
        // Size the armed panel to the claim, exactly as the skeptic panel is sized (see
        // `survivesScrutiny`): the three fixed checks are what ANY claim needs, and an agent that
        // has read this one names the computation that would expose it specifically. Additive — a
        // planner that says nothing, or fails, leaves the panel as strong as it was.
        //
        // The planner gets the shortlist too, and this is why it is computed here rather than just
        // below where the analysts read it. It was planning blind: on a library holding only resting
        // heart rate, it proposed re-tests against step count and against a weekday/weekend split
        // with no weekday data, and two of five analysts spent their whole session discovering that
        // — "No data for Steps." A re-test that cannot be run is worse than no extra re-test at all,
        // because the panel was SIZED as though it had one. Planning against the data the person
        // actually has costs nothing; the line is already built.
        let planned = await llm(ctx.deadline, progress: ctx.progress) {
            try await subagents.composeRetests(claim: claim, available: available)
        }
        let extra = Self.composedChallenges(planned?.retests ?? [])
        let lenses = lenses + extra
        if !extra.isEmpty {
            await ctx.progress?.log(
                "· Planner added \(extra.count) re-test\(extra.count == 1 ? "" : "s") for this claim"
            )
        }
        await ctx.progress?.log(
            "Replication panel: \(lenses.count) armed analysts re-test \(subject) against the data…"
        )
        // The exact registry key(s) the claim is about.
        //
        // Without this an analyst had NO way to know them: `subject` is a display name used only in
        // the log line above, and the claim it is handed is prose plus a basis sentence — neither
        // carries a key. So it guessed from English, and guessed wrong: asked to re-test a resting
        // heart rate step it queried "Heart rate", got nothing, and reported that as a failure to
        // replicate. Across three probes against the real model, not one analyst completed a re-test.
        //
        // This is the panel that exists to check findings against the DATA. It could not find the
        // data.
        let named = metrics.isEmpty
            ? nil
            : "The claim is about these exact metric keys, which is what the tools expect: "
            + metrics.map(\.rawValue).joined(separator: ", ") + "."
        let verdicts = await concurrentMap(
            Array(lenses.enumerated()),
            maxConcurrent: EnhancementPolicy.maxConcurrentSubagents
        ) { index, lens -> Verdict? in
            guard !shouldStop(ctx.deadline) else { return nil }
            // The model-written re-test is bounded HERE, before the code-generated lines are joined
            // on. Clamping the joined string instead — which is what `replicate` used to do at 240
            // characters — cut from the end, and the end is where `named` and `available` live: a
            // realistic composition measured 350 characters, so the whole available-metrics line and
            // part of the metric-key line were discarded. Both exist to fix a failure mode this panel
            // actually had, and both were being deleted by the clamp meant to protect the window.
            let steered = [PromptText.clamped(lens, to: 240), named, available]
                .compactMap(\.self).joined(separator: "\n")
            let verdict = await llm(ctx.deadline, progress: ctx.progress) {
                try await subagents.replicate(claim: claim, lens: steered, substrate: substrate)
            }
            if let verdict {
                // Narrate the analyst's reasoning alongside the verdict — the re-test's actual
                // ground, not a bare boolean. "Could not run it" is said as its own outcome, because
                // it is not a judgement on the finding and must not read as one.
                let outcome = if !verdict.couldTest {
                    "could not run this check"
                } else if verdict.holdsUp {
                    "confirmed in the data"
                } else {
                    "failed to replicate"
                }
                await ctx.progress?.log(
                    "· Replication \(index + 1)/\(lenses.count): " + outcome
                        + (verdict.why.isEmpty ? "" : " — \(String(verdict.why.prefix(110)))")
                )
            }
            return verdict
        }
        // An analyst that could not RUN its check has refuted nothing, so it is excluded from the
        // tally for exactly the reason a verdict that never rendered is: no evidence is not evidence
        // against. Without this, an analyst whose `analyze` call found no data answered "when in
        // doubt, false" — as its instruction tells it to — and voted a true finding down. Observed
        // against the real model doing precisely that, 0 of 5, on a claim whose basis stated the
        // numbers.
        return PanelOutcome(verdicts.compactMap(\.self).filter(\.couldTest))
    }
}
