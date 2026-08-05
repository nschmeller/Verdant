import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What happens to a proposal the registry cannot resolve.
///
/// Split from `AgenticGovernanceTests` when that file passed the 500-line limit.
struct UnknownMetricDropTests {
    /// A proposal naming a metric the registry does not know is dropped, and SAID.
    ///
    /// `ProposedFinding.metric` deliberately carries no `.anyOf` — the full key vocabulary in the
    /// output schema blew the 4k budget on device — so the registry resolve is the anti-hallucination
    /// boundary and an unresolvable key is expected traffic. It used to vanish with no line in the
    /// feed, which was the only signal anyone would ever get that the boundary had fired.
    ///
    /// Observed, not imagined: driving the real on-device model over seeded data, one proposal in
    /// three named the metric "steps" where the registry key is "stepCount".
    @Test func `a proposal naming an unknown metric is dropped out loud`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 8000, daysAgo: 1...40, jitter: 400, now: Date()
        )
        let sink = ProgressSink()
        let fake = FakeSubagents(proposals: [ProposedFinding(
            kind: InsightKind.trend.rawValue,
            metric: "steps",
            secondaryMetric: "steps",
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Slight Step Decline",
            story: "Steps have slightly decreased from recent norms.",
            worth: 40
        )])
        let orchestrator = Orchestrator(
            provider: MetricStatsProvider(modelContainer: container), writer: writer,
            embeddings: Embeddings(), subagents: fake, capability: { .available }
        )

        await orchestrator.runDiscovery(progress: sink.reporter())

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<InsightLog>()).isEmpty, "an unknown metric persisted")
        let feed = (sink.last?.activityLog ?? []).map(\.text)
        #expect(
            feed.contains { $0.contains("not a metric this app tracks") },
            Comment(rawValue: "the drop was silent: \(feed)")
        )
    }
}
