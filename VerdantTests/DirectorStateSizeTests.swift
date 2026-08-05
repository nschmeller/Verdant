import Foundation
import SwiftData
import Testing
@testable import Verdant

/// A bound on the research director's state, which is a prompt assembled from seven sources.
///
/// Each source is clamped on its own — five feed titles at 50 characters, four rejections, three
/// retirements, three prior dead ends, three barren angles (the journal truncates its text and reason
/// to 90 apiece), five untouched metric names. Nothing measured the SUM, and the state gained its
/// seventh line the same day that gap was written up for the panel claims.
///
/// It matters more here than the arithmetic suggests. The director runs once per pass for the life of
/// an indefinite run, and its window also has to hold the journal tool's schema and whatever the
/// journal returns. A state that crept toward the window would not produce a wrong plan — it would
/// produce no plan, and the loop would silently fall back to dry-streak arithmetic for the rest of
/// the run, which is precisely the deterministic behaviour the director exists to replace.
struct DirectorStateSizeTests {
    /// Measured at 2,350 with every source saturated — ~590 tokens, leaving the director's own
    /// instructions and its journal-tool schema comfortable room inside 4,096. The bound sits just
    /// above that so future growth trips it while today's reality passes.
    ///
    /// Worth noting what 2,350 is: the CLAMPS' worst case, not production's. The fixture writes
    /// 90-character reasons onto every journal row, where the app itself uses short literals and now
    /// none at all for barren angles. Bounding the mechanism rather than today's strings is
    /// deliberate — it stays honest if a reason gets longer later, which is the change that would
    /// otherwise slip through.
    ///
    /// It also corrected an estimate. Reasoning through the clamps beforehand gave ~1,900; the real
    /// figure was 20% higher. That is the third time in this codebase that adding up clamps by hand
    /// came out under the measurement.
    static let maxStateCharacters = 2600

    private func orchestrator(_ container: ModelContainer) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: FakeSubagents(),
            capability: { .available }
        )
    }

    /// Every source at its limit, with strings longer than any clamp, so the result measures the
    /// clamps rather than the fixture's politeness.
    private func saturated(_ writer: StoreWriter, _ ctx: DiscoveryContext) async throws {
        let long = String(repeating: "an overlong model-written phrase that keeps going ", count: 6)
        for index in 0..<8 {
            // A REALISTIC reason, not the 34-character constant this used to pass. Rejections now
            // carry the panel's own objection (`Orchestrator.rejection`), which is an order of
            // magnitude longer and rides four-deep into this state — the fixture has to reflect that
            // or the budget below is measured against a case that no longer happens.
            await ctx.ledger.record(
                title: "\(long)\(index)",
                reason: Orchestrator.rejection(
                    by: "skeptics",
                    outcome: PanelOutcome((0..<9).map { seat in
                        Verdict(
                            why: seat == 0 ? String(repeating: "a wordy objection ", count: 12) : "",
                            couldTest: true, holdsUp: false
                        )
                    })
                )
            )
            await ctx.ledger.recordRetirement(title: "\(long)\(index)")
            try await writer.recordJournal(
                kind: .rejected, text: "\(long)\(index)", reason: long, jobRunID: UUID()
            )
            try await writer.recordJournal(
                kind: .barren, text: "\(long)\(index)", reason: long, jobRunID: UUID()
            )
        }
        for (index, metric) in MetricKey.allCases.prefix(6).enumerated() {
            let fact = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline, recent: 12000, baseline: 8000,
                pctChange: 50, z: 6, n: 7, kind: .trend, direction: .up, magnitude: .large,
                salience: 60 + index
            )
            _ = try await writer.appendInsightIfNovel(
                fact: fact, phrasing: .init(summary: long, oneTapTitle: long), jobRunID: UUID()
            )
        }
    }

    @Test func `the assembled director state stays inside its budget`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 1...60, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
        var ctx = DiscoveryContext(
            jobID: UUID(), now: now, deadline: nil, progress: nil,
            substrate: substrate, adversarial: true
        )
        try await saturated(writer, ctx)

        let state = await orchestrator(container)
            .directorState(ctx, pass: 7, produced: 3, dryStreak: 2)

        // Non-vacuity: every line must actually be present, or this measures an empty string.
        for marker in [
            "Feed holds",
            "Rejected this run",
            "Retired this run",
            "Prior runs ruled out",
            "Chased with no yield"
        ] {
            #expect(state.contains(marker), Comment(rawValue: "\(marker) line missing from the state"))
        }
        #expect(
            state.count <= Self.maxStateCharacters,
            Comment(rawValue: "director state is \(state.count) characters")
        )
        _ = ctx
    }
}
