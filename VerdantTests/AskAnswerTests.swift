import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What the Ask tab says when it cannot give the person the answer they asked for.
///
/// Split from `OrchestratorTests` when that file hit its length limit, and the right seam: these
/// four outcomes — answered, did-not-finish, nothing-to-say, withheld — are a SET, and each one's
/// value is that it is not one of the others. They were not always. Three of them returned the same
/// sentence, "I couldn't land a confident answer to that one from your data", which is true of
/// exactly one: a model that fell over is fixed by asking again, and a withheld answer is not an
/// absent one. The tests asserting that shared string were themselves named "the honest fallback".
///
/// Verdant's copy elsewhere already holds this line — `unavailableAnswer` refuses to give one
/// reason for four capability states, because "ask me again once it's ready" is a false promise to
/// someone whose iPhone never will be. Same argument, applied one screen over.
struct AskAnswerTests {
    private func makeOrchestrator(
        _ container: ModelContainer,
        capability: LLMCapability,
        subagents: any SubagentRunning
    ) -> Orchestrator {
        let writer = StoreWriter(modelContainer: container)
        let stats = MetricStatsProvider(modelContainer: container)
        return Orchestrator(
            provider: stats,
            writer: writer,
            embeddings: Embeddings(),
            subagents: subagents,
            capability: { capability }
        )
    }

    private func seedMaterialSteps(_ writer: StoreWriter, now: Date) async throws {
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)
    }

    @Test func `answer returns the agent's text with no deterministic caution`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        var fake = FakeSubagents()
        fake.answerText = "Your steps have been higher than usual lately."
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let answer = await orchestrator.answer(question: "How are my steps?", now: now)
        #expect(answer == "Your steps have been higher than usual lately.")
        #expect(!answer.contains("healthcare provider"))
    }

    /// The agent session errors (rate limit/contention) → the user gets the honest fallback, never a
    /// blank or a fabricated answer.
    ///
    /// And specifically the DIDN'T-FINISH one. This asserted `couldNotAnswer` — the same string the
    /// safety-veto test below asserted, and the same one an empty answer returned — so three
    /// outcomes shared one sentence and the test named "the honest fallback" was pinning a message
    /// that was wrong in two of the three. Retrying fixes this case and rephrasing does nothing, so
    /// telling the person their question was unanswerable sends them to rewrite a question that was
    /// fine.
    @Test func `a wholesale Q&A inference failure says the request did not finish`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.failAllLLM = true
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let answer = await orchestrator.answer(question: "How are my steps?")
        #expect(answer == Orchestrator.answerDidNotFinish)
    }

    /// An agent that runs and produces nothing is the third case, and the only one `couldNotAnswer`
    /// was ever the right words for.
    @Test func `an empty answer says the data did not support one`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.answerText = ""
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let answer = await orchestrator.answer(question: "How are my steps?")
        #expect(answer == Orchestrator.couldNotAnswer)
    }

    /// The three must stay distinct, or the split silently collapses back to where it started.
    @Test func `the three failures say three different things`() {
        let all = [
            Orchestrator.couldNotAnswer, Orchestrator.answerDidNotFinish, Orchestrator.answerWithheld
        ]
        #expect(Set(all).count == 3)
        #expect(all.allSatisfy { $0.count > 40 }, "a fallback is too terse to tell anyone anything")
    }

    /// The Ask surface's safety gate. `answer` runs the panel over the model's prose before returning
    /// it, and the persist path's equivalent is tested — this one was not.
    ///
    /// It is the more direct of the two: a finding the panel vetoes is never written, but an ANSWER
    /// goes straight to the person who asked. Drop this guard and prose the reviewers judged a
    /// diagnosis, medical advice, or alarmist is handed over verbatim, in a health app whose
    /// disclaimer promises otherwise.
    @Test func `an answer the safety panel vetoes is never shown`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        var fake = FakeSubagents()
        fake.answerText = "This pattern indicates you may have a thyroid condition."
        fake.safetyIsSafe = false
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        let answer = await orchestrator.answer(question: "How are my steps?", now: now)

        #expect(answer == Orchestrator.answerWithheld)
        #expect(!answer.contains("thyroid"), "vetoed prose reached the user")
        // The one case where "I couldn't land a confident answer" is simply false: an answer existed
        // and was held back. Saying otherwise misleads someone about their own health data.
        #expect(answer != Orchestrator.couldNotAnswer)
    }

    /// And it fails CLOSED: a panel that cannot render a verdict must withhold the answer, not pass
    /// it through. "When in doubt, leave it out" is the posture everywhere else safety is judged.
    @Test func `an answer is withheld when the safety panel cannot render a verdict`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        var fake = FakeSubagents()
        fake.answerText = "Your steps have been higher than usual lately."
        fake.safetyFails = true
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        let answer = await orchestrator.answer(question: "How are my steps?", now: now)

        // `answerWithheld`, not `couldNotAnswer`: a panel that could not render a verdict withheld a
        // real answer, which is the same OUTCOME as a veto even though the cause differs. The one
        // thing that must never happen is the answer itself appearing.
        #expect(answer == Orchestrator.answerWithheld, "an unvetted answer was shown")
        #expect(!answer.contains("higher than usual"), "the unvetted prose reached the user")
    }

    @Test func `answer is unavailable with honest, state-specific copy`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let orchestrator = makeOrchestrator(
            container, capability: .unavailableForever, subagents: FakeSubagents()
        )
        let answer = await orchestrator.answer(question: "How are my steps?")
        #expect(answer == Orchestrator.unavailableAnswer(.unavailableForever))
        // A device that can NEVER run Apple Intelligence must not be promised it'll "be ready" — the bug
        // a single unavailable string caused. The other states keep their accurate, distinct guidance.
        #expect(!answer.lowercased().contains("ready"))
        #expect(!answer.lowercased().contains("once"))
        #expect(Orchestrator.unavailableAnswer(.downloading).lowercased().contains("ready"))
        #expect(Orchestrator.unavailableAnswer(.notEnabled).contains("Settings"))
    }

    @Test func `an unsafe model answer is caught and replaced, never shown`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // The model returns diagnostic prose; the safety panel vetoes it and the user is told the
        // answer was withheld, never handed the unsafe text — the Q&A safety backstop, agent-decided.
        var fake = FakeSubagents()
        fake.answerText = "This means you have diabetes."
        fake.safetyIsSafe = false
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let answer = await orchestrator.answer(question: "How are my steps?", now: now)
        #expect(answer == Orchestrator.answerWithheld)
        #expect(!answer.contains("diabetes"))
    }
}
