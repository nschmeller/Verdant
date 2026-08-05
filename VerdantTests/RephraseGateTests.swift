import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The one rewrite the safety gate allows, and the four ways it must NOT become a loophole.
///
/// Built after a measured full run: the panel refused nine of fourteen proposals and was right about
/// all nine — the fleet had written causes and alarm into findings whose numbers were fine ("caused
/// by improved cardiovascular fitness", "increased stress", "an anomaly, which is alarming"). All
/// three proposals that found a planted resting-heart-rate step died here rather than at the
/// skeptics. So the rewrite exists to fix PROSE, and these tests exist because a retry on a
/// fail-closed gate is exactly the kind of thing that rots into a rubber stamp.
struct RephraseGateTests {
    private struct Fixture {
        let writer: StoreWriter
        let provider: MetricStatsProvider
        let now: Date

        func run(_ fake: FakeSubagents) async -> Int {
            await Orchestrator(
                provider: provider, writer: writer, embeddings: Embeddings(),
                subagents: fake, capability: { .available }
            ).runDiscovery(now: now)
        }
    }

    private func fixture() async throws -> Fixture {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...30, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 31...120, now: now)
        return Fixture(
            writer: writer, provider: MetricStatsProvider(modelContainer: container), now: now
        )
    }

    private func proposal() -> ProposedFinding {
        ProposedFinding(
            kind: InsightKind.trend.rawValue, metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Steps Up", story: "Your steps rose, an ALARMING jump caused by new habits.",
            worth: 80
        )
    }

    /// The rescue: a rewrite that drops the offending phrase clears the SAME panel, and the finding
    /// is stored as the REWRITE — not as the prose the panel refused.
    @Test func `a rewrite that clears the panel is what gets stored`() async throws {
        let fx = try await fixture()
        var fake = FakeSubagents()
        fake.proposals = [proposal()]
        fake.safetyRefusesTextContaining = "ALARMING"
        fake.rephrasedSummary = "Your steps averaged 12,000 over the last 30 days, against 8,000 before."
        fake.rephrasedTitle = "Steps Up"
        let kept = await fx.run(fake)
        #expect(kept > 0, "the rewrite cleared the panel but nothing was kept")
        let stored = try await fx.writer.provenanceForTest()
        #expect(!stored.isEmpty)
        let summaries = try await fx.writer.activeSummariesForTest()
        #expect(
            summaries.contains { !$0.contains("ALARMING") && $0.contains("12,000") },
            Comment(rawValue: "stored prose is not the rewrite: \(summaries)")
        )
    }

    /// The bar is unchanged: a rewrite the panel refuses AGAIN is dropped, and the reason recorded is
    /// the SECOND refusal — the objection to the best version of the prose.
    @Test func `a rewrite the panel refuses again is dropped`() async throws {
        let fx = try await fixture()
        var fake = FakeSubagents()
        fake.proposals = [proposal()]
        fake.safetyIsSafe = false
        fake.safetyWhy = "names a condition as the user's"
        fake.rephrasedSummary = "A rewritten summary that the panel still will not accept."
        let kept = await fx.run(fake)
        #expect(kept == 0, "a finding the panel refused twice was persisted")
        let journal = try await fx.writer.journalEntries(kind: .rejected, limit: 5, now: fx.now)
        #expect(
            journal.contains { $0.contains("names a condition") },
            Comment(rawValue: "the second refusal is not what was recorded: \(journal)")
        )
    }

    /// The rephraser is told to return the summary unchanged when a finding cannot be said plainly.
    /// That must drop it WITHOUT spending another panel — five sessions to be told the same thing.
    @Test func `an unchanged rewrite is dropped without a second panel`() async throws {
        let fx = try await fixture()
        var fake = FakeSubagents()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        fake.proposals = [proposal()]
        fake.safetyIsSafe = false
        fake.rephrasedSummary = nil // the fake then echoes the original back
        let kept = await fx.run(fake)
        #expect(kept == 0)
        // Exactly one panel: five lenses, not ten.
        #expect(
            calls.safetyLenses.count == Orchestrator.safetyLenses.count,
            Comment(rawValue: "ran \(calls.safetyLenses.count) safety reviews — a second panel on "
                + "identical text")
        )
    }

    /// A panel that never rendered said nothing ABOUT THE PROSE. Rewriting toward that would have the
    /// rephraser invent an objection, so no rewrite is attempted at all.
    @Test func `a quorum failure is not sent to the rephraser`() async throws {
        let fx = try await fixture()
        var fake = FakeSubagents()
        fake.proposals = [proposal()]
        fake.safetyFails = true // no reviewer renders
        fake.rephrasedSummary = "This rewrite must never be reached."
        let kept = await fx.run(fake)
        #expect(kept == 0)
        let journal = try await fx.writer.journalEntries(kind: .rejected, limit: 5, now: fx.now)
        #expect(
            journal.contains { $0.contains("could not be reached") },
            Comment(rawValue: "a quorum failure was not reported as one: \(journal)")
        )
    }
}
