import Foundation

// MARK: - The standing-finding audit (re-verification against fresh data)

nonisolated extension Orchestrator {
    /// The audit's re-test angles — the replication lenses re-anchored on TODAY: a standing finding
    /// was verified against the data as it stood when it surfaced; these ask whether it still holds
    /// now that the data has moved.
    static let auditLenses = [
        "does it still hold in the CURRENT data — recompute its core relationship or level over the "
            + "most recent windows with analyze; has it faded, reversed, or held?",
        "outlier-robustness today: re-compute with median instead of mean and check unusualDays — "
            + "is the finding now carried by a few extreme days that arrived after it surfaced?",
        "has the data moved past it — compare the claim against the newest windows (analyze recent "
            + "spans vs its original story); does the latest data tell a different story?"
    ]

    /// Re-verify the standing feed against FRESH data — the verification loop's second arm, run at
    /// every substrate-refresh boundary of a deep run. The strongest active findings go to the
    /// armed replication panel with TODAY's substrate; one that no longer holds is retired
    /// (tombstoned — the same retirement curation uses) and remembered in the run ledger so the
    /// fleet doesn't immediately re-surface it. A finding must keep earning its slot as data
    /// arrives, not just earn it once. Returns the number retired.
    /// `round` advances once per refresh boundary, rotating the docket through the ranked feed so
    /// every standing finding faces the panel within a few refreshes rather than only the strongest
    /// few, forever (see `auditCandidates`).
    @discardableResult
    func auditStandingFindings(_ ctx: DiscoveryContext, round: Int = 0) async -> Int {
        guard let substrate = ctx.substrate else { return 0 }
        let candidates = await (try? writer.auditCandidates(
            limit: DeepAnalysisPolicy.auditFindingsPerRefresh, round: round
        )) ?? []
        guard !candidates.isEmpty else { return 0 }
        await ctx.progress?.log(
            "Auditing \(candidates.count) standing finding\(candidates.count == 1 ? "" : "s") "
                + "against the fresh data…"
        )
        var retired = 0
        for candidate in candidates {
            if shouldStop(ctx.deadline) { break }
            let holds = await survivesReplication(
                candidate.claim,
                subject: "“\(candidate.title)”",
                metrics: candidate.metrics,
                substrate: substrate,
                ctx,
                lenses: Self.auditLenses
            )
            if holds.passed {
                await ctx.progress?.log("· “\(candidate.title)” still holds")
                continue
            }
            // A Stop or spent deadline mid-panel thins it, and a lone rendered reject then reads
            // as "fails". Retiring a STANDING finding is destructive enough to demand a panel that
            // actually ran — skip and let the next refresh re-audit at full strength.
            if shouldStop(ctx.deadline) { break }
            do {
                try await writer.retire(candidate.target)
                retired += 1
                await ctx.progress?
                    .log("✗ Retired “\(candidate.title)” — no longer holds in the current data")
                await ctx.ledger.recordRetirement(title: candidate.title)
                // The journal remembers the retirement across runs — the next run's fleet is
                // steered away from re-surfacing it, not just this one's.
                try? await writer.recordJournal(
                    kind: .retired, text: candidate.title,
                    reason: "no longer held against fresh data",
                    jobRunID: ctx.jobID, now: ctx.now
                )
            } catch {
                await ctx.progress?
                    .log("· Couldn't retire “\(candidate.title)” — it will be re-audited next refresh")
            }
        }
        return retired
    }
}
