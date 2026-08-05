import Foundation
import SwiftData
import Testing
@testable import Verdant

struct PersistenceTests {
    private func makeWriter() throws -> StoreWriter {
        try StoreWriter(modelContainer: TestSupport.inMemoryContainer())
    }

    private func fact(_ metric: MetricKey) -> VerifiedFact {
        VerifiedFact(
            metric: metric, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: 70
        )
    }

    private func append(
        _ writer: StoreWriter,
        _ fact: VerifiedFact,
        now: Date
    ) async throws -> PersistentIdentifier? {
        try await writer.appendInsightIfNovel(
            fact: fact, phrasing: FindingPhrasing.phrasing(for: fact), jobRunID: UUID(), now: now
        )
    }

    @Test func `append if novel dedupes the same metric+comparison`() async throws {
        let writer = try makeWriter(); let now = Date()
        let first = try await append(writer, fact(.stepCount), now: now)
        #expect(first != nil)
        let dup = try await append(writer, fact(.stepCount), now: now)
        #expect(dup == nil)
    }

    @Test func `curation keeps only the highest-quality findings`() async throws {
        let writer = try makeWriter(); let now = Date()
        let metrics: [MetricKey] = [
            .stepCount,
            .activeEnergyBurned,
            .heartRateVariabilitySDNN,
            .vo2Max,
            .appleExerciseTime,
            .bodyMass
        ]
        for (index, metric) in metrics.enumerated() {
            let salience = (index + 1) * 10 // 10, 20, … 60
            let row = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline,
                recent: 100, baseline: 80, pctChange: 25, z: 5, n: 7,
                kind: .trend, direction: .up, magnitude: .large, salience: salience
            )
            _ = try await append(writer, row, now: now)
        }
        try await writer.curateFindings(maxActive: 3, now: now)
        let active = try await writer.snapshotsForSearch(now: now)
        #expect(active.count == 3)
        // The three lowest-salience metrics are tombstoned.
        let activeMetrics = Set(active.map(\.metric))
        #expect(activeMetrics.contains(MetricKey.bodyMass.rawValue)) // salience 60
        #expect(!activeMetrics.contains(MetricKey.stepCount.rawValue)) // salience 10
    }

    @Test func `curation caps how many findings one body system can hold`() async throws {
        let writer = try makeWriter(); let now = Date()
        // Four DISTINCT cardio metrics (so the one-per-metric rule keeps all four) with no embeddings
        // (so semantic dedup doesn't fire) and a generous budget — only the per-domain cap should bite.
        let cardio: [(MetricKey, Int)] = [
            (.restingHeartRate, 80),
            (.heartRateVariabilitySDNN, 70),
            (.vo2Max, 60),
            (.walkingHeartRateAverage, 50)
        ]
        for (metric, salience) in cardio {
            let row = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline,
                recent: 100, baseline: 80, pctChange: 25, z: 5, n: 7,
                kind: .trend, direction: .up, magnitude: .large, salience: salience
            )
            _ = try await append(writer, row, now: now)
        }
        try await writer.curateFindings(maxActive: 10, now: now)
        let active = try await writer.snapshotsForSearch(now: now)
        // Cap is 3 per body system, so the weakest cardio finding is tombstoned despite the slack budget.
        #expect(active.count == 3)
        #expect(!active.map(\.metric).contains(MetricKey.walkingHeartRateAverage.rawValue)) // salience 50
    }

    @Test func `curation drops a semantically duplicate finding on a different metric`() async throws {
        let writer = try makeWriter(); let now = Date()
        let phrasing = FindingPhrasing.Phrasing(summary: "x", oneTapTitle: "x")
        let vector = Embeddings.pack([1, 0, 0, 0]) // identical story embedding
        // Two different metrics, but the same story embedding → duplicates; only one may survive.
        _ = try await writer.appendInsightIfNovel(
            fact: fact(.stepCount), phrasing: phrasing, embedding: vector,
            jobRunID: UUID(), now: now
        )
        _ = try await writer.appendInsightIfNovel(
            fact: fact(.vo2Max), phrasing: phrasing, embedding: vector,
            jobRunID: UUID(), now: now
        )
        try await writer.curateFindings(maxActive: 10, now: now)
        #expect(try await writer.snapshotsForSearch(now: now).count == 1)
    }

    @Test func `curation shows one finding per metric, keeping the stronger across types`() async throws {
        let writer = try makeWriter(); let now = Date()
        // An insight and a correlation can BOTH be active on the same metric — they pass separate
        // novelty guards. The one-per-metric rule must still show only one finding about a given
        // metric, and pick by quality regardless of finding type or insertion order: here the
        // correlation (80) outranks the insight (50) on resting heart rate, so the insight is dropped
        // even though the budget has ample slack. A redundant pair about one metric is exactly the
        // low-signal feed the bound exists to prevent.
        let weakInsight = VerifiedFact(
            metric: .restingHeartRate, comparison: .recentVsBaseline,
            recent: 100, baseline: 80, pctChange: 25, z: 5, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: 50
        )
        _ = try await append(writer, weakInsight, now: now)
        let correlation = MetricCorrelation(
            metricA: .sleepDurationHours, metricB: .restingHeartRate, lag: 0,
            r: 0.6, partialR: 0.55, spearman: 0.58, n: 60, nEff: 42, pValue: 0.001,
            significant: true, activityControlled: true
        )
        _ = try await writer.appendCorrelationIfNovel(
            correlation, phrasing: FindingPhrasing.Phrasing(summary: "x", oneTapTitle: "x"),
            quality: 80, embedding: nil, jobRunID: UUID(), now: now
        )

        try await writer.curateFindings(maxActive: 10, now: now)

        #expect(try await writer.snapshotsForSearch(now: now).isEmpty) // the weaker insight is gone
        let pairKey = ["restingHeartRate", "sleepDurationHours"].sorted().joined(separator: "|")
        #expect(try await writer.hasRecentCorrelation(pairKey: pairKey, within: 14, now: now))
    }

    @Test func `tombstone hides insights`() async throws {
        let writer = try makeWriter(); let now = Date()
        _ = try await append(writer, fact(.stepCount), now: now)
        try await writer.tombstoneInsights(for: .stepCount)
        let stillThere = try await writer.hasRecentInsight(
            metric: .stepCount, comparison: .recentVsBaseline, within: 14, now: now
        )
        #expect(stillThere == false)
        #expect(try await writer.snapshotsForSearch(now: now).isEmpty)
    }

    @Test func `tombstoning a deleted metric invalidates findings of any age, not just recent ones`(
    ) async throws {
        let writer = try makeWriter(); let now = Date()
        // A finding created well beyond the former 14-day tombstone window. The feed shows findings of
        // any age, so when its source data is deleted in HealthKit it MUST still be invalidated — the
        // old recency bound left a stale card live on data the user had removed.
        let old = now.addingTimeInterval(-40 * 86400)
        _ = try await append(writer, fact(.stepCount), now: old)
        #expect(try await writer.hasRecentInsight(
            metric: .stepCount, comparison: .recentVsBaseline, within: 60, now: now
        ))
        try await writer.tombstoneInsights(for: .stepCount)
        #expect(try await !writer.hasRecentInsight(
            metric: .stepCount, comparison: .recentVsBaseline, within: 60, now: now
        ))
    }

    @Test func `tombstone hides correlations involving a deleted metric`() async throws {
        let writer = try makeWriter(); let now = Date()
        let correlation = MetricCorrelation(
            metricA: .sleepDurationHours, metricB: .restingHeartRate, lag: 0,
            r: 0.6, partialR: 0.55, spearman: 0.58, n: 60, nEff: 42, pValue: 0.001,
            significant: true, activityControlled: true
        )
        let phrasing = FindingPhrasing.Phrasing(summary: "x", oneTapTitle: "x")
        _ = try await writer.appendCorrelationIfNovel(
            correlation, phrasing: phrasing, quality: 80, embedding: nil, jobRunID: UUID(), now: now
        )
        // Deleting HealthKit samples for EITHER metric must invalidate the connection (it rests on both).
        try await writer.tombstoneCorrelations(for: .restingHeartRate)
        let pairKey = ["restingHeartRate", "sleepDurationHours"].sorted().joined(separator: "|")
        #expect(try await !writer.hasRecentCorrelation(pairKey: pairKey, within: 14, now: now))
    }

    @Test func `agent records and updates its run state each pass`() async throws {
        let writer = try makeWriter(); let now = Date()
        try await writer.recordRun(mode: .standard, findingCount: 3, now: now)
        let first = try await writer.agentStateForTest()
        #expect(first?.totalRuns == 1)
        #expect(first?.mode == "standard")
        #expect(first?.findingCount == 3)
        // A second pass updates the SAME singleton row (not a duplicate) and increments the count.
        let later = now.addingTimeInterval(3600)
        try await writer.recordRun(mode: .deep, findingCount: 7, now: later)
        let second = try await writer.agentStateForTest()
        #expect(second?.totalRuns == 2)
        #expect(second?.mode == "deep")
        #expect(second?.findingCount == 7)
        #expect(second?.at == later)
    }

    @Test func `delete all removes everything`() async throws {
        let writer = try makeWriter(); let now = Date()
        _ = try await append(writer, fact(.stepCount), now: now)
        try await writer.deleteAllInsights()
        #expect(try await writer.snapshotsForSearch(now: now).isEmpty)
    }

    @Test func `anchor round trips and overwrites`() async throws {
        let writer = try makeWriter()
        #expect(try await writer.loadAnchor(for: .stepCount) == nil)
        try await writer.saveAnchor(for: .stepCount, data: Data([1, 2, 3, 4]))
        #expect(try await writer.loadAnchor(for: .stepCount) == Data([1, 2, 3, 4]))
        try await writer.saveAnchor(for: .stepCount, data: Data([9, 9]))
        #expect(try await writer.loadAnchor(for: .stepCount) == Data([9, 9]))
    }

    @Test func `resetIngestCache clears rollups and anchors for a clean re-ingest`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let provider = MetricStatsProvider(modelContainer: container)
        let now = Date()
        // A populated derived cache: daily rollups + a sync anchor.
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 0...40, now: now)
        try await writer.saveAnchor(for: .stepCount, data: Data([1, 2, 3]))
        #expect(try await !provider.recentSeries(for: .stepCount, days: 30, now: now).isEmpty)
        #expect(try await writer.loadAnchor(for: .stepCount) != nil)
        // The civil-day migration relies on this clearing BOTH — rollups (so stale local-keyed rows
        // can't linger) AND the anchor (so the next ingest takes the full-backfill path, not incremental).
        try await writer.resetIngestCache()
        #expect(try await provider.recentSeries(for: .stepCount, days: 30, now: now).isEmpty)
        #expect(try await writer.loadAnchor(for: .stepCount) == nil)
    }

    @Test func `re-applying a day replaces its rollup rather than accumulating`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let provider = MetricStatsProvider(modelContainer: container)
        let now = Date()
        let day = try #require(Calendar.civil.date(
            byAdding: .day,
            value: -2,
            to: Calendar.civil.startOfDay(for: now)
        ))

        // A first ingest records the day...
        try await writer.applyRollups(
            upserts: [DayRollup(
                metric: .restingHeartRate,
                dayStart: day,
                values: DayValues(mean: 100, sum: 100, count: 1)
            )],
            deletions: []
        )
        // ...and a later authoritative recompute of the SAME day must REPLACE it — never sum to 300 or
        // leave a second row. The whole incremental-ingest design (recompute affected days in full)
        // rests on this: a `+=` slip here would silently inflate values on every observer wake.
        try await writer.applyRollups(
            upserts: [DayRollup(
                metric: .restingHeartRate,
                dayStart: day,
                values: DayValues(mean: 200, sum: 200, count: 1)
            )],
            deletions: []
        )

        let points = try await provider.recentSeries(for: .restingHeartRate, days: 30, now: now)
        #expect(points.count == 1) // one day, not a duplicate row
        #expect(points.first?.value == 200) // the replaced value, never 100 or 300
    }

    @Test func `recent insight kinds reflects stored`() async throws {
        let writer = try makeWriter(); let now = Date()
        _ = try await append(writer, fact(.stepCount), now: now)
        #expect(try await writer.recentInsightKinds(now: now).contains("trend"))
    }

    @Test func `concurrent appendIfNovel inserts exactly once`() async throws {
        let writer = try makeWriter(); let now = Date()
        let theFact = fact(.stepCount)
        let phrasing = FindingPhrasing.phrasing(for: theFact)
        // Many concurrent attempts for the same fact; the atomic novelty guard must admit only one.
        let ids = await withTaskGroup(of: PersistentIdentifier?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await writer.appendInsightIfNovel(
                        fact: theFact, phrasing: phrasing, jobRunID: UUID(), now: now
                    )
                }
            }
            var collected: [PersistentIdentifier?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(ids.compactMap(\.self).count == 1)
    }
}
