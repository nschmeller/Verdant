import Foundation

/// What a verification panel decided — kept whole instead of collapsed to a `Bool` the instant it is
/// computed. The panels are the most expensive reasoning in the app and their verdicts carry the
/// clearest account of WHY a finding is on the feed, so the tally and the panelists' own words are
/// recorded with the finding (`InsightLog.provenance`) rather than narrated once and lost.
nonisolated struct PanelOutcome {
    let passed: Bool
    /// Panelists who held the finding up, out of those who rendered a verdict at all (a
    /// rate-limited call renders none and is excluded from both counts).
    let held: Int
    let rendered: Int
    /// Whether sessions were actually ISSUED. Distinguishes "the panel ran and nothing came back"
    /// from "the panel never ran", which `rendered == 0` alone cannot — and they are different facts
    /// to tell a person about a finding that is on their feed.
    let convened: Bool
    /// The single most useful sentence the panel produced: the strongest objection when it knocked
    /// the finding down, otherwise the strongest reason it survived.
    let headline: String

    /// The gate is off (a test seam) or the panel was never convened — nothing to record.
    static let notConvened = PanelOutcome(
        passed: true, held: 0, rendered: 0, headline: "", convened: false
    )
    /// The budget was spent before a single session could be issued: fails closed, says nothing.
    static let outOfBudget = PanelOutcome(
        passed: false, held: 0, rendered: 0, headline: "", convened: false
    )

    /// Summarize the verdicts that actually rendered. `passed` is `panelHolds`' decision, so the
    /// aggregation rule stays in exactly one place.
    init(_ rendered: [Verdict]) {
        let verdict = Orchestrator.panelHolds(rendered)
        // Quote the side that decided it: the objection if it fell, the endorsement if it stood.
        let deciding = rendered.filter { $0.holdsUp == verdict }
        self.rendered = rendered.count
        held = rendered.count(where: \.holdsUp)
        passed = verdict
        headline = deciding.map(\.why).first { !$0.isEmpty } ?? ""
        // Sessions were issued to reach this initializer, whether or not any of them answered.
        convened = true
    }

    private init(passed: Bool, held: Int, rendered: Int, headline: String, convened: Bool) {
        self.passed = passed
        self.held = held
        self.rendered = rendered
        self.headline = headline
        self.convened = convened
    }

    /// One clause for the finding's provenance line, e.g. `"5/6 skeptics held it up"`.
    ///
    /// A convened panel that rendered NOTHING says so rather than staying silent. The panels fall
    /// open in that case — a wholly rate-limited run keeps its finding rather than losing it to
    /// infrastructure, which is the right trade — but the finding then reaches the feed beside copy
    /// promising it was "put through a panel of independent skeptics and analysts", with an empty
    /// provenance line as the only hint. A silent omission is indistinguishable from a detail nobody
    /// bothered to record, and this is the one case where a person should trust a finding less.
    func clause(_ noun: String) -> String? {
        guard convened else { return nil }
        guard rendered > 0 else { return "no \(noun) could be reached" }
        return "\(held)/\(rendered) \(noun) held it up"
    }
}

