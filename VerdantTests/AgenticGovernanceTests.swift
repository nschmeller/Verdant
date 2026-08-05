import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The agent-governance layer: the novelty judge (freshness is an agent decision), the curator
/// (feed slots are an agent decision), the research director (pass strategy is an agent decision),
/// and the persistent research journal (cross-run memory). Deterministic behaviors survive ONLY as
/// infra-failure fallbacks, and these tests pin both sides of that line.
struct AgenticGovernanceTests {
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

    private func seedMaterialSteps(_ writer: StoreWriter, now: Date) async throws {
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

    private func fact(_ metric: MetricKey, salience: Int, comparison: ComparisonKey = .recentVsBaseline)
        -> VerifiedFact
    {
        VerifiedFact(
            metric: metric, comparison: comparison,
            recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: salience
        )
    }

    // MARK: Novelty judge

    @Test func `a colliding proposal is judged, and a re-tread verdict drops it`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        var fake = stepProposalFake()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(now: now)
        // Second run a day later re-proposes the same finding: a collision the judge must rule on.
        await orchestrator.runDiscovery(now: now.addingTimeInterval(86400))

        // The default fake verdict is "re-tread" — the standing finding keeps its slot.
        #expect(calls.noveltyPriors.count == 1)
        let steps = try await writer.snapshotsForSearch(now: now)
            .filter { $0.metric == MetricKey.stepCount.rawValue }
        #expect(steps.count == 1)
    }

    @Test func `a meaningful-update verdict lets the candidate through`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        var fake = stepProposalFake()
        fake.noveltyIsUpdate = true
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(now: now)
        await orchestrator.runDiscovery(now: now.addingTimeInterval(86400))

