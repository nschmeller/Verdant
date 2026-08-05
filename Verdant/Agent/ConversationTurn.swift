import Foundation

/// One completed exchange on the Ask screen.
///
/// The screen has always kept a transcript and rendered it as a conversation; until now nothing was
/// replayed into either Q&A session, so the app showed a conversation and the model answered a
/// series of unrelated questions. Asking "How have my steps been?" and then "Why?" sent the agent
/// the word "Why?" with no referent — it could only guess or decline, in a UI that had just implied
/// it would know.
///
/// Withholding the transcript was a deliberate choice to protect the 4,096-token window, and that
/// constraint is real. What changes here is only its severity: replaying a hard-clamped tail of the
/// conversation costs a bounded few hundred tokens, where replaying the whole thing would grow
/// without limit and eventually kill the session mid-answer.
/// Only `Instructions.answerer` is told this may arrive. `Instructions.explorer` — which the gather
/// pass runs on — is deliberately left alone: it is SHARED with the investigator's explore pass,
/// where no conversation exists, and its prefix has already had to give up a tool once to stay under
/// the harness bound. The gather pass gets the context in its prompt instead, which is where it is
/// needed to turn "why?" into something measurable.
nonisolated struct ConversationTurn: Equatable {
    let question: String
    let answer: String
}

nonisolated extension ConversationTurn {
    /// Exchanges replayed. Two, not more: the referents a follow-up actually reaches for ("why?",
    /// "what about last month?") live in the immediately preceding turn, while older ones cost the
    /// same tokens to carry and are far likelier to mislead the gather pass into measuring something
    /// the user has moved on from.
    static let maxReplayed = 2
    /// Characters kept per side of an exchange. An answer runs longer than this, so it is the tail
    /// that gets cut — the question is what a follow-up refers to, and the answer's opening sentence
    /// is what it usually refers to WITHIN.
    static let maxCharacters = 220

    /// The clamped tail of a conversation, or `nil` when there is nothing to replay.
    ///
    /// Rendered here rather than at the two call sites because both Q&A passes need the identical
    /// text: the gather pass has to resolve "why?" into something measurable BEFORE it can choose a
    /// tool, and the answering pass needs the same context or it writes a reply that does not follow
    /// from the question it was asked. Two hand-built strings would be two clamps to keep in
    /// agreement, and this codebase's most productive defect class is exactly that drift.
    static func context(_ history: [ConversationTurn]) -> String? {
        let recent = history.suffix(maxReplayed).filter {
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !recent.isEmpty else { return nil }
        let lines = recent.map { turn in
            "Q: \(turn.question.prefix(maxCharacters))\nA: \(turn.answer.prefix(maxCharacters))"
        }
        return "Earlier in this conversation:\n" + lines.joined(separator: "\n")
    }
}
