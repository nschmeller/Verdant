import Foundation

// MARK: - The scout sweep (the discovery loop's agent phase)

nonisolated extension Orchestrator {
    /// One pass's scout sweep: rotating surveyor agents read the map of the data — coverage,
    /// strange days, horizons, missed links, data quality — and hand back testable leads, which the
    /// same pass's investigator fleet chases as extra lenses. Serial like every fan-out (each agent
    /// at full power), and steered away from leads already handed over this run.
    func runScoutSweep(
        _ ctx: DiscoveryContext,
        pass: Int,
        exhaustedBreadth: Bool
    ) async -> [ProposedLead] {
        guard let substrate = ctx.substrate else { return [] }
        let lenses = Instructions.scoutLenses(pass: pass)
        // Cross-run steering: scouts hunting "unvisited ground" should know what PRIOR runs
        // already ruled out, not just this run's leads (fetched once — it can't change mid-sweep).
        let priorRuns = await (try? writer.journalSteering(excludingRun: ctx.jobID, now: ctx.now)) ?? []
        var seen = Set<String>()
        var unique: [ProposedLead] = []
        for (index, lens) in lenses.enumerated() {
            if shouldStop(ctx.deadline) { break }
            await ctx.progress?.log("Scout \(index + 1)/\(lenses.count): \(lens)…")
            // Steer with the leads already handed over — recorded per scout below, so within a pass
            // scout 2 genuinely sees scout 1's leads — plus, when breadth ran dry, an explicit push
            // into fresh ground. The avoid-list is capped and truncated at record time (RunLedger);
            // it rides in a 4k window.
            // The covered ground travels as an `AvoidList` rather than being appended to the lens
            // string, so it renders as one labelled block at the END of the scout's prompt. The
            // dry-sweep push stays on the ANGLE, because it is a directive about where to look and
            // not an item to avoid.
            let avoid = await AvoidList(
                handedToInvestigators: ctx.ledger.recentLeads(),
                priorRunDeadEnds: priorRuns
            )
            var angle = lens
            if exhaustedBreadth {
                angle += "\nPrevious sweeps ran dry — hunt where no lens has looked: "
                    + "rare metrics, the oldest windows, the gaps."
            }
            let leads = await llm(ctx.deadline, progress: ctx.progress) {
                try await subagents.scout(
                    lens: angle, avoid: avoid, substrate: substrate, now: ctx.now
                )
            } ?? []
            // Order-insensitive dedup key (A↔B is the same lead), applied as each scout reports so
            // the ledger steering below carries every distinct lead forward immediately.
            let fresh = leads.filter { lead in
                let pair = [lead.metric, lead.secondaryMetric].sorted().joined(separator: "|")
                return seen.insert("\(pair)|\(lead.hypothesis.lowercased())").inserted
            }
            await ctx.ledger.recordLeads(fresh.map(\.hypothesis))
            unique.append(contentsOf: fresh)
            await ctx.progress?.log(
                fresh.isEmpty
                    ? "· Scout \(index + 1) found no new ground"
                    : "· Scout \(index + 1) hands over \(fresh.count): "
                    + fresh.map { String($0.hypothesis.prefix(60)) }.joined(separator: " · ")
            )
        }
        // EVERY distinct lead becomes a lens. There used to be a `prefix(maxLeadsPerPass)` here,
        // which dropped leads by ARRIVAL ORDER — scout 1's fourth idea always beat scout 2's first,
        // on no judgment at all. The width it was protecting is already bounded at the schema
        // (`maxLeadsPerScout` per scout × `scoutsPerPass`), and each lens is its own bounded session,
        // so more leads cost time, not context. Time spent reasoning is the point.
        return unique
    }

    /// The director's self-composed angles as investigator lenses. Same defensive treatment as a
    /// scout lead: model-written text with no schema-side length bound, riding into a 4k session.
    /// Blank entries are dropped — a director that had nothing to add says so by adding nothing,
    /// and an empty lens would otherwise spend a whole investigator session on no instruction.
    static func directorLenses(_ angles: [String]) -> [String] {
        angles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "an angle the research director chose for this pass: \(PromptText.clamped($0, to: 200))" }
    }

    /// Scout leads as investigator lenses — prompt text, truncated defensively (hypothesis AND
    /// metric keys are model-written strings with no schema-side length bound, and they ride into
    /// a 4k session).
    static func leadLenses(_ leads: [ProposedLead]) -> [String] {
        leads.map { lead in
            let metric = String(lead.metric.prefix(40))
            let secondary = String(lead.secondaryMetric.prefix(40))
            let pair = secondary != metric && !secondary.isEmpty ? " and \(secondary)" : ""
            return "chase this scout lead: \(PromptText.clamped(lead.hypothesis, to: 200)) — focus on "
                + "\(metric)\(pair); test it with the tools and propose only what the numbers confirm"
        }
    }
}
