import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Verdant

/// The user-facing drill-down: tap a finding → "Investigate this further". It runs the same fleet,
/// panels and curation as a research pass, but every lens is re-anchored on the tapped finding —
/// and it was the one user-triggered path with no coverage at all.
struct FocusedDiscoveryTests {
    private func makeOrchestrator(
        _ container: ModelContainer,
        subagents: any SubagentRunning,
        capability: @escaping @Sendable () -> LLMCapability = { .available }
    ) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: subagents,
            capability: capability
        )
    }

    private func stepProposalFake() -> FakeSubagents {
        FakeSubagents(proposals: [ProposedFinding(
            kind: InsightKind.trend.rawValue,
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Steps up",
            story: "Your steps rose noticeably.",
            worth: 80
        )])
    }

    private let focus = InvestigationFocus(
        metric: .stepCount, secondaryMetric: nil, title: "Steps up"
    )

    @Test func `a drill-down surfaces findings and anchors every lens on the tapped finding`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)
        var fake = stepProposalFake()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let last = ProgressSink()

        let produced = await makeOrchestrator(container, subagents: fake)
            .runFocusedDiscovery(focus: focus, now: now, progress: last.reporter())

        #expect(produced == 1)
        #expect(try await writer.snapshotsForSearch(now: now).count == 1)
        // EVERY investigator was pointed at the tapped finding — that is what makes this a
        // drill-down rather than another broad sweep.
        let lenses = calls.investigateLenses
        #expect(!lenses.isEmpty)
        let anchored = lenses.allSatisfy {
            $0.contains(MetricKey.stepCount.displayName) || $0.contains(focus.title)
        }
        #expect(anchored)
        // One lens exists purely to try to knock the finding down.
        #expect(lenses.contains { $0.contains("challenge the finding") })
        #expect(last.last?.phase == .finished)
    }

    /// A drill-down produces nothing when nothing new clears the bar — and must say so honestly
    /// rather than reading as a failed run.
    /// A question costs two model passes and a five-reviewer safety panel — a long silence in an app
    /// whose promise is that you can watch it reason. Pins that the Ask path reports real steps,
    /// including the panels narrating themselves through the same reporter.
    @Test func `answering a question narrates its actual steps`() async throws {
        let container = try TestSupport.inMemoryContainer()
        // Seeded, so the load reports what it read rather than "no logged history yet". That extra
        // line is correct behaviour and it evicted the opener: the feed keeps the last
        // `maxLogEntries` (8) and this flow already emits exactly eight — opener, working, panel
        // convening, five reviewers. The test was passing at the boundary. A user with data is also
        // the case worth asserting on.
        try await TestSupport.seed(
            StoreWriter(modelContainer: container), metric: .restingHeartRate, value: 58,
            daysAgo: 1...40, jitter: 2, now: Date()
        )
        var fake = FakeSubagents()
        fake.answerText = "Your resting heart rate fell about 3 bpm over the last month."
        let sink = ProgressSink()

        let answer = await makeOrchestrator(container, subagents: fake)
            .answer(question: "How is my resting heart rate?", progress: sink.reporter())

        #expect(answer == fake.answerText)
        let feed = try #require(sink.last?.activityLog).map(\.text)
        #expect(feed.contains { $0.contains("Reading your health data") })
        #expect(feed.contains { $0.contains("working through your question") })
        // The safety panel narrates itself once the reporter reaches it.
        #expect(feed.contains { $0.contains("Safety panel") })
    }

    @Test func `a drill-down that finds nothing closes with an honest note`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let last = ProgressSink()

        let produced = await makeOrchestrator(container, subagents: FakeSubagents())
            .runFocusedDiscovery(focus: focus, now: now, progress: last.reporter())

        #expect(produced == 0)
        let note = try #require(last.last?.note)
        #expect(note.contains("nothing new cleared the bar"))
    }

    /// Every finding needs the model, so a drill-down without one must not imply it looked and
    /// found nothing.
    @Test func `a drill-down without a model refuses instead of reporting a clean bill`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let calls = SubagentCallRecorder()
        var fake = stepProposalFake()
        fake.calls = calls
        let last = ProgressSink()

        let produced = await makeOrchestrator(container, subagents: fake, capability: { .downloading })
            .runFocusedDiscovery(focus: focus, now: now, progress: last.reporter())

        #expect(produced == 0)
        #expect(calls.investigateLenses.isEmpty) // not a single session was issued
        let note = try #require(last.last?.note)
        #expect(note.contains("isn't available"))
    }
}
