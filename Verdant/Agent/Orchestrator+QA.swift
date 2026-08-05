import Foundation

/// Foreground Q&A — now fully agentic. Each question launches ONE ephemeral agent session over the
/// same logical tool surface the investigator drives (overview, stats, correlations, patterns,
/// custom `analyze` queries, past-insight search), so it can answer *relational* and custom-view
/// questions, not just single-metric ones. There is no router and no pre-resolved fact string —
/// the agent decides what to look up and pulls the real numbers itself; scope is its judgment too.
/// The answer still passes the agent safety panel before it is shown.
nonisolated extension Orchestrator {
    /// `history` is the Ask screen's earlier exchanges. It is replayed in hard-clamped form so a
    /// follow-up like "why?" has a referent — see `ConversationTurn`.
    func answer(
        question: String,
        history: [ConversationTurn] = [],
        now: Date = .now,
        progress: ProgressReporter? = nil
    ) async -> String {
        guard capability().isAvailable else { return Self.unavailableAnswer(capability()) }
        subagents.prewarm()
        // Narrated at the granularity this function actually KNOWS — the same rule the research
        // feed follows: no rotating filler, so every line the user reads is literally what is
        // happening. The safety panel narrates itself through the reporter below.
        await progress?.log("Reading your health data…")
        // Fresh substrate per question: cheap relative to a chat exchange, and the tools then serve
        // cached scans for every call the agent makes while reasoning about this question.
        // Same honest load as the runs. The Ask path is where it matters most to say so: a failed
        // read here produces a confident-sounding answer with nothing behind it, to a question the
        // person just asked.
        let loaded = await Self.loadSeries(provider, now: now)
        if loaded.series.isEmpty { await progress?.log(loaded.note) }
        let substrate = AnalysisSubstrate(provider: provider, series: loaded.series, now: now)
        // Kick the scans off before the session starts, so the answer's first tool call reads a
        // finished scan instead of making the user wait on the CPU mid-answer.
        await substrate.precompute()
        await progress?.log("An agent is working through your question — measuring, then answering…")
        // Three outcomes, three answers. These used to be one `guard` returning `couldNotAnswer` for
        // all of them, and they are not the same thing to tell someone who just asked about their own
        // health: the model falling over is fixed by asking again, an empty answer by rephrasing, and
        // a withheld answer by neither — an answer existed. See the three strings' docs.
        let produced = await llm(
            nil, progress: progress,
            {
                try await subagents.answer(
                    question: question, history: history, substrate: substrate, now: now
                )
            }
        )
        guard let answer = produced else { return Self.answerDidNotFinish }
        guard !answer.text.isEmpty else { return Self.couldNotAnswer }
        guard await passesSafety(answer.text, progress: progress) else { return Self.answerWithheld }
        return answer.text
    }
}