extension Orchestrator {
    /// The distinct ways a finding most often fails. Giving each skeptic its own lens catches
    /// failure modes that identical reviewers would all miss together — diversity beats redundancy.
    /// A finding must clear a majority of these challenges to survive.
    ///
    /// MEASURED 2026-08-03, and the numbers say this panel is not currently a filter. Two claims
    /// were put through it: a clean 4.5 SD regime shift with no caveats firing, and a correlation
    /// that failed multiple-comparison correction (p = 0.42) and flipped sign across thirds. Three
    /// runs each, nine reviewers per run (six fixed lenses plus the challenger's composed ones):
    ///
    ///     STRONG   1/9, 1/9, 3/9    — never passed
    ///     WEAK     3/9, 0/9, 1/9    — never passed
    ///
    /// Five of nine are needed. A per-lens hold rate around 19% puts a strict majority near 1%, so
    /// the panel rejects essentially everything and barely distinguishes the two claims (19% vs 15%
    /// is noise at this sample size). Per-lens measurement found no single bad lens to blame — the
    /// rates are uniformly low.
    ///
    /// The compounding is the point, and it is visible in the instruction each reviewer gets: "Set
    /// holdsUp to true ONLY if it clearly survives … when in doubt, false." Every lens is told to
    /// default to no, and then a MAJORITY of no-defaulters is required to say yes. The per-agent bar
    /// and the aggregation rule push the same direction and multiply.
    ///
    /// CONFIRMED end to end on 2026-08-03, after every other gate was improved. A full run over six
    /// metrics with real structure, given budget enough to vet (623 s):
    ///
    ///     11 proposals reached the safety panel
    ///      5 passed it (45%) — that panel's lens rewrites worked; it was ~14% the same morning
    ///      4 reached the skeptics
    ///      0 passed them: 5 holds across 36 verdicts, a 14% per-lens rate
    ///      0 ever reached the replication panel
    ///
    /// So this panel is now the binding constraint on the whole app, and the replication analysts —
    /// the only reviewers with tools, and the ones fixed this session to complete re-tests at all —
    /// never convene.
    ///
    /// CORRECTION. This paragraph first claimed the rejections were built on invented numbers, and
    /// two of its three examples were wrong — checked afterwards against the bases themselves.
    /// "The observed shift of 0.1 standard errors from no-change" is a VERBATIM quotation:
    /// `VolatilityShift.verifiedBasis` prints "the shift is %.1f standard errors from no-change", and
    /// it recurred across findings because several weak volatility shifts really did have seZ near
    /// 0.1. "The claim of a correlation of r = 1.0" was a skeptic REBUTTING a finding titled "Body
    /// Mass and Sleep Duration Are Perfectly Synced" — objecting to an overclaim, which is its job.
    /// Both are the panel doing exactly what it is told: "trust those numbers and reason WITH them".
    ///
    /// What survives is narrower and still real. "The confidence interval includes zero" appears in
    /// no basis the app produces, and the lens removed this session invented a COUNTERFACTUAL —
    /// "removing the extreme outliers would result in a much lower effect size of 1.2 standard
    /// deviations" — which is a computation, not a reading, and needs tools this panel does not
    /// have. Asking a tool-less reviewer to recompute is the defect; asking it to weigh figures the
    /// basis already states is not.
    ///
    /// Deliberately not retuned here. Which knob moves — the per-lens bar, the majority rule, the
    /// lens count, or giving these reviewers the tools their questions require — changes what the app
    /// is willing to show a person about their health, and that is the owner's call. The same shape
    /// governs the safety panel; see `passesSafety`.
    static let scrutinyLenses = [
        "Is this trivial or obvious — something the user could already see at a glance in the Apple "
            + "Health app (a single metric's average moving up or down, a predictable weekday/weekend "
            + "gap, an expected record after obvious effort), or a physiological tautology (moving more "
            + "raises heart rate and burns energy — of course those track)? If so, it does not belong here.",
        "Could this easily be coincidence, noise, or a small-sample fluke rather than a durable pattern?",
        "Could this be a measurement artifact or fully explained by something mundane — a device change, "
            + "more activity, or the time of year?",
        "Is the effect actually meaningful in size, or technically real but so small it changes nothing?",
        "Is there a simpler or reverse explanation — could the causation run the other way, or a third "
            + "factor drive both — making the framing misleading?",
        // "Would this still hold if the few most extreme days were removed, or does it rest on a
        // handful of outliers?" used to sit here, and was removed on measurement.
        //
        // A skeptic holds NO tools. It sees prose and a basis line, and this question cannot be
        // answered from either — so a reviewer that takes it seriously has to invent the answer, and
        // did: asked it about a clean 4.5 SD regime shift, one replied "removing the extreme outliers
        // (days 1 and 2) would result in a much lower effect size of 1.2 standard deviations". There
        // are no days 1 and 2 in a prose summary and there is no 1.2 anywhere. That fabricated figure
        // then rides into the finding's provenance line, quoted to the user as the panel's reasoning.
        //
        // The check itself is not lost — it is `replicationLenses[1]`, put to analysts who carry
        // `unusualDays` and `analyze` and can actually compute it. Asking it of the panel that cannot
        // was the category error.
        //
        // Stated plainly because it cuts the other way too: this lens held 0 of 3 on a strong finding
        // and 3 of 3 on a weak one, so dropping it mechanically raises the panel's pass rate. That is
        // a side effect, not the reason. The reason is that a tool-less agent asked to compute will
        // make something up, and this app's whole boundary is that the model never derives a number.
        // Numeric fidelity. The registry resolve makes the METRIC unforgeable and the shown figures
        // are re-read from source, but the summary PROSE is free text the model writes — a figure
        // mistyped or invented there reaches the user unchecked. The schema only asks it not to;
        // this asks someone to look.
        "Numeric honesty: does every figure and direction in the prose match the Verified basis? If "
            + "the claim lists figures NO verified number supports, judge each — a rounded or "
            + "window reference (\"the last 30 days\") is fine, but a statistic that appears nowhere "
            + "in the verified numbers is invented and fails this outright, however good the "
            + "insight reads."
    ]

