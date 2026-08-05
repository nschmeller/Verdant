import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The feed's SIZE, as opposed to its contents.
///
/// Which findings keep a slot is entirely the curator agent's call — that is the architecture, and
/// the deterministic worth floors were deliberately removed. How MANY keep a slot is not: "a handful
/// of exceptional findings, not a wall" is a promise the feed makes to the user, and the agent can
/// return any keep-list it likes, including all of them. What holds the line is a `prefix(budget)`
/// and a roster-range filter in the persist path — plumbing, in the middle of a decision path where
/// the surrounding philosophy actively argues for deleting clamps.
///
/// Only the CONSTANT's range (3...12) was tested. Nothing checked the feed itself.
struct CurationBudgetTests {
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

    private func fact(_ metric: MetricKey, salience: Int) -> VerifiedFact {
        VerifiedFact(
            metric: metric, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: salience
        )
    }

    /// The feed's bound survives a curator that wants to keep everything.
    ///
    /// "A handful of exceptional findings, not a wall" is a promise made to the user on the feed
    /// itself, and curation is an AGENT decision — the agent can return any keep-list it likes,
    /// including all of them. A `prefix(budget)` in the persist path is what actually holds the
    /// line, and it is plumbing sitting inside a decision path where the surrounding philosophy
    /// ("agents decide, no deterministic gates") actively argues for deleting clamps. Only the
    /// CONSTANT's range was tested; nothing checked the feed.
    @Test func `an over-generous curator cannot grow the feed past its budget`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let budget = EnhancementPolicy.maxActiveFindings
        let metrics = Array(MetricKey.allCases.prefix(budget + 6))
        #expect(metrics.count > budget, "need more findings than the budget to test the bound")
        for (index, metric) in metrics.enumerated() {
            let seeded = fact(metric, salience: 10 + index)
            _ = try await writer.appendInsightIfNovel(
                fact: seeded, phrasing: FindingPhrasing.phrasing(for: seeded),
                jobRunID: UUID(), now: now
            )
        }
        var fake = FakeSubagents()
        // The fake's default already asks to keep 64 — stated here because it IS the test.
        fake.curationKeep = Array(0..<64)
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.curate(now: now)

        let active = try await writer.snapshotsForSearch(now: now)
        #expect(active.count <= budget, "curator kept \(active.count) against a budget of \(budget)")
        #expect(!active.isEmpty, "the trim retired everything")
    }

    /// The same bound when the curator names numbers that are not on the roster at all — the closed
    /// roster is the boundary, exactly as the metric registry is for metric names.
    @Test func `keep-list numbers outside the roster are ignored`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        for (index, metric) in [MetricKey.stepCount, .vo2Max].enumerated() {
            let seeded = fact(metric, salience: 30 + index * 30)
            _ = try await writer.appendInsightIfNovel(
                fact: seeded, phrasing: FindingPhrasing.phrasing(for: seeded),
                jobRunID: UUID(), now: now
            )
        }
        var fake = FakeSubagents()
        fake.curationKeep = [0, 99, -3, 5000] // one real index, three the roster never offered
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.curate(now: now)

        let active = try await writer.snapshotsForSearch(now: now)
        #expect(active.count == 1, "out-of-range keeps were honoured: \(active.count) active")
    }
}
