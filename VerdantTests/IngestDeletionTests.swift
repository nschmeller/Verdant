import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The ingest path is where wrong data ENTERS. A stale rollup, a mis-advanced anchor or a missed
/// deletion sits upstream of every statistic, every finding and every card, and no downstream
/// safeguard can detect it — the numbers are real, they just describe data that is no longer there.
///
/// It was also the least testable code in the app: `Ingestor` held a concrete `HealthStore` and
/// HealthKit cannot be faked. `HealthReading` is the seam that makes these possible.
///
/// The property under test is the one `dailyValuesRange`'s doc calls an INVARIANT and that was
/// previously enforceable only as a tripwire on its call sites: when the user deletes a sample from
/// Apple Health, Verdant's rollup for that day must GO, not linger.
/// A transient HealthKit error, for the mid-recompute failure case.
private struct TransientHealthFailure: Error {}

struct IngestDeletionTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// A fake Health store: it holds whatever days the test says it holds, and reports a scan that
    /// names the affected days — exactly what HealthKit's anchored query gives the ingestor.
    private final class FakeHealth: HealthReading, @unchecked Sendable {
        var days: [Date: Double] = [:]
        var affected: [Date] = []
        var hadDeletions = false
        var newAnchor: Data? = Data([1])
        private(set) var rangeCalls = 0
        /// When set, `dailyValues` throws — a transient HealthKit error mid-recompute.
        var failPerDayReads = false

        func anchoredScan(for _: MetricKey, anchor _: Data?) async throws -> AnchoredScan {
            AnchoredScan(
                newAnchor: newAnchor, affectedDays: affected,
                hadDeletions: hadDeletions, addedCount: days.count
            )
        }

        func dailyValues(for metric: MetricKey, dayStart: Date) async throws -> DayValues? {
            if failPerDayReads { throw TransientHealthFailure() }
            guard let value = days[dayStart] else { return nil }
            _ = metric
            return DayValues(mean: value, sum: value, count: 1)
        }

        func dailyValuesRange(
            for metric: MetricKey, from start: Date, to end: Date
        ) async throws -> [DayRollup] {
            rangeCalls += 1
            return days.filter { $0.key >= start && $0.key < end }
                .sorted { $0.key < $1.key }
                .map { DayRollup(
                    metric: metric, dayStart: $0.key,
                    values: DayValues(mean: $0.value, sum: $0.value, count: 1)
                ) }
        }

        func earliestSampleDate(for _: MetricKey) async throws -> Date? {
            days.keys.min()
        }
    }

    /// The whole point: a day the user deleted from Health must lose its rollup.
    @Test func `a deleted sample's rollup is removed, not left behind`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        let dayA = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let dayB = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        health.days = [dayA: 9000, dayB: 8000]

        // First ingest establishes both rollups and saves an anchor.
        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = try await ingestor.ingest(metric: .stepCount, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        #expect(try await provider.dailySeries(now: now).first?.values.count == 2)

        // The user deletes dayA in Apple Health. HealthKit reports a deletion; the day is gone.
        health.days = [dayB: 8000]
        health.hadDeletions = true
        health.affected = [dayA]
        _ = try await ingestor.ingest(metric: .stepCount, now: now)

        let after = try #require(try await provider.dailySeries(now: now).first).values
        #expect(after[dayA] == nil, "the deleted day's rollup survived the recompute")
        #expect(after[dayB] == 8000, "the surviving day was lost")
    }

    /// And the first ingest really does take the one-query range path — the reason that API exists,
    /// and the case where it is safe because no stale rollup can pre-exist.
    @Test func `the first ingest uses the range query`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        health.days = try [#require(calendar.date(byAdding: .day, value: -5, to: today)): 100]

        _ = try await Ingestor(
            healthStore: health, writer: StoreWriter(modelContainer: container)
        ).ingest(metric: .stepCount, now: now)

        #expect(health.rangeCalls == 1, "first ingest made \(health.rangeCalls) range queries")
    }

    /// A deletion-triggered recompute must NOT reach for the range query, because it cannot express
    /// a removal. This is the invariant stated on `dailyValuesRange`, now checked by behaviour
    /// rather than by counting call sites.
    @Test func `the deletion recompute never uses the deletion-blind range query`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        let day = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        health.days = [day: 700]

        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = try await ingestor.ingest(metric: .stepCount, now: now) // first ingest: range is fine
        let afterFirst = health.rangeCalls

        health.days = [:]
        health.hadDeletions = true
        health.affected = [day]
        _ = try await ingestor.ingest(metric: .stepCount, now: now)

        #expect(
            health.rangeCalls == afterFirst,
            "the recompute used the deletion-blind range query — a deleted day would linger"
        )
    }

    /// Deleting data in Apple Health must retire the findings built on it.
    ///
    /// `Ingestor` tombstones a metric's insights and correlations whenever HealthKit reports a
    /// deletion, and the reasoning is in the code: findings derived from removed samples no longer
    /// hold. This is the visible half of the delete promise — a user who removes a bad reading and
    /// then sees Verdant still asserting a conclusion drawn from it has been told something false.
    ///
    /// Untestable before `HealthReading` existed, because it needs a HealthKit deletion to occur.
    @Test func `a deletion retires the findings that rest on that metric`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        let day = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        health.days = [day: 9000]

        let fact = VerifiedFact(
            metric: .stepCount, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: 80
        )
        _ = try await writer.appendInsightIfNovel(
            fact: fact, phrasing: FindingPhrasing.phrasing(for: fact), jobRunID: UUID(), now: now
        )
        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = try await ingestor.ingest(metric: .stepCount, now: now)
        #expect(
            try await !writer.snapshotsForSearch(now: now).isEmpty,
            "the finding must be live before the deletion, or the check is vacuous"
        )

        health.days = [:]
        health.hadDeletions = true
        health.affected = [day]
        _ = try await ingestor.ingest(metric: .stepCount, now: now)

        // Retired, not erased: the row stays, tombstoned, exactly like an audit retirement.
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<InsightLog>())
        #expect(rows.count == 1, "the finding should still exist, tombstoned")
        let retired = rows.allSatisfy(\.tombstoned)
        #expect(retired, "a finding built on deleted data is still being surfaced")
    }

    /// An incremental pass recomputes only the recent window. Re-reading the whole history on every
    /// observer wake would be slow enough to matter on a phone, and the window is what keeps a wake
    /// cheap — but nothing checked that older days are actually left alone.
    @Test func `an incremental pass leaves old days untouched`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        let ancient = try #require(calendar.date(byAdding: .day, value: -300, to: today))
        let recent = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        health.days = [ancient: 1000, recent: 2000]

        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = try await ingestor.ingest(metric: .stepCount, now: now) // first ingest: both land

        // The old day vanishes from HealthKit, but the incremental window does not reach it, so its
        // rollup must survive — the window is a performance boundary, not a licence to lose data.
        health.days = [recent: 2000]
        health.hadDeletions = true
        health.affected = [recent]
        _ = try await ingestor.ingest(metric: .stepCount, now: now)

        let provider = MetricStatsProvider(modelContainer: container)
        let values = try #require(try await provider.dailySeries(now: now).first).values
        #expect(values[ancient] == 1000, "an incremental pass reached outside its window")
        #expect(values[recent] == 2000)
    }

    /// A pass that fails mid-recompute must NOT advance the anchor.
    ///
    /// The anchor is the only carrier of the deletion signal: HealthKit will not re-report a
    /// deletion once its anchor has been consumed. So the code deliberately does not swallow errors
    /// here — if the recompute or the invalidation fails, the pass throws and the anchor stays put,
    /// and the deletion replays next time. Advance it anyway and a single transient error strands
    /// stale findings on deleted data FOREVER, which is the one failure in this file that cannot be
    /// recovered from by trying again.
    @Test func `a failed pass leaves the anchor alone so the deletion replays`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        let day = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        health.days = [day: 9000]

        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = try await ingestor.ingest(metric: .stepCount, now: now)
        let anchorAfterFirst = try await writer.loadAnchor(for: .stepCount)
        #expect(anchorAfterFirst != nil, "the first pass should have saved an anchor")

        // A deletion arrives, but the per-day recompute fails partway through.
        health.days = [:]
        health.hadDeletions = true
        health.affected = [day]
        health.failPerDayReads = true
        health.newAnchor = Data([9, 9, 9]) // what would be saved if the pass wrongly continued

        await #expect(throws: (any Error).self) {
            _ = try await ingestor.ingest(metric: .stepCount, now: now)
        }

        let anchorAfterFailure = try await writer.loadAnchor(for: .stepCount)
        #expect(
            anchorAfterFailure == anchorAfterFirst,
            "the anchor advanced through a failed pass — the deletion can never replay"
        )
    }

    /// A metric HealthKit holds nothing for must still save its anchor, or every later pass retakes
    /// the expensive first-ingest path for a metric that will never have data.
    @Test func `a metric with no samples still records an anchor`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth() // no days at all

        _ = try await Ingestor(healthStore: health, writer: writer)
            .ingest(metric: .stepCount, now: now)

        #expect(
            try await writer.loadAnchor(for: .stepCount) != nil,
            "no anchor saved — every future pass will redo the full backfill probe"
        )
    }

    /// History deepening actually recovers older days — and only older ones.
    ///
    /// This matters more than it used to. The app's newest detector, `SeasonalityScan`, needs TWO
    /// YEARS before it says anything, and deepening is the only thing that reaches back that far: a
    /// first ingest on a capped-era install stops short, and the incremental window covers 40 days.
    /// If deepening silently no-opped, the annual-rhythm finding would never fire for anyone and
    /// nothing would report an error — the app would simply be quieter than it should be.
    @Test func `deepening recovers older history and marks the metric done`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        let old = try #require(calendar.date(byAdding: .day, value: -900, to: today))
        let recent = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        // HealthKit holds both, but only the recent day has been ingested so far.
        health.days = [old: 500, recent: 2000]

        // Simulate a capped first ingest: the recent rollup and an anchor exist, the old day does not.
        try await writer.applyRollups(
            upserts: [DayRollup(
                metric: .stepCount, dayStart: recent,
                values: DayValues(mean: 2000, sum: 2000, count: 1)
            )],
            deletions: []
        )
        try await writer.saveAnchor(for: .stepCount, data: Data([1]))

        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = await ingestor.deepenHistory(now: now)

        let provider = MetricStatsProvider(modelContainer: container)
        let values = try #require(try await provider.dailySeries(now: now).first).values
        #expect(values[old] == 500, "deepening did not recover the older day")
        #expect(values[recent] == 2000, "deepening disturbed an existing rollup")
        #expect(
            try await writer.hasDeepenedHistory(for: .stepCount),
            "the metric was not marked deepened — every later pass will probe again"
        )
    }

    /// And a second pass skips a metric already deepened, so the expensive probe runs once.
    @Test func `deepening does not run twice for the same metric`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let health = FakeHealth()
        let today = calendar.startOfDay(for: now)
        health.days = try [#require(calendar.date(byAdding: .day, value: -900, to: today)): 500]
        try await writer.saveAnchor(for: .stepCount, data: Data([1]))

        let ingestor = Ingestor(healthStore: health, writer: writer)
        _ = await ingestor.deepenHistory(now: now)
        let callsAfterFirst = health.rangeCalls
        #expect(callsAfterFirst > 0, "the first deepen never queried — the check would be vacuous")

        _ = await ingestor.deepenHistory(now: now)
        #expect(
            health.rangeCalls == callsAfterFirst,
            "deepening re-probed an already-deepened metric"
        )
    }
}
