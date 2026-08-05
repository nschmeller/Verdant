import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What ranks a single-metric finding: the AGENT's judgment, not the size of the change.
///
/// `MaterialityRules.buildFact` takes `requestedSalience` with a default of `nil`, and falling back
/// computes salience from `|z|` and `%change` instead. The persist route passes the agent's `worth`,
/// and the reason is spelled out where it is done: for a lone metric the statistical term measures
/// *bigness*, which usually means *obviousness*, so blending it in "would promote the loud,
/// predictable changes this app exists to filter out". The model's worth captures non-obviousness,
/// which is what should rank.
///
/// Drop that argument and nothing fails. The feed simply re-sorts toward the biggest numbers — the
/// exact editorial failure the app defines itself against — with no error, no crash, and no test
/// noticing. (Correlations and the pattern kinds blend a stat term deliberately; there the stat
/// measures trustworthiness of a subtle link, not bigness. This is only about single-metric leads.)
struct SalienceSourceTests {
    private func makeOrchestrator(
        _ container: ModelContainer,
        subagents: any SubagentRunning
    ) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: subagents,
            capability: { .available }
        )
    }

    /// A modest, unremarkable rise — so the statistical salience is nowhere near the agent's 90 and
    /// the two sources are actually distinguishable.
    private func seedModestRise(_ writer: StoreWriter, now: Date) async throws {
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 8000, daysAgo: 8...60, jitter: 300, now: now
        )
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 8600, daysAgo: 1...7, jitter: 300, now: now
        )
    }

    @Test func `a single-metric finding is ranked by the agent's worth, not by how big the change is`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedModestRise(writer, now: now)

        let fake = FakeSubagents(proposals: [ProposedFinding(
            kind: InsightKind.trend.rawValue,
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "A quiet drift upward",
            story: "Your steps have edged up over the past week.",
            worth: 90
        )])

        await makeOrchestrator(container, subagents: fake).runDiscovery(now: now)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<InsightLog>()).filter { !$0.tombstoned }
        let row = try #require(rows.first, "the proposal was not persisted")
        #expect(row.salience == 90, "ranked \\(row.salience) — computed from the numbers instead?")
    }

    /// The fixture has to make the two sources DIFFER, or the assertion above passes either way.
    /// This is the non-vacuity guard: the statistical salience for this change must not happen to be
    /// 90 as well.
    @Test func `the fixture distinguishes the agent's worth from the computed salience`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedModestRise(writer, now: now)

        let provider = MetricStatsProvider(modelContainer: container)
        let stat = try #require(
            try await provider.stat(for: .stepCount, comparison: .recentVsBaseline, now: now)
        )
        let computed = MaterialityRules.salience(z: stat.z, pct: stat.pctChange)
        #expect(computed != 90, "computed salience is also 90 — the test cannot tell them apart")
    }
}
