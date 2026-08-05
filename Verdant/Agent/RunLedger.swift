import Foundation

/// One run's working memory across its serial agents: hypotheses the panels rejected, leads the
/// scouts already handed over, and findings the audit retired. Injected into later prompts so the
/// fleet ITERATES — a rejected hypothesis steers the next investigator somewhere new instead of
/// being re-proposed and burning another full panel on the same dead end.
actor RunLedger {
    private var rejected: [String] = []
    private var leads: [String] = []
    private var retired: [String] = []

    /// Both halves are clamped, and the reason only recently needed it.
    ///
    /// The title is model-written (the "3-6 word" guide is advisory only) and has been clamped all
    /// along. The reason was a 34-character constant, so nobody bounded it — then rejections started
    /// carrying the panel's actual objection and the same four entries grew by roughly 750
    /// characters. Measured: the assembled `directorState` went to 2,882 against a 2,600 bound, and
    /// `DirectorStateSizeTests` did not notice because its fixture still used the old constant.
    ///
    /// 95 keeps the objection's opening — which is why `Orchestrator.rejection` leads with it — and
    /// leaves the ring inside the EXISTING budget four entries deep (2,590 against 2,600). Raising
    /// that bound was the other option and the director has the tokens spare, but a budget someone
    /// reasoned about should not move because a new field arrived; the field fits instead.
    /// Everything here rides in every subsequent investigator prompt, out of a 4,096-token window.
    func record(title: String, reason: String) {
        rejected.append("\(PromptText.clamped(title, to: 80)) (\(PromptText.clamped(reason, to: 95)))")
        if rejected.count > 24 { rejected.removeFirst(rejected.count - 24) }
    }

    /// The most recent rejections, oldest first, capped tightly — this text rides in every
    /// subsequent investigator prompt inside a 4k-token window.
    func recentRejections(limit: Int = 6) -> [String] {
        Array(rejected.suffix(limit))
    }

    /// Leads already handed to investigators this run, so later scouts hunt NEW ground instead of
    /// re-proposing. Hypotheses are truncated at record time — they are model-written sentences,
    /// and this ring rides inside every scout prompt.
    func recordLeads(_ hypotheses: [String]) {
        leads.append(contentsOf: hypotheses.map { PromptText.clamped($0, to: 100) })
        if leads.count > 24 { leads.removeFirst(leads.count - 24) }
    }

    func recentLeads(limit: Int = 8) -> [String] {
        Array(leads.suffix(limit))
    }

    /// Findings the audit RETIRED this run. Deliberately its own ring (not the rejection ring): the
    /// novelty guards ignore tombstoned rows, so the only brake on re-proposing a just-retired
    /// finding is this steering — it must not be evicted by ordinary rejections in a long run.
    func recordRetirement(title: String) {
        retired.append(PromptText.clamped(title, to: 80))
        if retired.count > 16 { retired.removeFirst(retired.count - 16) }
    }

    func retirements(limit: Int = 12) -> [String] {
        Array(retired.suffix(limit))
    }
}
