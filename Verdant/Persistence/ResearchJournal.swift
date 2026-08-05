import Foundation
import SwiftData

/// One entry in the agent fleet's persistent **research journal** — the cross-RUN memory of what
/// has already been tried: hypotheses the panels rejected (and why), findings the audit retired,
/// findings that survived every panel, and angles that were chased and yielded nothing. The
/// in-memory `RunLedger` steers agents within one run and dies with it; this journal is what lets
/// the NEXT run iterate instead of re-litigating the same dead ends from scratch. Append-only and
/// pruned to a bounded row count (like everything else in the store, it is a derived cache of the
/// fleet's own work).
@Model
final class ResearchJournalEntry {
    var createdAt: Date
    /// `ResearchJournalKind` raw value: `"rejected"`, `"retired"`, `"confirmed"`, or `"barren"`.
    var kind: String
    /// The claim/title in question — clamped at write time (it is model-written text, and journal
    /// lines ride inside future 4k-token prompts).
    var text: String
    /// Why it was rejected/retired, or how a barren angle came up empty; empty for confirmed.
    var reason: String
    /// The run that wrote it, so steering can exclude the CURRENT run (the in-memory ledger
    /// already covers it).
    var jobRunID: UUID

    init(createdAt: Date, kind: String, text: String, reason: String, jobRunID: UUID) {
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.reason = reason
        self.jobRunID = jobRunID
    }
}

/// What happened to a claim — the journal's closed vocabulary, and the one the `researchJournal`
/// tool offers the research director. Declaration order is the order the model sees.
nonisolated enum ResearchJournalKind: String, CaseIterable {
    case confirmed, rejected, retired
    /// An angle a real investigator session CHASED and that produced no proposal at all. The other
    /// three kinds all record something that WAS proposed, so cross-run learning about where to look
    /// was positive-only: an angle could come back empty every run and leave no trace, and the next
    /// run's scouts would re-propose it with no way to know. Unlike `rejected`/`retired`, this is
    /// deliberately NOT pushed at agents as "do not re-propose" — barren ground can bear fruit once
    /// more data arrives, so it is offered to the research director as a fact to weigh.
    case barren

    /// The vocabulary as the tool's `.anyOf` guide states it. Derived, never re-typed: a hand-written
    /// list is a silent drift waiting to happen — add a kind, forget the guide, and the director can
    /// never ask for it (nothing fails, the history is just invisible).
    static let allRawValues = allCases.map(\.rawValue)
}