        // Judge-approved update appends alongside the standing finding; the curator (keep-all in
        // this fake) then weighs both.
        let steps = try await writer.snapshotsForSearch(now: now)
            .filter { $0.metric == MetricKey.stepCount.rawValue }
        #expect(steps.count == 2)
    }

    // MARK: Curator

    @Test func `the curator's keep-list decides the feed — numbers left out are retired`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        for (index, metric) in [MetricKey.stepCount, .vo2Max, .bodyMass].enumerated() {
            _ = try await writer.appendInsightIfNovel(
                fact: fact(metric, salience: 30 + index * 30),
                phrasing: FindingPhrasing.phrasing(for: fact(metric, salience: 30 + index * 30)),
                jobRunID: UUID(), now: now
            )
        }
        var fake = FakeSubagents()
        fake.curationKeep = [0] // roster is strongest-first: keep only the salience-90 finding
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.curate(now: now)

        let active = try await writer.snapshotsForSearch(now: now)
        #expect(active.count == 1)
        #expect(active.first?.metric == MetricKey.bodyMass.rawValue)
    }

    /// The director set the pass's STRATEGY but its lens roster was a fixed rotation, so anything
    /// that roster structurally cannot ask went unasked. It can now compose angles of its own —
    /// ADDED to the fleet, never substituted, so a terse director can't narrow a pass.
    @Test func `the director's composed lenses reach the fleet without replacing it`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.passPlan = PassPlan(
            strategy: "breadth",
            directive: "chase the sleep signal",
            extraLenses: ["wrist temperature against sleep onset", "   ", "glucose after long walks"]
        )
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(
            now: now,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(300)),
            exhaustive: true
        )

        let lenses = calls.investigateLenses
        #expect(lenses.contains { $0.contains("wrist temperature against sleep onset") })
        #expect(lenses.contains { $0.contains("glucose after long walks") })
        // Blank angles are dropped rather than spending an investigator session on no instruction.
        #expect(!lenses.contains { $0.hasSuffix("research director chose for this pass: ") })
        // Additive: the standard thematic roster still ran alongside them.
        #expect(lenses.contains { $0.contains("REGIME SHIFTS") })
    }

    /// The director's own view of the fleet's cross-run memory. Every other agent has this history
    /// PUSHED at it as a clamped do-not-repeat list; the director is the one whose job is deciding
    /// FROM history, so it can query the record by kind instead of judging from the three lines the
    /// briefing happened to pick.
    @Test func `the journal tool answers by kind, with the panel's reason attached`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let run = UUID()
        try await writer.recordJournal(kind: .confirmed, text: "Sleep leads HRV", jobRunID: run, now: now)
        try await writer.recordJournal(
            kind: .rejected, text: "Steps drive weight",
            reason: "the skeptics called it a tautology", jobRunID: run, now: now
        )
        try await writer.recordJournal(kind: .retired, text: "VO2 max record", jobRunID: run, now: now)

        let tool = ResearchJournalTool(writer: writer, now: now)
        let confirmed = try await tool.call(arguments: .init(kind: "confirmed", limit: 8))
        #expect(confirmed.lines == ["Sleep leads HRV"])
        // A rejection carries WHY — the whole point of asking rather than being handed a title.
        let rejected = try await tool.call(arguments: .init(kind: "rejected", limit: 8))
        #expect(rejected.lines == ["Steps drive weight — the skeptics called it a tautology"])
        #expect(try await tool.call(arguments: .init(kind: "retired", limit: 8)).lines.count == 1)
        // Closed vocabulary, same as every other tool: an unknown kind yields nothing rather than
        // being coerced into one the director didn't ask for.
        #expect(try await tool.call(arguments: .init(kind: "invented", limit: 8)).lines.isEmpty)
    }

    /// End to end: a finding whose PROSE states a statistic nothing computed must reach the skeptic
    /// panel carrying that fact. The prose is the one thing the app shows verbatim, and it was the
    /// last place a hallucinated number could travel unchecked.
    @Test func `a figure the engines never computed is put in front of the skeptics`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        var fake = stepProposalFake()
        // The seeded trend is roughly 12,000 vs 8,000. "312%" is from nowhere.
        fake.proposals = [ProposedFinding(
            kind: InsightKind.trend.rawValue,
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Steps up",
            story: "Your steps rose 312% over the period — a remarkable change.",
            worth: 80
        )]
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(now: now)

        let claim = try #require(calls.scrutinyClaims.first)
        #expect(claim.contains("NO verified number supports"))
        #expect(claim.contains("312%"))
    }

    /// Closing the hypothesis loop. The journal recorded WHAT was established but never what kind of
    /// looking established it, so nothing could learn that one angle keeps paying off while another
    /// never does — least of all the director, whose job is choosing where to point the fleet. The
    /// angle now rides on the confirmation, and reaches the director through its journal tool.
    @Test func `a confirmed finding records the angle that found it, and the director can read it`(
    ) async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        let orchestrator = makeOrchestrator(container, subagents: stepProposalFake())

        await orchestrator.runDiscovery(now: now)

        let confirmed = try await ResearchJournalTool(writer: writer, now: now)
            .call(arguments: .init(kind: "confirmed", limit: 8))
        let line = try #require(confirmed.lines.first)
        #expect(line.contains("Steps up"))
        // The first investigation lens is the one the fake's single proposal is attributed to.
        let angle = try #require(Instructions.investigationLenses.first)
        #expect(line.contains(String(angle.prefix(40))))

        // …and it does NOT leak into the do-not-repeat steering, which would teach the fleet to
        // avoid the very angles that work.
        let steering = try await writer.journalSteering(excludingRun: UUID(), now: now)
        #expect(!steering.contains { $0.contains("Steps up") })
    }

    /// Settings promises delete-all removes "its memory of what it's already shown you" and that
    /// "Verdant can rediscover findings over time". The journal is that memory — and its rejections
    /// are pushed at every investigator as "do NOT re-propose", so leaving it behind broke the
    /// promise twice: the memory survived, and the fleet kept avoiding the ground just cleared.
    @Test func `delete-all clears the research journal, so the slate is genuinely clean`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // A run that both surfaces a finding and records dead ends in the journal.
        var fake = stepProposalFake()
        fake.scrutinyHoldsUp = false // everything is rejected → journal fills with dead ends
        await makeOrchestrator(container, subagents: fake).runDiscovery(now: now)
        #expect(try await !(writer.journalSteering(excludingRun: UUID(), now: now)).isEmpty)

        try await writer.deleteJournal()

        // Nothing left to steer the next run away from ground the user asked to clear.
        #expect(try await writer.journalSteering(excludingRun: UUID(), now: now).isEmpty)
        #expect(try await writer.journalEntries(kind: .rejected, limit: 8, now: now).isEmpty)
        #expect(try await writer.journalEntries(kind: .confirmed, limit: 8, now: now).isEmpty)
    }

    // MARK: Provenance

    /// A kept finding records WHO proposed it and WHAT the panels decided — the panels are the most
    /// expensive reasoning in the app, and their verdicts used to scroll past in the live feed and
    /// be gone. Pins the end-to-end wiring: lens → panels → persisted row.
    @Test func `a kept finding records the lens that proposed it and the panels' tallies`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        let orchestrator = makeOrchestrator(container, subagents: stepProposalFake())

        await orchestrator.runDiscovery(now: now)

        let provenance = try await writer.provenanceForTest()
        #expect(provenance.count == 1)
        let line = try #require(provenance.first)
        #expect(line.contains("Proposed by the investigator on"))
        // Both panels ran and their tallies are recorded, not just the fact that they passed.
        #expect(line.contains("\(Orchestrator.scrutinyLenses.count) skeptics held it up"))
        #expect(line.contains("\(Orchestrator.replicationLenses.count) replication analysts held it up"))
    }

    /// The rendering itself, away from the pipeline: a panel that never convened contributes no
    /// clause (rather than an honest-looking "0/0"), and a panelist's words are quoted.
    @Test func `the provenance line omits panels that never convened and quotes a panelist`() {
        let skeptics = PanelOutcome([
            Verdict(why: "the effect survives dropping the extremes", couldTest: true, holdsUp: true),
            Verdict(why: "", couldTest: true, holdsUp: true)
        ])
        let line = Orchestrator.provenanceLine(
            lens: "sleep and its downstream effects",
            skeptics: skeptics,
            replication: .notConvened
        )
        #expect(line.contains("sleep and its downstream effects"))
        #expect(line.contains("2/2 skeptics held it up"))
        #expect(!line.contains("replication analysts"))
        #expect(line.contains("the effect survives dropping the extremes"))
    }

    /// "Worth your attention" is now a curator decision, not `quality >= 60` + a top-3 slice in the
    /// view. Pins both halves: what the curator names is promoted, and a promotion it withholds (or
    /// aims at something it retired) never reaches the feed.
    @Test func `the curator's highlight list — not a score threshold — promotes findings`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        for (index, metric) in [MetricKey.stepCount, .vo2Max, .bodyMass].enumerated() {
            _ = try await writer.appendInsightIfNovel(
                fact: fact(metric, salience: 30 + index * 30),
                phrasing: FindingPhrasing.phrasing(for: fact(metric, salience: 30 + index * 30)),
                jobRunID: UUID(), now: now
            )
        }
        var fake = FakeSubagents()
        fake.curationKeep = [0, 1]
        // #1 is the MIDDLE-scoring finding, and #2 is retired — so a threshold or a top-N slice
        // cannot produce this outcome, and a promotion of a retired row must be dropped.
        fake.curationHighlight = [1, 2]
        await makeOrchestrator(container, subagents: fake).curate(now: now)

        let promoted = try await writer.highlightedTitlesForTest()
        #expect(promoted.count == 1)
        // Roster is strongest-first: #0 is salience-90 (bodyMass), #1 is salience-60 (vo2Max).
        #expect(promoted.first?.contains(MetricKey.vo2Max.displayName) == true)
    }

    @Test func `curator infra failure falls back to the deterministic trim`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // Two findings on the SAME metric: the deterministic fallback's one-per-metric rule keeps
        // one; an agent keep-all would keep both — so the outcome tells the two paths apart.
        _ = try await writer.appendInsightIfNovel(
            fact: fact(.stepCount, salience: 80),
            phrasing: FindingPhrasing.phrasing(for: fact(.stepCount, salience: 80)),
            jobRunID: UUID(), now: now
        )
        _ = try await writer.appendInsightIfNovel(
            fact: fact(.stepCount, salience: 60, comparison: .weekOverWeek),
            phrasing: FindingPhrasing.phrasing(for: fact(
                .stepCount,
                salience: 60,
                comparison: .weekOverWeek
            )),
            jobRunID: UUID(), now: now
        )
        var fake = FakeSubagents()
        fake.curatorFails = true
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.curate(now: now)

        #expect(try await writer.snapshotsForSearch(now: now).count == 1)
    }

    @Test func `an agent keep-all keeps same-metric findings the old trim would have dropped`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        _ = try await writer.appendInsightIfNovel(
            fact: fact(.stepCount, salience: 80),
            phrasing: FindingPhrasing.phrasing(for: fact(.stepCount, salience: 80)),
            jobRunID: UUID(), now: now
        )
        _ = try await writer.appendInsightIfNovel(
            fact: fact(.stepCount, salience: 60, comparison: .weekOverWeek),
            phrasing: FindingPhrasing.phrasing(for: fact(
                .stepCount,
                salience: 60,
                comparison: .weekOverWeek
            )),
            jobRunID: UUID(), now: now
        )
        let orchestrator = makeOrchestrator(container, subagents: FakeSubagents())

        await orchestrator.curate(now: now)

        // The curation DECISION was the agent's: keep-all means both stay.
        #expect(try await writer.snapshotsForSearch(now: now).count == 2)
    }

    // MARK: Research journal (cross-run memory)

    @Test func `journal clamps model-written text and excludes the current run from steering`() async throws {
        let writer = try StoreWriter(modelContainer: TestSupport.inMemoryContainer())
        let now = Date()
        let thisRun = UUID()
        let priorRun = UUID()
        try await writer.recordJournal(
            kind: .rejected, text: String(repeating: "x", count: 300),
            reason: "too thin", jobRunID: priorRun, now: now
        )
        try await writer.recordJournal(
            kind: .rejected, text: "current-run dead end", reason: "", jobRunID: thisRun, now: now
        )

        let steering = try await writer.journalSteering(excludingRun: thisRun, now: now)
        #expect(steering.count == 1)
        #expect(steering.first?.contains("too thin") == true)
        // Clamped at write time: 90 chars of text plus the reason suffix.
        #expect((steering.first?.count ?? .max) < 120)
    }

    @Test func `journal prunes to a bounded row count, newest kept`() async throws {
        let writer = try StoreWriter(modelContainer: TestSupport.inMemoryContainer())
        let now = Date()
        for index in 0..<10 {
            try await writer.recordJournal(
                kind: .rejected, text: "entry \(index)", reason: "",
                jobRunID: UUID(), now: now.addingTimeInterval(Double(index))
            )
        }
        try await writer.pruneJournal(keep: 4)
        let remaining = try await writer.journalSteering(
            excludingRun: UUID(), limit: 20, now: now.addingTimeInterval(10)
        )
        #expect(remaining.count == 4)
        #expect(remaining.contains("entry 9")) // newest survive
        #expect(!remaining.contains("entry 0"))
    }

    @Test func `a prior run's dead ends steer the next run's investigators`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedMaterialSteps(writer, now: now)
        // Run 1: the proposal dies at the safety panel — a journaled dead end.
        var unsafeFake = stepProposalFake()
        unsafeFake.safetyIsSafe = false
        await makeOrchestrator(container, subagents: unsafeFake).runDiscovery(now: now)

        // Run 2 (a fresh job): its investigators must be steered away from that dead end.
        var fake = FakeSubagents()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        await makeOrchestrator(container, subagents: fake)
            .runDiscovery(now: now.addingTimeInterval(3600))

        #expect(calls.investigateLenses.contains { lens in
            lens.contains("dead ends from earlier runs") && lens.contains("Steps up")
        })
    }

    // MARK: Research director

    /// The third routing branch. `frontier` means "whole corners of the data are untouched", and it
    /// must push the scouts into unvisited ground on the DIRECTOR's say-so — not only after the
    /// deterministic dry-streak fallback has already noticed. Pinning it on pass 1, where the dry
    /// streak is zero, is what proves the director's choice alone did it.
    @Test func `a frontier plan pushes the scouts into unvisited ground on pass one`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.passPlan = PassPlan(
            strategy: "frontier", directive: "the oldest windows nobody has examined", extraLenses: []
        )
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        await orchestrator.runDiscovery(
            now: now,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(300)),
            exhaustive: true
        )

        #expect(!calls.scoutLenses.isEmpty) // frontier scouts, unlike drill
        #expect(calls.scoutLenses.allSatisfy { $0.contains("Previous sweeps ran dry") })
    }

    @Test func `a drill plan routes the deep pass away from scouting`() async throws {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.passPlan = PassPlan(
            strategy: "drill",
            directive: "dig into the strongest finding",
            extraLenses: []
        )
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, subagents: fake)

        // A short real deadline lets a handful of passes run, then stops the indefinite loop.
        await orchestrator.runDiscovery(
            now: now,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(300)),
            exhaustive: true
        )

        // The director was consulted, its drill routing skipped the scout sweep entirely (an
        // empty feed means drilling finds no foci, but the strategy decision is what's pinned).
        #expect(!calls.directStates.isEmpty)
        #expect(calls.scoutLenses.isEmpty)
    }
}
