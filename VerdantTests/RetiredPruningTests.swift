import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Bounding the retired findings, which nothing did.
///
/// `pruneJournal` exists because "an INDEFINITE research program appends entries for as long as the
/// app stays open, so an unpruned table would grow without limit". Exactly the same is true of
/// retired findings — curation retires some every pass, a tombstoned row is never deleted otherwise,
/// and only a user's "delete all" clears them — and only the journal was bounded.
///
/// The cost lands twice: the store grows for as long as the app runs (each row carries prose and an
/// embedding), and `setHighlights` scans EVERY row including tombstones on every curation round, so
/// the scan slows in proportion to how long the program has been running. Which is the app's
/// headline use case.
struct RetiredPruningTests {
    /// Distinct metrics, because `appendInsightIfNovel` dedups by (metric, comparison) within its
    /// lookback — twelve appends for one metric produce one row, and the test would have measured
    /// nothing. Retired directly rather than through `retire(_:)`, which keys on the row's own UUID
    /// while the append returns a `PersistentIdentifier`: this test is about the pruning, not the
    /// route into a tombstone.
    private func seedRetired(
        _ container: ModelContainer, _ writer: StoreWriter, count: Int, now: Date
    ) async throws {
        for (index, metric) in MetricKey.allCases.prefix(count).enumerated() {
            let fact = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline, recent: Double(9000 + index),
                baseline: 8000, pctChange: 12, z: 3, n: 7, kind: .trend, direction: .up,
                magnitude: .moderate, salience: 50
            )
            _ = try await writer.appendInsightIfNovel(
                fact: fact, phrasing: .init(summary: "S\(index)", oneTapTitle: "T\(index)"),
                jobRunID: UUID(), now: now.addingTimeInterval(Double(index))
            )
        }
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<InsightLog>()) {
            row.tombstoned = true
        }
        try context.save()
    }

    @Test func `retired findings beyond the cap are deleted, newest kept`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()
        try await seedRetired(container, writer, count: 12, now: now)

        let before = ModelContext(container)
        let retiredBefore = try before.fetch(FetchDescriptor<InsightLog>()).count { $0.tombstoned }
        #expect(retiredBefore == 12, "the fixture retired \(retiredBefore) — nothing to prune")

        try await writer.pruneRetiredFindings(keep: 5)

        let after = ModelContext(container)
        let rows = try after.fetch(FetchDescriptor<InsightLog>())
        #expect(rows.count { $0.tombstoned } == 5, "kept \(rows.count { $0.tombstoned })")
        // The NEWEST are kept: a just-retired finding is the one a person might still ask about.
        let titles = Set(rows.filter(\.tombstoned).map(\.oneTapTitle))
        #expect(titles.contains("T11"), "the most recent retirement was pruned")
        #expect(!titles.contains("T0"), "the oldest retirement survived")
    }

    /// Active findings are never touched — the whole point is that this bounds history, not the feed.
    @Test func `an active finding is never pruned`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()
        try await seedRetired(container, writer, count: 8, now: now)
        let fact = VerifiedFact(
            metric: .vo2Max, comparison: .recentVsBaseline, recent: 44, baseline: 40, pctChange: 10,
            z: 3, n: 7, kind: .trend, direction: .up, magnitude: .moderate, salience: 70
        )
        _ = try await writer.appendInsightIfNovel(
            fact: fact, phrasing: .init(summary: "Live", oneTapTitle: "Still standing"),
            jobRunID: UUID(), now: now
        )

        try await writer.pruneRetiredFindings(keep: 1)

        let after = ModelContext(container)
        let active = try after.fetch(FetchDescriptor<InsightLog>()).filter { !$0.tombstoned }
        #expect(active.count == 1)
        #expect(active.first?.oneTapTitle == "Still standing")
    }

    /// Under the cap, nothing is deleted and no save is forced.
    @Test func `a short history is left alone`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedRetired(container, writer, count: 3, now: Date())
        try await writer.pruneRetiredFindings(keep: 200)
        let after = ModelContext(container)
        #expect(try after.fetch(FetchDescriptor<InsightLog>()).count == 3)
    }

    /// And curation calls it, or the bound exists and never applies.
    @Test func `curation prunes the tombstones it creates`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator.swift" }
        )
        #expect(
            SourceScan.code(source.text).contains("pruneRetiredFindings()"),
            "curation no longer bounds the retired findings it produces"
        )
    }
}
