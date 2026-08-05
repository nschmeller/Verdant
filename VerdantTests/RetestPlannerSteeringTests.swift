import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The agent that SIZES the armed panel planned without knowing what data exists.
///
/// `composeRetests` reads the claim and names extra computations worth running; each one becomes
/// another analyst. It was handed the claim and nothing else, so it proposed re-tests against
/// metrics the person may not have — and every such re-test is spent before it starts.
///
/// Measured against the real model on a library holding resting heart rate and nothing else: the
/// planner proposed a step-count comparison and a weekday/weekend split, and two of five analysts
/// spent their entire session finding out ("No data for Steps."). That is worse than proposing
/// nothing, because the panel was sized as though those analysts would report something. The
/// shortlist the analysts themselves receive was already being built twenty lines below the planner
/// call; it now gets built above it and passed in.
///
/// Steering, not a filter. The planner may still propose whatever it likes — including a metric off
/// the list, if it has a reason.
struct RetestPlannerSteeringTests {
    private func makeOrchestrator(_ container: ModelContainer, _ fake: FakeSubagents) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(), subagents: fake, capability: { .available }
        )
    }

    /// Only step count has data, so a planner that is told the truth cannot propose a heart-rate
    /// re-test by accident.
    private func context(_ container: ModelContainer) async throws -> DiscoveryContext {
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 8000, daysAgo: 1...40, jitter: 400, now: Date()
        )
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(), now: Date()
        )
        return DiscoveryContext(
            jobID: UUID(), now: Date(), deadline: nil, progress: nil,
            substrate: substrate, adversarial: true
        )
    }

    private func runPanel(_ recorder: SubagentCallRecorder) async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.calls = recorder
        let ctx = try await context(container)
        let substrate = try #require(ctx.substrate)
        _ = await makeOrchestrator(container, fake).survivesReplication(
            "Your step count settled higher.", subject: "step count",
            metrics: [.stepCount], substrate: substrate, ctx
        )
    }

    @Test func `the planner is told which metrics have data`() async throws {
        let recorder = SubagentCallRecorder()
        try await runPanel(recorder)

        let planned = recorder.retestPlanAvailable
        #expect(planned.count == 1, "the planner ran \(planned.count) times, expected once")
        let line = try #require(recorder.firstRetestPlanAvailable, "the planner still plans blind")
        #expect(line.contains(MetricKey.stepCount.rawValue))
        #expect(
            !line.contains(MetricKey.restingHeartRate.rawValue),
            "a metric with no data was offered to the planner: \(line)"
        )
    }

    /// The planner and the analysts must be reading the SAME shortlist. Two builders would drift, and
    /// the failure mode is silent: a planner proposing re-tests the analysts are then steered away
    /// from. This pins that one value reaches both.
    @Test func `the planner and the analysts get the same shortlist`() async throws {
        let recorder = SubagentCallRecorder()
        try await runPanel(recorder)

        let planned = try #require(recorder.firstRetestPlanAvailable)
        let lenses = recorder.replicateLenses
        #expect(!lenses.isEmpty, "the panel never convened")
        for lens in lenses {
            #expect(lens.contains(planned), "an analyst was steered by a different shortlist")
        }
    }

    /// Non-vacuity: the shortlist is a real sentence naming real keys, not an empty string that would
    /// satisfy `contains` everywhere above.
    @Test func `the shortlist is not empty`() async throws {
        let recorder = SubagentCallRecorder()
        try await runPanel(recorder)
        let planned = try #require(recorder.firstRetestPlanAvailable)
        #expect(planned.count > 20, "the shortlist is \(planned.count) characters: \(planned)")
    }
}
