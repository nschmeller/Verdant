import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The verification loop's two arms — the armed replication panel on NEW proposals and the
/// standing-finding audit against FRESH data — plus the scout sweep and the collection loop's
/// persistence pieces, all driven through the deterministic fake.
struct ReplicationAuditTests {
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

    private func context(
        _ container: ModelContainer,
        now: Date = Date(),
        deadline: ContinuousClock.Instant? = nil,
        adversarial: Bool = true
    ) -> DiscoveryContext {
        let provider = MetricStatsProvider(modelContainer: container)
        return DiscoveryContext(
            jobID: UUID(), now: now, deadline: deadline, progress: nil,
            substrate: AnalysisSubstrate(provider: provider, series: [], now: now),
            adversarial: adversarial
        )
    }

    private func seedStepTrend(_ writer: StoreWriter, now: Date) async throws {
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)
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

    // MARK: The armed replication panel (new proposals)

    /// Every analyst must be given a DIFFERENT re-test, for the same reason the skeptic and safety
    /// panels must: a panel of identical reviewers is one reviewer counted several times. Here it
    /// would be worse than useless — the panel's job is to re-test a claim from angles its author did
    /// not choose, so three analysts all running the same check would re-confirm exactly the
    /// weakness the finding already survived, and report it as three independent confirmations.
    @Test func `every replication analyst is given a different re-test`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedStepTrend(writer, now: now)
        var fake = stepProposalFake()
        fake.composedRetests = ["re-run it on weekdays only"]
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        let asked = calls.replicateLenses
        #expect(!asked.isEmpty, "the panel never convened")
        #expect(Set(asked).count == asked.count, "a re-test was run twice: \(asked)")
        // Each fixed re-test must be ASKED, allowing for per-run steering appended to it (the
        // available-metrics shortlist rides on the lens, exactly as it does for investigators). The
        // claim here is coverage and distinctness, not that the string arrives verbatim.
        for lens in Orchestrator.replicationLenses {
            #expect(
                asked.contains { $0.hasPrefix(lens) },
                Comment(rawValue: "no analyst was given: \(lens.prefix(50))")
            )
        }
    }

    @Test func `a finding the replication panel refutes is dropped even after the skeptics pass`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedStepTrend(writer, now: now)
        // Skeptics endorse (default), but the armed re-test against the data fails — the finding
        // exists only in the window that produced it, and must not surface.
        var fake = stepProposalFake()
        fake.replicationHoldsUp = false
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        // Raw rows, not `snapshotsForSearch`: that read filters tombstoned findings, so "the panel
        // dropped it" and "it was written and then hidden" would look identical. The claim being
        // tested is that a refuted finding is never persisted at all.
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CorrelationLog>()) == 0)
    }

    @Test func `the replication panel runs AFTER the skeptic panel`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedStepTrend(writer, now: now)
        // When the skeptics reject, the replication panel must never be spent on the corpse.
        var fake = stepProposalFake()
        fake.scrutinyHoldsUp = false
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        #expect(calls.replicateClaims.isEmpty)
    }

    @Test func `replication falls open when every armed analyst fails on infrastructure`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.replicationFails = true
        let orchestrator = makeOrchestrator(container, subagents: fake)
        let ctx = context(container)
        // Rendered-verdict aggregation mirrors the skeptic panel: zero rendered verdicts is an
        // infra failure, not a quality judgment — the skeptic-passed finding is kept. (This is also
        // the documented trade-off: a wholly rate-limited background run gets no ADDED verification.)
        let survives = try await orchestrator.survivesReplication(
            "a claim", subject: "a test finding", metrics: [.stepCount],
            substrate: #require(ctx.substrate), ctx
        )
        #expect(survives.passed)
    }

    @Test func `replication fails closed when the budget is spent before the panel can run`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let orchestrator = makeOrchestrator(container, subagents: FakeSubagents())
        let ctx = context(container, deadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        let survives = try await orchestrator.survivesReplication(
            "a claim", subject: "a test finding", metrics: [.stepCount],
            substrate: #require(ctx.substrate), ctx
        )
        #expect(!survives.passed)
    }

    @Test func `replication is bypassed when adversarial is off`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.replicationHoldsUp = false
        let orchestrator = makeOrchestrator(container, subagents: fake)
        let ctx = context(container, adversarial: false)
        let survives = try await orchestrator.survivesReplication(
            "a claim", subject: "a test finding", metrics: [.stepCount],
            substrate: #require(ctx.substrate), ctx
        )
        #expect(survives.passed)
    }

    // MARK: The standing-finding audit

    @Test func `the audit retires a standing finding that no longer replicates`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedStepTrend(writer, now: now)
        // Surface a finding the usual way (every panel endorses)…
        await makeOrchestrator(container, subagents: stepProposalFake()).runDiscovery(now: now)
        #expect(try await writer.snapshotsForSearch(now: now).count == 1)

        // …then audit it against "fresh" data with a panel that refutes it.
        var fake = FakeSubagents()
        fake.replicationHoldsUp = false
        let orchestrator = makeOrchestrator(container, subagents: fake)
        let retired = await orchestrator.auditStandingFindings(context(container, now: now))

        #expect(retired == 1)
        // The audit RETIRES rather than deletes, so the correct claim here is the opposite of the
        // one above: the row must still exist and be tombstoned. `snapshotsForSearch` alone could
        // not tell that apart from the row never having been written.
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<InsightLog>())
        #expect(rows.count == 1, "the retired finding should still be on disk, tombstoned")
        let allTombstoned = rows.allSatisfy(\.tombstoned)
        #expect(allTombstoned, "the audit did not tombstone it")
        #expect(try await writer.snapshotsForSearch(now: now).isEmpty, "it is still surfaced")
    }

    @Test func `the audit keeps a standing finding that still replicates`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedStepTrend(writer, now: now)
        await makeOrchestrator(container, subagents: stepProposalFake()).runDiscovery(now: now)

        let orchestrator = makeOrchestrator(container, subagents: FakeSubagents())
        let retired = await orchestrator.auditStandingFindings(context(container, now: now))

        #expect(retired == 0)
        #expect(try await writer.snapshotsForSearch(now: now).count == 1)
    }

    /// The armed panel is sized to the claim, like the skeptic panel: a planner names the
    /// computation that would expose THIS claim specifically, and each becomes another analyst.
    /// Additive in both directions — extras are added, silence changes nothing.
    @Test func `the planner's re-tests become extra armed analysts`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.composedRetests = ["recompute at lag 0 — a lead-lag claim dies if lag 0 is stronger", " "]
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)
        let ctx = context(container)

        let survives = try await orchestrator.survivesReplication(
            "a claim", subject: "a test finding", metrics: [.stepCount],
            substrate: #require(ctx.substrate), ctx
        )

        #expect(survives.passed)
        #expect(survives.rendered == Orchestrator.replicationLenses.count + 1) // blank dropped
        #expect(calls.replicateLenses.contains { $0.contains("a lead-lag claim dies if lag 0 is stronger") })
    }

    @Test func `a silent planner leaves the armed panel untouched`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let orchestrator = makeOrchestrator(container, subagents: FakeSubagents())
        let ctx = context(container)

        let survives = try await orchestrator.survivesReplication(
            "a claim", subject: "a test finding", metrics: [.stepCount],
            substrate: #require(ctx.substrate), ctx
        )

        #expect(survives.rendered == Orchestrator.replicationLenses.count)
    }

    /// The docket used to be the strongest `limit` findings at EVERY refresh, forever — so with a
    /// feed of 11 and a docket of 4, anything ranked 5+ was re-tested exactly never, and a
    /// mid-ranked claim that had quietly stopped holding could sit on the feed for the life of the
    /// app. Successive rounds must sweep the whole feed.
    @Test func `the audit docket rotates so every standing finding is eventually re-tested`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let metrics: [MetricKey] = [
            .stepCount, .vo2Max, .bodyMass, .restingHeartRate, .activeEnergyBurned, .respiratoryRate
        ]
        for (index, metric) in metrics.enumerated() {
            let seeded = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline,
                recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
                kind: .trend, direction: .up, magnitude: .large, salience: 90 - index * 10
            )
            _ = try await writer.appendInsightIfNovel(
                fact: seeded, phrasing: FindingPhrasing.phrasing(for: seeded),
                jobRunID: UUID(), now: now
            )
        }

        let docket = 2
        var seen = Set<String>()
        // Ceil(6 / 2) rounds is exactly one full sweep of the feed.
        for round in 0..<3 {
            let batch = try await writer.auditCandidates(limit: docket, round: round)
            #expect(batch.count == docket)
            seen.formUnion(batch.map(\.title))
        }
        #expect(seen.count == metrics.count) // every finding faced the panel, not just the top two

        // Round 0 is still the strongest first — rotation changes WHEN, never the ranking.
        let first = try await writer.auditCandidates(limit: docket, round: 0)
        #expect(first.first?.title.contains(MetricKey.stepCount.displayName) == true)
    }

    @Test func `auditCandidates lists active findings and retire is a defensive no-op on ghosts`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedStepTrend(writer, now: now)
        await makeOrchestrator(container, subagents: stepProposalFake()).runDiscovery(now: now)

        let candidates = try await writer.auditCandidates(limit: 4)
        #expect(candidates.count == 1)
        #expect(candidates.first?.title == "Steps up")

        let target = try #require(candidates.first?.target)
        try await writer.retire(target)
        #expect(try await writer.auditCandidates(limit: 4).isEmpty)
        // Retiring an already-retired (or hard-deleted) finding must be a no-op, not a crash —
        // Settings' delete-all can race a deep run.
        try await writer.retire(target)
        try await writer.deleteAllInsights()
        try await writer.retire(target)
    }

    // MARK: The scout sweep

    @Test func `the scout sweep runs scoutsPerPass surveyors, dedups, and remembers its leads`(
    ) async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.scoutLeads = [
            ProposedLead(
                hypothesis: "steps dip before poor sleep",
                metric: "stepCount",
                secondaryMetric: "sleepDurationHours"
            ),
            ProposedLead(
                hypothesis: "HRV sags on Mondays",
                metric: "heartRateVariabilitySDNN",
                secondaryMetric: "heartRateVariabilitySDNN"
            )
        ]
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)
        let ctx = context(container)

        let leads = await orchestrator.runScoutSweep(ctx, pass: 1, exhaustedBreadth: false)

        #expect(calls.scoutLenses.count == DeepAnalysisPolicy.scoutsPerPass)
        // Both scouts return the same two leads — dedup collapses them.
        #expect(leads.count == 2)
        let remembered = await ctx.ledger.recentLeads()
        #expect(remembered.count == 2)
    }

    @Test func `a dry breadth pass pushes the scouts into unvisited ground`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        _ = await orchestrator.runScoutSweep(context(container), pass: 3, exhaustedBreadth: true)

        #expect(calls.scoutLenses.allSatisfy { $0.contains("Previous sweeps ran dry") })
    }

    // MARK: Deep-run loop discipline

    @Test func `an already-expired deadline stops the deep loop before any agent is spent`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        let produced = await orchestrator.runDiscovery(
            deadline: ContinuousClock.now.advanced(by: .seconds(-1)), exhaustive: true
        )

        #expect(produced == 0)
        #expect(calls.scoutLenses.isEmpty)
        #expect(calls.investigateLenses.isEmpty)
    }

    // MARK: Collection-loop persistence pieces

    @Test func `earliestRollupDay finds the oldest day and deepen markers ride the ingest cache`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        #expect(try await writer.earliestRollupDay(for: .stepCount) == nil)
        try await TestSupport.seed(writer, metric: .stepCount, value: 9000, daysAgo: 5...10, now: now)
        let earliest = try #require(try await writer.earliestRollupDay(for: .stepCount))
        let expected = try #require(Calendar.civil.date(
            byAdding: .day, value: -10, to: Calendar.civil.startOfDay(for: now)
        ))
        #expect(earliest == expected)

        #expect(try await !writer.hasDeepenedHistory(for: .stepCount))
        try await writer.markHistoryDeepened(for: .stepCount)
        try await writer.markHistoryDeepened(for: .stepCount) // idempotent
        #expect(try await writer.hasDeepenedHistory(for: .stepCount))
        // Markers share the ingest cache's lifecycle exactly: a reset re-deepens automatically.
        try await writer.resetIngestCache()
        #expect(try await !writer.hasDeepenedHistory(for: .stepCount))
    }

    @Test func `an old-version deepen marker does not count — 1825-era installs re-deepen`(
    ) async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // The 1,825-day era wrote "deepened#<metric>" markers; the all-time horizon uses a
        // versioned key precisely so those installs deepen once more to their true beginning.
        // This pins the migration trigger: an old-key row must NOT read as already-deepened.
        try await writer.seedLegacyDeepenMarker(for: .stepCount)
        #expect(try await !writer.hasDeepenedHistory(for: .stepCount))
    }
}
