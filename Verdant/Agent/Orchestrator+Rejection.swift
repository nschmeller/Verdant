import Foundation

// MARK: - How a rejection is narrated back to the fleet

/// Split out of `Orchestrator+Persist.swift` at the 500-line limit. It belongs together anyway: this
/// is the one place that turns a panel's verdict into the sentence three readers learn from — the
/// run ledger steering later investigators, the journal steering the next run, and the research
/// director, which is told it learns "what the panels rejected and why".
nonisolated extension Orchestrator {
    /// A rejection reason in the panel's own words, falling back to the tally when it said nothing.
    ///
    /// Clamped, because this rides into the ledger and the journal, and both ride into a 4k prompt —
    /// `RunLedger` truncates again at record time, but a reason should arrive already the size it
    /// means to be.
    /// The OBJECTION LEADS and the tally trails, which is not a style choice — it is the only way the
    /// sentence survives the trip.
    ///
    /// `JournalWriter.record` clamps `reason` to 90 characters at write time, and that journal is
    /// what steers the NEXT run. Written the other way round — "the skeptics rejected it (2/9
    /// skeptics held it up) — “…”" — the prefix alone eats about seventy of those ninety and the
    /// director inherits a tally plus eighteen characters of the actual objection. The panel's words
    /// are the part with information in them, so they go first and the bookkeeping takes whatever is
    /// left.
    static func rejection(by panel: String, outcome: PanelOutcome) -> String {
        let tally = "\(outcome.held)/\(outcome.rendered) \(panel) held it up"
        guard !outcome.headline.isEmpty else { return "the \(panel) rejected it — \(tally)" }
        return "“\(PromptText.clamped(outcome.headline, to: 140))” — \(tally)"
    }
}
