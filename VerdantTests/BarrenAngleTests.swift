import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Cross-run learning about WHERE TO LOOK used to be positive-only. The journal recorded what was
/// confirmed, rejected and retired — all outcomes of something that was actually *proposed*. An
/// angle a scout invented, that the fleet chased, and that produced no proposal at all left no trace
/// anywhere but the run's in-memory ledger, which dies with the run. The next run's scouts could
/// re-propose it forever with no way to know.
///
/// `barren` closes that. What it deliberately does NOT do is become another prohibition: barren
/// ground bears fruit once more data lands, so it reaches the research director as a fact to weigh
/// and never enters `journalSteering`'s do-not-repeat list. These tests pin both halves — that the
/// signal is recorded, and that it stays advisory.
struct BarrenAngleTests {
    /// The app must not write a reason on a barren entry — see the fixture note below. Pinned
    /// separately because the size test that motivated it saturates the journal by hand and so
    /// cannot see this.
    @Test func `a barren angle is journaled without a reason`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator.swift" }
        )
        let code = SourceScan.code(source.text)
        let call = try #require(
            SourceScan.callSites(of: "recordJournal", in: code).first { $0.contains("kind: .barren") },
            "nothing journals a barren angle any more"
        )
        #expect(!call.contains("reason:"), Comment(rawValue: "barren entry carries a reason: \(call)"))
    }

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

    private var now: Date {
        Calendar.civil.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// A container with enough real data that the investigation path runs end to end.
    private func seeded() async throws -> ModelContainer {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 9000, daysAgo: 1...40, now: now
        )
        return container
    }

    private func context(_ container: ModelContainer) async throws -> DiscoveryContext {
        let provider = MetricStatsProvider(modelContainer: container)
        let series = try await provider.dailySeries(now: now)
        return DiscoveryContext(
            jobID: UUID(), now: now, deadline: nil, progress: nil,
            substrate: AnalysisSubstrate(provider: provider, series: series, now: now)
        )
    }

    private let productive = "chase this scout lead: steps rose — focus on stepCount"
    private let empty = "chase this scout lead: nothing here — focus on bodyMass"

    @Test func `an angle that was chased and produced nothing is journaled as barren`() async throws {
        let container = try await seeded()
        var fake = stepProposalFake()
        fake.lensesWithNoFindings = [empty]
        let orchestrator = makeOrchestrator(container, subagents: fake)

        let ctx = try await context(container)
        _ = await orchestrator.runInvestigation(
            ctx, lenses: [productive, empty], learnable: [productive, empty]
        )

        let writer = StoreWriter(modelContainer: container)
        let barren = try await writer.journalEntries(kind: .barren, limit: 8, now: now)
        #expect(barren.count == 1)
        #expect(barren.first?.contains("nothing here") == true)
        // The angle that DID produce is not recorded as barren.
        #expect(barren.allSatisfy { !$0.contains("steps rose") })
    }

    /// The distinction that makes the signal trustworthy. A session that never rendered — rate
    /// limited, or a model blip — tells you nothing about the angle, and recording it as barren would
    /// steer the director away from ground that was never actually examined.
    @Test func `an angle whose session never rendered is not called barren`() async throws {
        let container = try await seeded()
        var fake = stepProposalFake()
        fake.lensesThatFail = [empty]
        let orchestrator = makeOrchestrator(container, subagents: fake)

        let ctx = try await context(container)
        _ = await orchestrator.runInvestigation(
            ctx, lenses: [productive, empty], learnable: [productive, empty]
        )

        let writer = StoreWriter(modelContainer: container)
        #expect(try await writer.journalEntries(kind: .barren, limit: 8, now: now).isEmpty)
    }

    /// Only the INVENTED angles are learnable. The fixed thematic rotation comes back empty
    /// constantly and by design; journaling it would bury the scouts' signal in its own noise.
    @Test func `the fixed thematic rotation is never journaled as barren`() async throws {
        let container = try await seeded()
        var fake = stepProposalFake()
        fake.lensesWithNoFindings = [empty, "a fixed thematic angle"]
        let orchestrator = makeOrchestrator(container, subagents: fake)

        let ctx = try await context(container)
        _ = await orchestrator.runInvestigation(
            ctx,
            lenses: ["a fixed thematic angle", empty],
            learnable: [empty] // the rotation is not passed as learnable
        )

        let writer = StoreWriter(modelContainer: container)
        let barren = try await writer.journalEntries(kind: .barren, limit: 8, now: now)
        #expect(barren.count == 1)
        #expect(barren.first?.contains("nothing here") == true)
    }

    /// The journal prunes to a bounded row count globally, so a dry pass must not be able to evict
    /// the confirmed/rejected history that actually steers the fleet.
    @Test func `one pass cannot flood the journal with barren rows`() async throws {
        let container = try await seeded()
        let many = (0..<12).map { "chase this scout lead: angle \($0) — focus on bodyMass" }
        var fake = stepProposalFake()
        fake.lensesWithNoFindings = Set(many)
        let orchestrator = makeOrchestrator(container, subagents: fake)

        let ctx = try await context(container)
        _ = await orchestrator.runInvestigation(ctx, lenses: many, learnable: Set(many))

        let writer = StoreWriter(modelContainer: container)
        let barren = try await writer.journalEntries(kind: .barren, limit: 50, now: now)
        #expect(barren.count == Orchestrator.maxBarrenPerPass)
    }

    /// The mechanism was tested by calling `runInvestigation` directly. This tests the WIRING — that
    /// the deep loop actually computes `learnable` from the pass's invented angles and passes it.
    ///
    /// Those are different failures. If the loop passed `[]`, every unit test above would still be
    /// green and not one barren angle would ever be journaled in production: the feature would be
    /// fully implemented, fully tested, and completely inert.
    @Test func `a deep pass journals the scout leads that came back empty`() async throws {
        let container = try await seeded()
        var fake = stepProposalFake()
        fake.scoutLeads = [ProposedLead(
            hypothesis: "steps might lead body mass by three days",
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.bodyMass.rawValue
        )]
        // Every lead lens comes back empty; the thematic rotation still proposes, so the pass is not
        // uniformly dry and the barren entry cannot be an artifact of nothing happening at all.
        fake.lensesWithNoFindings = ["chase this scout lead:"]
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(
            now: now,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(400)),
            exhaustive: true
        )

        let writer = StoreWriter(modelContainer: container)
        let barren = try await writer.journalEntries(kind: .barren, limit: 8, now: now)
        #expect(!barren.isEmpty, "the deep loop journaled no barren angle — is `learnable` wired?")
        #expect(
            barren.contains { $0.contains("steps might lead body mass") },
            "journaled something, but not the scout lead: \(barren)"
        )
    }

    /// The half that keeps this from becoming another deterministic guard: barren angles are
    /// evidence for the director, never a do-not-repeat instruction pushed at every investigator.
    @Test func `barren angles never enter the do-not-repeat steering list`() async throws {
        let container = try await seeded()
        let writer = StoreWriter(modelContainer: container)
        let otherRun = UUID()
        try await writer.recordJournal(
            kind: .barren, text: "an angle that yielded nothing",
            // No reason, matching what the app now records: the barren line's own heading says
            // "Chased with no yield", so a constant reason on every row repeated the heading into
            // the director's prompt three times and diluted the lens text beside it.
            reason: "", jobRunID: otherRun, now: now
        )
        try await writer.recordJournal(
            kind: .rejected, text: "a claim the panel killed",
            reason: "coincidence", jobRunID: otherRun, now: now
        )

        let steering = try await writer.journalSteering(excludingRun: UUID(), now: now)
        #expect(steering.contains { $0.contains("a claim the panel killed") })
        #expect(!steering.contains { $0.contains("an angle that yielded nothing") })

        // It IS readable through the director's own query surface.
        let asked = try await writer.journalEntries(kind: .barren, limit: 8, now: now)
        #expect(asked.contains { $0.contains("an angle that yielded nothing") })
    }
}