    /// Adversarial gate: a finding that has already cleared its story gate and safety vet must
    /// additionally survive a panel of independent skeptics, each attacking it from a different angle
    /// (`scrutinyLenses`). We keep it only on a strict majority "holds up". This is the backstop
    /// against the model's own `worthTelling` self-judgment running over-eager, and it guards every
    /// user-visible finding. Returns `true` immediately only when the gate is off (`adversarial ==
    /// false`, a test seam).
    ///
    /// Two failure modes, deliberately handled oppositely:
    ///  - **Budget spent** (`shouldStop`): we never even ran the panel, so we have *not* established
    ///    the finding clears the bar. The product's rule is "when in doubt, leave it out", and every
    ///    run re-derives its findings — so we drop it (fail **closed**) and let the next, unhurried
    ///    run vet and surface it. Showing an unvetted finding to protect availability is the wrong
    ///    trade for an app whose whole promise is that everything shown is exceptional.
    ///  - **Infra blip** (a skeptic call → `nil` from rate-limit/transient error): that's not a
    ///    quality judgment, and the finding already proved the model was working when it was phrased
    ///    and safety-vetted. Failed votes are discarded; we fall **open** only when *no* skeptic
    ///    rendered a verdict at all — because a single rendered verdict, even a lone "reject", IS a
    ///    quality judgment and must be honored (a rate-limited run that thins the panel to one reject
    ///    must not silently keep a finding the skeptic killed).
    func survivesScrutiny(_ story: String, subject: String, _ ctx: DiscoveryContext) async -> PanelOutcome {
        guard ctx.adversarial else { return .notConvened }
        guard !shouldStop(ctx.deadline) else { return .outOfBudget }
        // Size the panel to the CLAIM. The six fixed lenses are the failure modes every finding
        // shares; an agent that has actually read this one proposes the challenges they'd miss, and
        // each becomes another skeptic. Strictly additive — a challenger that goes quiet (or fails)
        // leaves the panel exactly as it was, so this can only ever deepen scrutiny.
        let composed = await llm(ctx.deadline, progress: ctx.progress) {
            try await subagents.composeChallenges(finding: story)
        }
        let extra = Self.composedChallenges(composed?.challenges ?? [])
        if !extra.isEmpty {
            await ctx.progress?.log(
                "· Challenger added \(extra.count) question\(extra.count == 1 ? "" : "s") for this finding"
            )
        }
        let lenses = Self.scrutinyLenses + extra
        let total = lenses.count
        await ctx.progress?.log(
            "Skeptic panel: \(total) challenges to \(subject) — trivial? coincidence? artifact? "
                + "too small? reversed? outliers?"
        )
        let verdicts = await concurrentMap(
            Array(lenses.enumerated()),
            maxConcurrent: EnhancementPolicy.maxConcurrentSubagents
        ) { index, lens -> Verdict? in
            let verdict = await llm(ctx.deadline, progress: ctx.progress) {
                try await subagents.scrutinize(finding: story, lens: lens)
            }
            if let verdict {
                // The verdict's reasoning is narrated, not discarded — the user sees WHY each
                // skeptic ruled, and a knock-down's strongest objection is visible in the feed.
                await ctx.progress?.log(
                    "· Skeptic \(index + 1)/\(total): "
                        + "\(verdict.holdsUp ? "holds up" : "knocks it down")"
                        + (verdict.why.isEmpty ? "" : " — \(String(verdict.why.prefix(110)))")
                )
            }
            return verdict
        }
        return PanelOutcome(verdicts.compactMap(\.self))
    }

    /// The panel's verdict over the skeptics that actually rendered one (failed/`nil` votes already
    /// dropped). Fall **open** ONLY when nothing rendered (a pure infra failure) — a single rendered
    /// verdict, even a lone "reject", is a real quality judgment and counts. Otherwise a *strict*
    /// majority of the rendered verdicts must hold it up; a tie rejects, in keeping with "when in doubt,
    /// leave it out". Pure so the exact thresholds — the empty-only fall-open and the tie-rejects
    /// boundary that a `>`→`>=` slip would silently flip — are locked in by tests.
    /// The challenger's questions as skeptic lenses. Same defensive treatment as every other
    /// model-written string that rides into a 4k session: trimmed, blanks dropped (an empty lens
    /// would spend a whole skeptic session on no question), and clamped.
    nonisolated static func composedChallenges(_ challenges: [String]) -> [String] {
        challenges
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { PromptText.clamped($0, to: 220) }
    }

    /// MEASURED 2026-08-03, and there is no quorum here — which now matters more than it did.
    ///
    /// A majority of RENDERED verdicts was safe while "rendered" meant "the call came back": a panel
    /// of five losing one to a rate limit still needed three of four. Widening `Verdict.couldTest`
    /// this session — so an analyst that could not test the claim abstains instead of refuting it —
    /// made abstention common, and abstentions are excluded from both counts. The tail is a panel of
    /// five in which four abstain and the fifth holds: 1 of 1, a strict majority, finding surfaced.
    ///
    /// Not hypothetical. Scoring the replication panel on a claim the data does NOT support ("your
    /// sleep has been getting steadily longer" against a flat series), three runs went 1/3, **1/1 —
    /// PASSED**, and 2/4. The only pass in the set was the run where one analyst spoke.
    ///
    /// Deliberately not fixed here. A quorum is another aggregation rule, and the measurements on
    /// this stack say the aggregation rules are already the binding constraint — adding one more
    /// without deciding the others is how a system ends up strict in the places nobody chose. The
    /// widened `couldTest` is still right on its own terms: counting "I could not test this" as
    /// evidence against a finding was worse. Both belong in the same decision.
    nonisolated static func panelHolds(_ rendered: [Verdict]) -> Bool {
        guard !rendered.isEmpty else { return true }
        return rendered.count(where: { $0.holdsUp }) * 2 > rendered.count
    }
}
