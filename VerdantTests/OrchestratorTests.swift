import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Integration tests for the discovery loop. Every finding is LLM-reasoned (there are no
/// deterministic findings), so the fake subagent supplies the model's leads and prose while the
/// deterministic verify → safety → curate path runs without the on-device model.
struct OrchestratorTests {
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

    /// Two cross-domain metrics with an identical day-to-day pattern → near-perfect correlation.
    private func seedCorrelatedPair(_ writer: StoreWriter, now: Date) async throws {
        try await TestSupport.seed(
            writer,
            metric: .sleepDurationHours,
            value: 7,
            daysAgo: 1...40,
            jitter: 1,
            now: now
        )
        try await TestSupport.seed(
            writer,
            metric: .restingHeartRate,
            value: 60,
            daysAgo: 1...40,
            jitter: 5,
            now: now
        )
    }

    private static let correlatedPairKey = ["restingHeartRate", "sleepDurationHours"]
        .sorted().joined(separator: "|")

    /// A fake whose agentic investigator "uncovers" one step-count finding. `worth` is the agent's own
    /// salience judgment (there is no longer a deterministic quality floor to clear). The orchestrator
    /// resolves the real numbers from the seeded store for the named metric/comparison.
    private func stepLeadFake(
        salience: Int,
        phrasingSummary: String = "Your steps rose noticeably."
    ) -> FakeSubagents {
        var fake = FakeSubagents()
        fake.proposals = [ProposedFinding(
            kind: InsightKind.trend.rawValue,
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Steps up",
            story: phrasingSummary,
            worth: salience
        )]
        return fake
    }

    /// A fake whose investigator proposes one finding of the given kind for `metric` (naming `secondary`
    /// for a correlation). The orchestrator resolves the real numbers for it from the seeded substrate.
    private func proposalFake(
        kind: InsightKind,
        metric: MetricKey,
        secondary: MetricKey? = nil,
        story: String = "A genuinely non-obvious pattern worth a look.",
        worth: Int = 75
    ) -> FakeSubagents {
        FakeSubagents(proposals: [ProposedFinding(
            kind: kind.rawValue,
            metric: metric.rawValue,
            secondaryMetric: (secondary ?? metric).rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "A finding",
            story: story,
            worth: worth
        )])
    }

    // MARK: Single-metric LLM leads

    @Test func `an LLM-discovered lead persists with vetted prose`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        let orchestrator = makeOrchestrator(
            container,
            capability: .available,
            subagents: stepLeadFake(salience: 80)
        )

        await orchestrator.runDiscovery(now: now)

        let steps = try await writer.snapshotsForSearch(now: now)
            .filter { $0.metric == MetricKey.stepCount.rawValue }
        #expect(steps.count == 1)
        #expect(steps.first?.summary == "Your steps rose noticeably.")
    }

    @Test func `a strong change the model never proposes is NOT surfaced (no deterministic findings)`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now) // a large, material deterministic trend
        // The agent proposes nothing and the single seeded metric yields no correlations.
        let fake = FakeSubagents()
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        await orchestrator.runDiscovery(now: now)
        // Raw rows: `snapshotsForSearch` filters tombstoned findings, so it cannot tell "never
        // written" from "written and then hidden". The claim here is the former — nothing reaches
        // the store at all.
        let rows = ModelContext(container)
        #expect(try rows.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try rows.fetchCount(FetchDescriptor<CorrelationLog>()) == 0)
    }

    @Test func `a low-worth lead the agent still proposes is surfaced (no deterministic floor)`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // The deterministic salience/quality floor is gone: worth is the agent's call. A finding the
        // agent chose to propose (even at low salience) surfaces, gated only by safety + the skeptics.
        let orchestrator = makeOrchestrator(
            container,
            capability: .available,
            subagents: stepLeadFake(salience: 20)
        )

        await orchestrator.runDiscovery(now: now)

        let steps = try await writer.snapshotsForSearch(now: now)
            .filter { $0.metric == MetricKey.stepCount.rawValue }
        #expect(steps.count == 1)
    }

    @Test func `prose the safety panel vetoes is not surfaced`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // Safety is now an agent decision: the panel vetoes, so nothing surfaces (no blocklist).
        var fake = stepLeadFake(salience: 80, phrasingSummary: "This means you have diabetes.")
        fake.safetyIsSafe = false
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        await orchestrator.runDiscovery(now: now)
        // Raw rows: `snapshotsForSearch` filters tombstoned findings, so it cannot tell "never
        // written" from "written and then hidden". The claim here is the former — nothing reaches
        // the store at all.
        let rows = ModelContext(container)
        #expect(try rows.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try rows.fetchCount(FetchDescriptor<CorrelationLog>()) == 0)
    }

    @Test func `a finding is dropped when the safety panel cannot render a verdict (fail closed)`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // The panel errors on every lens. Safety fails CLOSED: an unconfirmed finding is never shown.
        var fake = stepLeadFake(salience: 80)
        fake.safetyFails = true
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        await orchestrator.runDiscovery(now: now)
        // Raw rows: `snapshotsForSearch` filters tombstoned findings, so it cannot tell "never
        // written" from "written and then hidden". The claim here is the former — nothing reaches
        // the store at all.
        let rows = ModelContext(container)
        #expect(try rows.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try rows.fetchCount(FetchDescriptor<CorrelationLog>()) == 0)
    }

    @Test func `model unavailable surfaces nothing`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        try await seedCorrelatedPair(writer, now: now)
        let orchestrator = makeOrchestrator(
            container, capability: .unavailableForever, subagents: stepLeadFake(salience: 90)
        )

        await orchestrator.runDiscovery(now: now)
        // Raw rows: `snapshotsForSearch` filters tombstoned findings, so it cannot tell "never
        // written" from "written and then hidden". The claim here is the former — nothing reaches
        // the store at all.
        let rows = ModelContext(container)
        #expect(try rows.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try rows.fetchCount(FetchDescriptor<CorrelationLog>()) == 0)
        #expect(try await !writer.hasRecentCorrelation(pairKey: Self.correlatedPairKey, within: 2, now: now))
    }

    @Test func `a run where all inference fails is not recorded as a completed analysis`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // Model reports available, but every subagent call errors (rate-limit/contention).
        var fake = FakeSubagents()
        fake.failAllLLM = true
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let produced = await orchestrator.runDiscovery(now: now, progress: ProgressReporter { _ in })
        #expect(produced == 0)
        // Nothing was actually reasoned, so the run must NOT stamp "last analyzed" — recording it would
        // tell the user their data got a clean bill when the reasoning layer never ran.
        #expect(try await writer.agentStateForTest() == nil)
    }

    // MARK: Cross-source correlations

    @Test func `a strong cross-source correlation is phrased and persisted`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedCorrelatedPair(writer, now: now)
        let fake = proposalFake(
            kind: .correlation, metric: .sleepDurationHours, secondary: .restingHeartRate,
            story: "On nights you sleep longer, your resting heart rate tends to be lower the next day."
        )
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        #expect(try await writer.hasRecentCorrelation(pairKey: Self.correlatedPairKey, within: 2, now: now))
    }

    @Test func `even a bounded foreground run drops a finding the skeptics reject`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedCorrelatedPair(writer, now: now)
        // A correlation the agent is happy to surface, but that the skeptic panel knocks down — it must
        // not surface, even on the everyday (non-deep) launch catch-up path.
        var fake = proposalFake(kind: .correlation, metric: .sleepDurationHours, secondary: .restingHeartRate)
        fake.scrutinyHoldsUp = false
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        #expect(try await !writer.hasRecentCorrelation(pairKey: Self.correlatedPairKey, within: 2, now: now))
    }

    @Test func `a correlation story the safety panel vetoes is not surfaced`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedCorrelatedPair(writer, now: now)
        var fake = proposalFake(
            kind: .correlation, metric: .sleepDurationHours, secondary: .restingHeartRate,
            story: "This is a sign of heart disease."
        )
        fake.safetyIsSafe = false // the agent safety panel rejects the prose
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        #expect(try await !writer.hasRecentCorrelation(pairKey: Self.correlatedPairKey, within: 2, now: now))
    }

    @Test func `a strong correlation the agent does not surface stays hidden (agent decides)`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedCorrelatedPair(writer, now: now)
        // The engine still finds the correlation, but the agentic investigator proposes nothing — so
        // nothing surfaces. This is the inversion: the agent decides what's shown, not the scan.
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: FakeSubagents())

        await orchestrator.runDiscovery(now: now)

        #expect(try await !writer.hasRecentCorrelation(pairKey: Self.correlatedPairKey, within: 2, now: now))
    }

    @Test func `a volatility shift is surfaced as a finding`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // Recent month erratic; long baseline steady; mean ~unchanged → a pure volatility shift.
        try await TestSupport.seed(
            writer,
            metric: .sleepDurationHours,
            value: 7,
            daysAgo: 1...28,
            jitter: 2.5,
            now: now
        )
        try await TestSupport.seed(
            writer,
            metric: .sleepDurationHours,
            value: 7,
            daysAgo: 31...130,
            jitter: 0.2,
            now: now
        )
        let orchestrator = makeOrchestrator(
            container, capability: .available,
            subagents: proposalFake(kind: .volatility, metric: .sleepDurationHours)
        )

        await orchestrator.runDiscovery(now: now)

        #expect(try await writer.hasRecentVolatility(metric: .sleepDurationHours, within: 2, now: now))
    }

    @Test func `a record-setting metric surfaces a pattern finding`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // Long flat history, then a clearly higher final week → a record 7-day stretch.
        try await TestSupport.seed(writer, metric: .vo2Max, value: 50, daysAgo: 8...200, jitter: 1, now: now)
        try await TestSupport.seed(writer, metric: .vo2Max, value: 62, daysAgo: 1...7, jitter: 1, now: now)
        let orchestrator = makeOrchestrator(
            container, capability: .available,
            subagents: proposalFake(kind: .milestone, metric: .vo2Max)
        )

        await orchestrator.runDiscovery(now: now)

        // A milestone and a volatility shift both describe this record; curation keeps the single
        // best (findings are kept independent — at most one per metric), so assert *a* finding for it.
        let vo2 = try await writer.snapshotsForSearch(now: now)
            .filter { $0.metric == MetricKey.vo2Max.rawValue }
        #expect(!vo2.isEmpty)
    }

    @Test func `a regime shift is surfaced as a finding`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // A sustained step: ~55 for two months, then ~62 for the last 40 days.
        try await TestSupport.seed(
            writer,
            metric: .restingHeartRate,
            value: 55,
            daysAgo: 41...100,
            jitter: 1,
            now: now
        )
        try await TestSupport.seed(
            writer,
            metric: .restingHeartRate,
            value: 62,
            daysAgo: 1...40,
            jitter: 1,
            now: now
        )
        let orchestrator = makeOrchestrator(
            container, capability: .available,
            subagents: proposalFake(kind: .regimeShift, metric: .restingHeartRate)
        )

        await orchestrator.runDiscovery(now: now)

        #expect(try await writer.hasRecentRegimeShift(metric: .restingHeartRate, within: 2, now: now))
    }
}
