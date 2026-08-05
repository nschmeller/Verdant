import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Conversational memory on the Ask screen, and the clamp that makes it affordable.
///
/// The screen always kept a transcript and rendered it as a conversation, and nothing was ever
/// replayed into the model. "How have my steps been?" followed by "Why?" sent the agent the bare
/// word "Why?" — it could only guess or decline, in a UI that had just implied it would know. That
/// was a deliberate trade to keep the 4,096-token window at arm's length, so the fix is not "replay
/// the transcript" but "replay a bounded tail of it".
///
/// The bound is the whole feature. An unclamped replay grows with the conversation and eventually
/// kills the session mid-answer — not a wrong answer, no answer — which is the failure mode the
/// original decision was avoiding and the one these tests exist to prevent returning.
struct ConversationMemoryTests {
    private func turn(_ index: Int) -> ConversationTurn {
        ConversationTurn(question: "Question \(index)", answer: "Answer \(index)")
    }

    // MARK: - The clamp

    @Test func `an empty conversation replays nothing`() {
        #expect(ConversationTurn.context([]) == nil)
    }

    /// Only the tail. A long conversation must cost the same as a short one.
    @Test func `only the last exchanges are replayed`() throws {
        let context = try #require(ConversationTurn.context((1...10).map(turn)))
        #expect(context.contains("Question 10"))
        #expect(context.contains("Question 9"))
        #expect(!context.contains("Question 8"), "the replay grows with the conversation")
    }

    /// The bound that matters: whatever the user types and however long the agent answers, the
    /// replayed context stays inside a few hundred tokens.
    @Test func `a runaway conversation cannot grow the replayed context`() throws {
        let huge = (1...50).map { index in
            ConversationTurn(
                question: String(repeating: "why ", count: 2000) + "\(index)",
                answer: String(repeating: "because ", count: 2000)
            )
        }
        let context = try #require(ConversationTurn.context(huge))
        let ceiling = ConversationTurn.maxReplayed * ConversationTurn.maxCharacters * 2 + 200
        #expect(
            context.count <= ceiling,
            "replayed \(context.count) characters — the 4k window is reachable again"
        )
    }

    /// A blank question carries no referent, so it is not worth its tokens.
    @Test func `an empty question is not replayed`() {
        #expect(ConversationTurn.context([ConversationTurn(question: "  ", answer: "x")]) == nil)
    }

    /// The clamp cuts the TAIL of each side. A follow-up refers to what was asked and to the opening
    /// of what was answered, so those are what must survive.
    @Test func `the clamp keeps the start of each side`() throws {
        let long = ConversationTurn(
            question: "Why did my resting heart rate " + String(repeating: "x", count: 500),
            answer: "Because your sleep " + String(repeating: "y", count: 500)
        )
        let context = try #require(ConversationTurn.context([long]))
        #expect(context.contains("Why did my resting heart rate"))
        #expect(context.contains("Because your sleep"))
    }

    // MARK: - The wiring

    private func makeOrchestrator(
        _ container: ModelContainer, subagents: any SubagentRunning
    ) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: subagents,
            capability: { .available }
        )
    }

    /// `history` is defaulted at every link — `ChatView` → `AppModel.ask` → `Orchestrator.answer` →
    /// `Subagents.answer` — so all four compile and run while passing nothing at all. This is the
    /// test that fails if any one of them stops forwarding it.
    @Test func `the conversation reaches the subagent that answers`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        let recorder = SubagentCallRecorder()
        fake.calls = recorder
        let history = [ConversationTurn(question: "How are my steps?", answer: "Higher than usual.")]

        _ = await makeOrchestrator(container, subagents: fake)
            .answer(question: "Why?", history: history)

        let seen = try #require(recorder.answerHistories.first, "answer was never called")
        #expect(seen == history, "the conversation was dropped on the way down")
    }

    /// The one link the runtime test cannot reach: `ChatView` is a SwiftUI view, so nothing above
    /// exercises the call that starts the chain. It is also the likeliest link to be lost — a future
    /// edit to `send()` that drops `history:` would compile, because the parameter is defaulted, and
    /// would silently restore the exact behaviour this feature removed.
    @Test func `the Ask screen passes the conversation when it asks`() throws {
        let chat = try #require(
            SourceScan.swiftSources().first { $0.path.hasSuffix("ChatView.swift") },
            "ChatView.swift not found — this invariant is no longer checking anything"
        )
        let calls = SourceScan.callSites(of: "model.ask", in: chat.text)
        #expect(!calls.isEmpty, "ChatView no longer calls model.ask — has the screen moved?")
        for call in calls {
            #expect(call.contains("history:"), "ChatView asks without the conversation: \(call)")
        }
    }

    /// The README describes this clamp in numbers, which makes it a transcription of
    /// `ConversationTurn`'s constants — the shape this codebase drifts on more than any other, and
    /// one created in the very edit that FIXED a different README drift about this same feature.
    ///
    /// Pinned rather than trusted: a README that describes an architecture the app no longer has is a
    /// documented failure here, and the only reason this one is checkable is that the claim is
    /// numeric.
    /// EVERY doc that states the clamp, not just the one that stated it first.
    ///
    /// The README was pinned when a drift about this feature was fixed there. Within the hour the
    /// same two numbers were written into `ARCHITECTURE.md`'s summary, out of reach of a check that
    /// named one file — the identical mistake, made by the same author, an hour after building the
    /// guard against it. So the check now finds the claim wherever it is written.
    @Test func `every doc that states the Ask clamp states the real one`() throws {
        let root = SourceScan.appRoot.deletingLastPathComponent()
        var checked = 0
        for name in ["README.md", "docs/ARCHITECTURE.md"] {
            let text = try String(
                contentsOf: root.appendingPathComponent(name), encoding: .utf8
            )
            // Whitespace-collapsed: markdown wraps at 100 columns, so "220" and "characters" land on
            // different lines and a literal search misses them. A test a reflow can break is a test
            // that gets deleted rather than fixed.
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard flat.contains("characters a side") else { continue }
            checked += 1
            #expect(
                flat.contains("last \(spelled(ConversationTurn.maxReplayed)) exchanges"),
                Comment(rawValue: "\(name) does not state maxReplayed = \(ConversationTurn.maxReplayed)")
            )
            #expect(
                flat.contains("\(ConversationTurn.maxCharacters) characters a side"),
                Comment(rawValue: "\(name) does not state maxCharacters = \(ConversationTurn.maxCharacters)")
            )
        }
        #expect(checked == 2, "expected both docs to describe the clamp, found \(checked)")
    }

    private func spelled(_ value: Int) -> String {
        [1: "one", 2: "two", 3: "three", 4: "four", 5: "five"][value] ?? "\(value)"
    }

    /// And a question asked with no conversation behind it still works — the common case, and the
    /// one a badly-placed `guard` would break.
    @Test func `a first question with no history still answers`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.answerText = "Your steps have been steady."
        let answer = await makeOrchestrator(container, subagents: fake).answer(question: "How are my steps?")
        #expect(answer == "Your steps have been steady.")
    }
}
