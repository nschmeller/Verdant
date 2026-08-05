import Foundation

/// Every sentence Verdant says to a person when it cannot give them the answer they asked for.
///
/// Gathered in one file because they are a set and only make sense as one: each names a DIFFERENT
/// reason, and the value of any of them is that it is not one of the others. Kept together, a new
/// failure path that reuses an existing string is visible; scattered, that is exactly what happened
/// — one message covered three outcomes for a while.
nonisolated extension Orchestrator {
    /// Honest, state-specific reason the Ask tab can't answer — the chat is reachable on every device,
    /// so a single "once it's ready" line would falsely promise a future to someone on hardware that can
    /// never run Apple Intelligence. Mirrors the per-state copy the feed/banner already use.
    static func unavailableAnswer(_ capability: LLMCapability) -> String {
        switch capability {
        case .available:
            "On-device intelligence is available — ask about any of your tracked health metrics."
        case .downloading:
            "Apple Intelligence is still downloading to your iPhone. Ask me again once it's ready — all of "
                + "Verdant's reasoning runs on your device."
        case .notEnabled:
            "Apple Intelligence isn't turned on yet. Enable it in Settings → Apple Intelligence & Siri and "
                + "I can answer questions about your health data, right on your iPhone."
        case .unavailableForever:
            "This iPhone can't run Apple Intelligence, which Verdant needs to reason about your data. It'll "
                + "work on a device that supports it — and nothing leaves your device either way."
        }
    }

    /// The agent ran and came back with nothing to say.
    static let couldNotAnswer =
        "I couldn't land a confident answer to that one from your data. Try asking about how a metric "
            + "has moved, or whether two of your metrics track each other."

    /// The agent never finished — a rate limit, a context overflow, a model error. `llm` returns nil
    /// for all of these and only these.
    ///
    /// Split out because `couldNotAnswer` was covering it, and the two call for opposite things from
    /// the person: this one is fixed by asking again, and rephrasing does nothing. Telling someone
    /// their question was unanswerable when the model simply fell over sends them to rewrite a
    /// question that was fine.
    ///
    /// The rule is already the codebase's own, one layer down — `llm` records the outcome
    /// specifically so a run "can tell a genuine 'nothing notable' pass apart from a wholesale
    /// inference failure: the two must not share a closing note." The Ask tab was the one place that
    /// principle was written down and not applied.
    static let answerDidNotFinish =
        "That one didn't finish — the on-device model was busy or the question ran long. Ask again "
            + "and it usually goes through; nothing about your question needs changing."

    /// The agent answered and the safety panel withheld it.
    ///
    /// The most important of the three to separate, because "I couldn't land a confident answer" is
    /// simply untrue here: an answer existed. Verdant's safety panel needs unanimity among five
    /// independent reviewers and fails closed, so this fires on prose that reads like a diagnosis —
    /// and it is reachable in normal use, not a corner case.
    ///
    /// Says what was withheld and why, then points at the reformulations that work. The alternative,
    /// staying vague to avoid inviting a retry, would mean misleading someone about their own health
    /// data to manage their behaviour.
    static let answerWithheld =
        "I worked that one out, but held it back: the answer read too much like a diagnosis, and "
            + "Verdant doesn't offer those. Ask how a metric has moved over time, or whether two of "
            + "them track each other, and I can answer directly."
}
