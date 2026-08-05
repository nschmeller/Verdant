import Foundation
import SwiftData
import Testing
@testable import Verdant

/// "Delete everything" is the strongest promise this app makes, and the one a person is least able
/// to check for themselves.
///
/// Two callers rely on it. Settings offers it to the user outright. And the civil-day migration uses
/// the same four writers to clear rows keyed to the OLD local-midnight boundary — rows that would
/// otherwise coexist with UTC-keyed ones and double-count every statistic.
///
/// The existing coverage was one insight, deleted, checked through `snapshotsForSearch` — a FILTERED
/// read that skips tombstoned rows. A retired finding left on disk would satisfy it while still
/// being the user's health data, unerased. `deleteAllCorrelations` had no test at all, and the
/// journal's own delete-all has already had a real bug of exactly this shape. So these count RAW
/// rows through a plain `ModelContext`, which is the only view that cannot hide a survivor.
struct DeleteEverythingTests {
    private func seeded() async throws -> (ModelContainer, StoreWriter) {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()

        // Active AND tombstoned findings of both kinds — the tombstoned ones are the point.
        for (index, metric) in [MetricKey.stepCount, .vo2Max].enumerated() {
            let fact = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline,
                recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
                kind: .trend, direction: .up, magnitude: .large, salience: 60 + index
            )
            _ = try await writer.appendInsightIfNovel(
                fact: fact, phrasing: FindingPhrasing.phrasing(for: fact), jobRunID: UUID(), now: now
            )
        }
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<InsightLog>()).prefix(1) {
            row.tombstoned = true
        }
        try context.save()

        // Journal entries of every kind, including the newest.
        for kind in ResearchJournalKind.allCases {
            try await writer.recordJournal(
                kind: kind, text: "something \(kind.rawValue)", reason: "r",
                jobRunID: UUID(), now: now
            )
        }

        // Ingest cache: rollups and anchors.
        try await TestSupport.seed(writer, metric: .stepCount, value: 9000, daysAgo: 1...5, now: now)
        try await writer.saveAnchor(for: .stepCount, data: Data([1, 2, 3]))
        return (container, writer)
    }

    /// Every store the two delete paths touch must come back genuinely empty — counted raw, with no
    /// predicate that could skip a survivor.
    @Test func `the delete paths leave no row of any kind behind`() async throws {
        let (container, writer) = try await seeded()
        let before = ModelContext(container)
        // The fixture must actually contain something, or "everything was deleted" is vacuous.
        #expect(try before.fetchCount(FetchDescriptor<InsightLog>()) == 2)
        #expect(try before.fetchCount(FetchDescriptor<ResearchJournalEntry>())
            == ResearchJournalKind.allCases.count)
        #expect(try before.fetchCount(FetchDescriptor<MetricRollup>()) > 0)
        #expect(try before.fetchCount(FetchDescriptor<SyncAnchor>()) > 0)

        try await writer.deleteAllInsights()
        try await writer.deleteAllCorrelations()
        try await writer.deleteJournal()
        try await writer.resetIngestCache()

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<InsightLog>()) == 0, "insights survived")
        #expect(try after.fetchCount(FetchDescriptor<CorrelationLog>()) == 0, "correlations survived")
        #expect(try after.fetchCount(FetchDescriptor<ResearchJournalEntry>()) == 0, "journal survived")
        #expect(try after.fetchCount(FetchDescriptor<MetricRollup>()) == 0, "rollups survived")
        #expect(try after.fetchCount(FetchDescriptor<SyncAnchor>()) == 0, "anchors survived")
    }

    /// A tombstoned finding is still the user's health data. The old check read through a filtered
    /// view that skips them, so one left on disk would have looked like success.
    @Test func `a retired finding is erased too, not merely hidden`() async throws {
        let (container, writer) = try await seeded()
        let before = ModelContext(container)
        #expect(
            try before.fetch(FetchDescriptor<InsightLog>()).contains { $0.tombstoned },
            "the fixture has no tombstoned row — this check would be vacuous"
        )

        try await writer.deleteAllInsights()

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<InsightLog>()) == 0)
    }

    /// Each step must be a safe no-op once already applied: the migration marks itself complete only
    /// on success, so a failure part-way through replays all four on the next launch.
    @Test func `running the delete paths twice is harmless`() async throws {
        let (container, writer) = try await seeded()
        for _ in 0..<2 {
            try await writer.deleteAllInsights()
            try await writer.deleteAllCorrelations()
            try await writer.deleteJournal()
            try await writer.resetIngestCache()
        }
        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<ResearchJournalEntry>()) == 0)
    }

    /// The other half of the promise, which is a NON-deletion: "Your Apple Health data is untouched
    /// — Verdant can rediscover findings over time."
    ///
    /// The user-facing delete clears findings, connections and the journal. It must NOT clear the
    /// ingest cache: those rollups are how the app rediscovers anything without re-reading years out
    /// of HealthKit, and the anchors are how it knows where it left off. Adding `resetIngestCache()`
    /// to this path would compile, satisfy every "everything is gone" test, and quietly turn a
    /// clean-slate tap into a multi-minute backfill — while the footer said the data was untouched.
    @MainActor
    @Test func `the user's delete keeps the ingest cache it promises to leave alone`() async throws {
        let (container, writer) = try await seeded()
        let model = AppModel(container: container)
        let before = ModelContext(container)
        let rollupsBefore = try before.fetchCount(FetchDescriptor<MetricRollup>())
        let anchorsBefore = try before.fetchCount(FetchDescriptor<SyncAnchor>())
        #expect(rollupsBefore > 0 && anchorsBefore > 0, "fixture has no cache to preserve")

        await model.deleteAllInsights()

        let after = ModelContext(container)
        // Findings and memory: gone.
        #expect(try after.fetchCount(FetchDescriptor<InsightLog>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<CorrelationLog>()) == 0)
        #expect(try after.fetchCount(FetchDescriptor<ResearchJournalEntry>()) == 0)
        // Health data cache: untouched, exactly as the footer says.
        #expect(try after.fetchCount(FetchDescriptor<MetricRollup>()) == rollupsBefore)
        #expect(try after.fetchCount(FetchDescriptor<SyncAnchor>()) == anchorsBefore)
        _ = writer
    }
}
