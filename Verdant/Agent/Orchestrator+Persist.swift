import Foundation

// MARK: - Persisting one agent-proposed finding

// The gauntlet a proposal runs between "an investigator named it" and "it is on the feed":
// novelty judge → safety panel (with its one rewrite) → embedding → per-kind number resolution →
// skeptic + replication panels → atomic novel-append.
//
// Every gate that can REJECT a finding on its merits is an agent decision — is it new, is it safe,
// is it true, does it replicate. That is the architectural commitment, and it is about vetoes.

/// Three steps are deterministic, and an earlier version of this line claimed there was one: number
/// resolution (the anti-hallucination boundary, and a gate), `affordsVetting` (a deadline, which
/// deliberately journals no rejection because nothing was judged), and the atomic append's novelty
/// window (a race guard; the novelty JUDGE above it already made the call). All three are plumbing —
/// time, races, and where numbers come from. RANKING is a separate question and only half agentic:
/// see `Orchestrator+Quality.swift`.
///
nonisolated extension Orchestrator {
    /// Everything one agent-proposed finding needs on its way to persistence — threaded through the
    /// per-kind persist helpers so each stays small and focused. `noveltyLookback` is the window the
    /// atomic append re-checks: 14 days normally, 0 when the novelty judge already cleared a
    /// collision (the standing finding then coexists until the curator weighs both).
    private struct Proposal {
        let finding: ProposedFinding
        let metric: MetricKey
        var phrasing: FindingPhrasing.Phrasing
        var embedding: Data?
        let substrate: AnalysisSubstrate
        let ctx: DiscoveryContext
        /// The investigator lens that proposed this — the first half of the finding's provenance
        /// ("which of the two dozen specialists found this?").
        let lens: String
        var noveltyLookback = Orchestrator.noveltyLookbackDays
    }

    /// How far back a candidate looks for the standing finding it might collide with. NOT a
    /// freshness gate: the window only SELECTS the prior finding; whether the candidate is a
    /// re-tread or a meaningful update is the novelty-judge agent's decision.
    static let noveltyLookbackDays = 14

    /// Every drop is narrated with its reason — so a run that vets many and keeps few reads as the
    /// rigorous filter it is, not as "the analysis stopped" — and recorded in the run's ledger so
    /// later investigators steer around it, and in the persistent journal so the NEXT run starts
    /// already knowing this dead end.
    private func drop(_ proposal: Proposal, _ reason: String) async -> Bool {
        await proposal.ctx.progress?.log("✗ Dropped “\(proposal.finding.title)” — \(reason)")
        await proposal.ctx.ledger.record(title: proposal.finding.title, reason: reason)
        try? await writer.recordJournal(
            kind: .rejected, text: proposal.finding.title, reason: reason,
            jobRunID: proposal.ctx.jobID, now: proposal.ctx.now
        )
        return false
    }

    /// Two-stage verification per proposal: the prose-skeptic panel first, then the ARMED
    /// replication panel that re-tests the claim against the data itself (analyze/unusualDays in
    /// the analysts' own hands). Skeptics catch bad reasoning; replication catches true-looking
    /// numbers that exist only in the window that produced them.
    /// Returns the finding's PROVENANCE line when both panels clear it, `nil` when either rejects.
    /// Recording the account rather than a bare pass is the point: the panels are the most expensive
    /// reasoning the app does, and until now their verdicts scrolled past in the live feed and were
    /// gone — the user could see THAT a finding survived scrutiny, never what it survived.
    private func survives(
        _ proposal: Proposal,
        basis: String,
        verified: [Double],
        // Dimensionless figures — sample sizes, lags, day and year counts. Kept apart from
        // `verified` because `NumericFidelity` expands the latter by unit factors, and a count
        // vouching for a coefficient is how a fabricated 0.9 used to pass. See that method's doc.
        counts: [Double] = [],
        subject: String,
        // The registry keys this claim is about, handed to the replication analysts so they re-test
        // the right series — see `survivesReplication`.
        metrics: [MetricKey]
    ) async -> String? {
        var claim = "\(proposal.phrasing.summary)\n\nVerified basis: \(basis)"
        // Engines inform, agents decide — applied to the finding's own prose. The arithmetic of
        // "does every stated figure match a verified one" is done deterministically (a small model
        // is poor at exactly this) and handed to the panel as a fact; whether an unsupported figure
        // is a hallucinated statistic or a harmless window reference is the skeptics' call.
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: proposal.phrasing.summary, basis: basis, verified: verified, counts: counts
        )
        if !unsupported.isEmpty {
            claim += "\n\nFigures stated in the prose that NO verified number supports: "
                + unsupported.joined(separator: ", ")
        }
        // Rejections carry the panel's OWN words. Every one of these used to record the same string,
        // "the verification panels rejected it", at six call sites — while `PanelOutcome.headline`,
        // the strongest objection the panel actually made, was computed right here and thrown away.
        // The app kept that sentence when a finding SURVIVED (the provenance line) and discarded it
        // when one died, which is the case that needs explaining and is very nearly all of them.
        //
        // Three things read the reason and all three were being fed nothing: `RunLedger` steers later
        // investigators in this pass with recent rejections, the journal steers the NEXT run, and the
        // research director's prompt says in as many words that it learns "what the panels rejected
        // and why". A constant string is not a why.
        let skeptics = await survivesScrutiny(claim, subject: subject, proposal.ctx)
        guard skeptics.passed else {
            _ = await drop(proposal, Self.rejection(by: "skeptics", outcome: skeptics))
            return nil
        }
        let replication = await survivesReplication(
            claim, subject: subject, metrics: metrics, substrate: proposal.substrate, proposal.ctx
        )
        guard replication.passed else {
            _ = await drop(proposal, Self.rejection(by: "replication analysts", outcome: replication))
            return nil
        }
        return Self.provenanceLine(
            lens: proposal.lens, skeptics: skeptics, replication: replication,
            verified: verified, counts: counts, basis: basis
        )
    }

    private func logKept(_ proposal: Proposal) async {
        await proposal.ctx.progress?.log("✓ Kept: \(proposal.phrasing.oneTapTitle)")
        // Confirmed findings enter the journal WITH the angle that produced them. Without the
        // angle the journal could only say what was established, never what kind of looking
        // establishes anything — so the research director, whose whole job is choosing where to
        // point the fleet next, had no way to learn that (say) lead-lag sweeps keep paying off
        // while volatility sweeps never do. It rides in `reason`, which is empty for confirmations
        // and is excluded from the do-not-repeat steering, so this adds a learning signal without
        // teaching the fleet to avoid its own successes.
        try? await writer.recordJournal(
            kind: .confirmed, text: proposal.phrasing.oneTapTitle, reason: proposal.lens,
            jobRunID: proposal.ctx.jobID, now: proposal.ctx.now
        )
    }

    /// Persist one agent-proposed finding. The numbers are resolved fresh from the single source of
    /// truth for whatever the agent named — so the shown figures are authoritative regardless of what
    /// the agent transcribed (the registry-resolving tool surface is the anti-hallucination boundary).
    /// No worth/materiality floor: the agent decided it was worth proposing; safety + the skeptic
    /// panel are the remaining, agent-run gates.
    /// False when the run can no longer afford to vet this proposal — and says so on the feed.
    ///
    /// Separated from the guard below and narrated, because it is not the same event as "there is
    /// nothing to resolve the numbers against" and it is not rare.
    ///
    /// Measured end to end against the real model: twelve investigators proposed twenty findings in
    /// 432 seconds against a 420-second budget, and every one died here. Not one panel convened — no
    /// skeptic, no replication, no safety — and the feed went from "Investigator 12 proposes 1: Body
    /// Mass and Sleep Duration Are Perfectly Synced" straight to "Keeping only the few findings
    /// worth your attention…", then showed nothing. Twenty findings gone, with no line anywhere
    /// saying so.
    ///
    /// It is the BACKGROUND on-power run that passes a deadline — the two foreground callers pass
    /// none — and `AppModel` describes that run as "the pass that spends the whole on-power window
    /// running agents". So an entire charging window can produce nothing and leave no record of why,
    /// on the one path nobody is watching.
    ///
    /// This logs it; it does not fix it. The run still spends its whole budget generating proposals
    /// it cannot afford to vet, and vetting is where the findings actually come from — roughly
    /// fourteen sessions per proposal against one to produce it. Reserving budget for the panels is
    /// a scheduling decision with a real trade behind it, so it is stated here and left to the owner
    /// rather than guessed at with a threshold.
    /// Reads as a condition inside the guard below so the branch count stays where it was — the
    /// function is at the complexity limit, and this check has to be one of its three conditions
    /// rather than a fourth.
    private func affordsVetting(_ finding: ProposedFinding, _ ctx: DiscoveryContext) async -> Bool {
        guard shouldStop(ctx.deadline) else { return true }
        // Counted, so the run's CLOSING note can see this too — a pass that dropped everything for
        // time otherwise reads as "a clean bill, not an empty one". Deliberately NOT recorded in the
        // journal as a rejection the way `drop` does: nothing was judged here, and teaching the
        // research director to avoid an angle it never got to test is worse than saying nothing.
        await ctx.progress?.noteDroppedForTime()
        await ctx.progress?.log(
            "✗ Dropped “\(finding.title)” — the run's time ran out before it could be vetted"
        )
        return false
    }

    func persistProposed(
        _ finding: ProposedFinding,
        lens: String,
        _ ctx: DiscoveryContext
    ) async -> Bool {
        // One guard, as before: this function sits at the complexity limit. The spent-budget case
        // is a condition here but NARRATES itself, which is the whole change — see `affordsVetting`.
        guard let substrate = ctx.substrate, await affordsVetting(finding, ctx),
              let metric = await resolvedMetric(finding, ctx)
        else { return false }
        let phrasing = FindingPhrasing.Phrasing(summary: finding.story, oneTapTitle: finding.title)
        await ctx.progress?.log("Investigating \(metric.displayName)…")
        var proposal = Proposal(
            finding: finding, metric: metric, phrasing: phrasing, embedding: nil,
            substrate: substrate, ctx: ctx, lens: lens
        )
        // Novelty FIRST — before the safety and skeptic panels, so a re-tread costs one judge
        // session instead of a full 14-session vetting. The lookback only selects the standing
        // finding; whether the candidate replaces it is the novelty judge's decision.
        let kind = InsightKind(rawValue: finding.kind) ?? .trend
        // KNOWN GAP (2026-08-02). `try?` collapses "the fetch threw" into "there is no standing
        // finding to compare against", and the `if let prior` below then skips the novelty judge
        // entirely — so a transient store error lets a re-tread onto the feed past the one guard that
        // exists to stop it.
        //
        // Falling open is the right trade and matches the panels: losing a good finding to
        // infrastructure is worse than showing a duplicate. What is wrong is that it happens in
        // silence, and the run cannot even report it because the two cases are the same value here.
        //
        // Not fixed rather than half-fixed: distinguishing them needs a throwing seam, and
        // `Orchestrator` holds a concrete `StoreWriter` — protocolising the writer to narrate one
        // rare failure would be a large refactor of the app's most load-bearing type, tested by
        // nothing that exists today. Recorded in ARCHITECTURE as an open item instead. The same
        // collapse is benign at the other `(try? writer…)` sites, which only omit steering or defer
        // work to the next round; this is the one where it skips a guard.
        let prior = await (try? writer.recentPriorDescriptor(
            kind: kind, metric: metric,
            secondaryMetric: MetricKey(rawValue: finding.secondaryMetric),
            comparison: ComparisonKey(rawValue: finding.comparison),
            within: Self.noveltyLookbackDays, now: ctx.now
        )).flatMap(\.self)
        if let prior {
            let verdict = await llm(ctx.deadline, progress: ctx.progress) {
                try await subagents.judgeNovelty(
                    candidate: "\(phrasing.oneTapTitle): \(phrasing.summary)", prior: prior
                )
            }
            guard verdict?.meaningfulUpdate == true else {
                return await drop(
                    proposal, "the novelty judge ruled it a re-tread of a standing finding"
                )
            }
            await ctx.progress?
                .log("· Novelty judge: a meaningful update on a standing finding — carrying it forward")
            proposal.noveltyLookback = 0
        }
        // Safety once, up front — the same agent panel for every kind. The refusal carries the
        // flagging reviewer's own sentence, not a constant: this is the gate that rejects most
        // often, so it is the fleet's main source of feedback about what the panels will not accept.
        // Safety once, up front — the same agent panel for every kind, plus the ONE rewrite it
        // allows. The measured bottleneck is not that the panel is strict but that the fleet writes
        // causes and alarm into findings whose numbers are fine, and the panel has just said which
        // words. See `safetyOutcome`; the bar itself is unchanged.
        let safety = await safetyOutcome(for: phrasing, deadline: ctx.deadline, progress: ctx.progress)
        guard let cleared = safety.clearedPhrasing else {
            return await drop(proposal, safety.refusalReason)
        }
        // `cleared` may be a REWRITE, in which case it is what the panels vet, what gets stored, and
        // what the user reads. The embedding is taken from it rather than from the original — and is
        // computed here rather than before the panel, so prose safety refuses is never vectorized.
        proposal.phrasing = cleared
        proposal.embedding = await embeddings.vector(for: cleared.summary)

        // Exhaustive, with no `default`. This router decides which SCAN a finding's numbers are
        // resolved from, so a kind that falls through is persisted with figures answering a
        // different question than its own prose — real numbers under a false claim, which the
        // anti-hallucination boundary does not catch because the numbers ARE from an engine. That
        // is precisely what a `default: persistTrendProposal` did to `seasonal` before it was
        // wired; naming every case is what stops the next detector repeating it.
        return switch kind {
        case .correlation: await persistCorrelationProposal(proposal)
        case .volatility: await persistVolatilityProposal(proposal)
        case .milestone: await persistMilestoneProposal(proposal)
        case .regimeShift: await persistRegimeProposal(proposal)
        case .seasonal: await persistSeasonalProposal(proposal)
        // The level-change kinds genuinely share the trend resolve. `redFlag` is a reserved raw
        // value the app no longer produces, and `none` never reaches here (the proposal is dropped
        // before this point) — but both are named so the switch stays a gate rather than a funnel.
        case .trend, .anomaly, .redFlag, .none: await persistTrendProposal(proposal)
        }
    }

    /// Run a store append, narrating a FAILURE rather than letting it look like a duplicate.
    ///
    /// `appendXIfNovel` returns nil for "not novel", and `try?` makes a thrown write return nil too —
    /// so a finding that cleared every panel and then failed to save was indistinguishable from one
    /// the novelty guard turned away, and produced no line at all. Every other outcome on this path
    /// narrates itself (`logKept`, `drop`), so silence here is the one gap in a feed whose rule is
    /// that it states what is happening.
    ///
    /// One helper rather than six `do`/`catch` blocks: the alternative is the same five lines copied
    /// per finding kind, which is the duplication this codebase spends most of its defects on.
    private func saved<Value>(
        _ kind: String, _ ctx: DiscoveryContext, _ append: () async throws -> Value?
    ) async -> Value? {
        do {
            return try await append()
        } catch {
            await ctx.progress?.log(
                "✗ A verified \(kind) finding could not be saved — it will be re-derived next run."
            )
            return nil
        }
    }

    /// The registry resolve IS the anti-hallucination boundary — `ProposedFinding.metric` carries
    /// no `.anyOf`, because the full key vocabulary in the output schema blew the 4k budget on
    /// device (see that type). So an unresolvable key is expected traffic, not an impossibility,
    /// and it is now SAID rather than dropped in silence.
    ///
    /// Not hypothetical: driving the real on-device model over seeded data, one proposal in three
    /// named the metric "steps" where the registry key is "stepCount". That proposal vanished with
    /// no line in the feed and no way to know the boundary had fired — the same silence a failed
    /// save had, and the only signal anyone gets about how often the model invents a key.
    private func resolvedMetric(_ finding: ProposedFinding, _ ctx: DiscoveryContext) async -> MetricKey? {
        guard let metric = MetricKey(rawValue: finding.metric) else {
            await ctx.progress?.log(
                "✗ Dropped “\(PromptText.clamped(finding.title, to: 60))” — “\(finding.metric.prefix(40))” is not a "
                    + "metric this app tracks."
            )
            return nil
        }
        return metric
    }

    private func persistCorrelationProposal(_ p: Proposal) async -> Bool {
        // The agent named a pair; the numbers come from the engine's scan (it can only surface a
        // pair the engine actually found — the closed, recomputable boundary).
        guard let other = MetricKey(rawValue: p.finding.secondaryMetric), other != p.metric
        else { return await drop(p, "not a valid metric pair") }
        let pairKey = [p.metric.rawValue, other.rawValue].sorted().joined(separator: "|")
        guard let corr = await p.substrate.correlationScan().correlations
            .first(where: { $0.pairKey == pairKey })
        else { return await drop(p, "the statistical engine computed no link for this pair") }
        guard let provenance = await survives(
            p, basis: corr.verifiedBasis,
            // The figures the engine actually computed — the basis prose renders only some of them,
            // so the check needs the values themselves (see `NumericFidelity`).
            // `pValue` keeps its unit factors: "p is about 1%" for 0.01 is a legitimate restatement.
            // `nEff` does not — an effective sample size is a count, however fractional it is.
            verified: [corr.r, corr.partialR, corr.spearman, corr.pValue],
            // `monotoneAgreement` is now stated in the basis, so prose may legitimately quote it.
            // Passed explicitly as well: basis parsing is a supplement, and a figure the panels are
            // invited to reason about should not depend on a sentence continuing to render it.
            // The thirds are passed rather than left to basis parsing: the "this link faded" prose
            // the changed-relationships lens invites quotes them, and depending on a sentence in
            // another file to keep those findings supportable is a dependency waiting to break.
            counts: [Double(corr.n), Double(corr.lag), corr.nEff, corr.monotoneAgreement]
                + corr.thirdsR,
            subject: "\(p.metric.displayName) ↔ \(other.displayName)",
            metrics: [p.metric, other]
        ) else { return false }
        let quality = Self.qualityScore(
            worth: p.finding.worth, strength: corr.trustStrength * 100, worthWeight: 0.55
        )
        let id = await saved("correlation", p.ctx) { try await writer.appendCorrelationIfNovel(
            corr, phrasing: p.phrasing, quality: quality, embedding: p.embedding, provenance: provenance,
            jobRunID: p.ctx.jobID, within: p.noveltyLookback, now: p.ctx.now
        ) }
        if id != nil {
            await logKept(p)
            // The live card counts cross-signal links surfaced. Nothing incremented it, so the chip
            // read 0 for the life of every run — see `reportPairsTested`.
            await p.ctx.progress?.apply { $0.correlationsSurfaced += 1 }
        }
        return id != nil
    }

    /// An annual-rhythm finding, resolved from `SeasonalityScan` at persist time like every other
    /// pattern kind — the agent names the finding, the engine supplies every number.
    private func persistSeasonalProposal(_ p: Proposal) async -> Bool {
        guard let swing = await p.substrate.seasonality().first(where: { $0.metric == p.metric })
        else { return await drop(p, "no repeating annual rhythm in this metric") }
        guard let provenance = await survives(
            p,
            basis: swing.verifiedBasis,
            verified: [
                swing.peakEffect, swing.oppositeEffect, swing.amplitude, swing.swingInUnits
            ],
            counts: [
                Double(swing.monthsCompared), Double(swing.yearsObserved),
                Double(swing.yearsAgreeing)
            ],
            subject: "the yearly rhythm in \(p.metric.displayName)", metrics: [p.metric]
        )
        else { return false }
        // Scaled by the swing AND by how many years actually agreed: a two-year pattern that both
        // years shared is worth more than a three-year one where only two did. Still only an input —
        // the curator agent decides what keeps a feed slot.
        let agreement = swing.yearsObserved > 0
            ? Double(swing.yearsAgreeing) / Double(swing.yearsObserved)
            : 0
        let magnitude = min(100, swing.amplitude * 40 * agreement)
        let quality = Self.qualityScore(worth: p.finding.worth, strength: magnitude, worthWeight: 0.6)
        let id = await saved("seasonal", p.ctx) { try await writer.appendSeasonalIfNovel(
            swing, phrasing: p.phrasing, quality: quality, embedding: p.embedding,
            provenance: provenance, jobRunID: p.ctx.jobID, within: p.noveltyLookback, now: p.ctx.now
        ) }
        if id != nil { await logKept(p) }
        return id != nil
    }

    private func persistVolatilityProposal(_ p: Proposal) async -> Bool {
        guard let shift = await p.substrate.volatility().first(where: { $0.metric == p.metric })
        else { return await drop(p, "no significant volatility shift in this metric") }
        guard let provenance = await survives(
            p,
            basis: shift.verifiedBasis,
            // The mean-shift percentage goes in `verified`, not `counts`: a percentage is exactly the
            // case unit factors exist for, since prose may legitimately restate 20% as 0.20.
            verified: [
                shift.recentSD, shift.baselineSD, shift.recentMean, shift.baselineMean,
                shift.cvRatio, shift.sdRatio, shift.seZ
            ] + [shift.meanShiftPercent].compactMap(\.self),
            counts: [Double(shift.n)],
            subject: "the swing in \(p.metric.displayName)", metrics: [p.metric]
        )
        else { return false }
        let magnitude = min(100, abs(Foundation.log(shift.cvRatio)) * 60)
        let quality = Self.qualityScore(worth: p.finding.worth, strength: magnitude, worthWeight: 0.6)
        let id = await saved("volatility", p.ctx) { try await writer.appendVolatilityIfNovel(
            shift, phrasing: p.phrasing, quality: quality, embedding: p.embedding, provenance: provenance,
            jobRunID: p.ctx.jobID, within: p.noveltyLookback, now: p.ctx.now
        ) }
        if id != nil { await logKept(p) }
        return id != nil
    }

    private func persistMilestoneProposal(_ p: Proposal) async -> Bool {
        guard let milestone = await p.substrate.milestones().first(where: { $0.metric == p.metric })
        else { return await drop(p, "no record-setting stretch in this metric") }
        guard let provenance = await survives(
            p,
            basis: milestone.verifiedBasis,
            verified: [
                milestone.recentMean, milestone.relativeMargin, milestone.relativeMargin * 100
            ],
            counts: [Double(milestone.spanDays)],
            subject: "the \(p.metric.displayName) record", metrics: [p.metric]
        )
        else { return false }
        let strength = min(100.0, milestone.relativeMargin * 300)
        let quality = Self.qualityScore(worth: p.finding.worth, strength: strength, worthWeight: 0.6)
        let id = await saved("milestone", p.ctx) { try await writer.appendMilestoneIfNovel(
            milestone, phrasing: p.phrasing, quality: quality, embedding: p.embedding, provenance: provenance,
            jobRunID: p.ctx.jobID, within: p.noveltyLookback, now: p.ctx.now
        ) }
        if id != nil { await logKept(p) }
        return id != nil
    }

    private func persistRegimeProposal(_ p: Proposal) async -> Bool {
        guard let shift = await p.substrate.regimes().first(where: { $0.metric == p.metric })
        else { return await drop(p, "no sustained baseline step in this metric") }
        guard let provenance = await survives(
            p,
            basis: shift.verifiedBasis,
            verified: [shift.preMean, shift.postMean, shift.score, shift.medianStepSD],
            counts: [Double(shift.postDays)],
            subject: "the shift in \(p.metric.displayName)", metrics: [p.metric]
        )
        else { return false }
        let strength = min(100.0, shift.score * 25)
        let quality = Self.qualityScore(worth: p.finding.worth, strength: strength, worthWeight: 0.6)
        let id = await saved("regime-shift", p.ctx) { try await writer.appendRegimeShiftIfNovel(
            shift, phrasing: p.phrasing, quality: quality, embedding: p.embedding, provenance: provenance,
            jobRunID: p.ctx.jobID, within: p.noveltyLookback, now: p.ctx.now
        ) }
        if id != nil { await logKept(p) }
        return id != nil
    }

    /// trend / anomaly — a single-metric change. The card's numbers are resolved from source for the
    /// named (metric, comparison), so the agent names a metric and never a figure. Its prose is
    /// another matter — `survives` passes `fact`'s real values to `NumericFidelity` two lines below
    /// precisely because the story CAN state a figure nothing supports.
    private func persistTrendProposal(_ p: Proposal) async -> Bool {
        guard let comparison = ComparisonKey(rawValue: p.finding.comparison),
              let stat = try? await provider.stat(for: p.metric, comparison: comparison, now: p.ctx.now),
              let fact = MaterialityRules.buildFact(stat: stat, requestedSalience: p.finding.worth)
        else { return await drop(p, "the numbers couldn't be resolved confidently from source") }
        guard let provenance = await survives(
            p, basis: fact.verifiedBasis,
            // `VerifiedFact.verifiedBasis` prints only the % shift, day count and z — never the
            // means, which are exactly what a trend finding's prose quotes.
            verified: [fact.recent, fact.baseline, fact.pctChange, fact.z],
            counts: [Double(fact.n)],
            subject: p.metric.displayName, metrics: [p.metric]
        )
        else { return false }
        let id = await saved("trend", p.ctx) { try await writer.appendInsightIfNovel(
            fact: fact, phrasing: p.phrasing, embedding: p.embedding, provenance: provenance,
            jobRunID: p.ctx.jobID,
            within: p.noveltyLookback, now: p.ctx.now
        ) }
        if id != nil { await logKept(p) }
        return id != nil
    }
}
