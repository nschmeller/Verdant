import Foundation
import SwiftData
import Testing
@testable import Verdant

struct StatsAndVerifierTests {
    /// In-memory store seeded with a clear step-count jump: ~8,000/day baseline, ~12,000/day recent.
    private func seededStore(now: Date) async throws -> (StoreWriter, MetricStatsProvider) {
        let container = try AppContainer.makeContainer(inMemory: true)
        let writer = StoreWriter(modelContainer: container)
        let stats = MetricStatsProvider(modelContainer: container)
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)

        var rollups: [DayRollup] = []
        for k in 7...36 { // baseline (prior 30 days), small variance
            let day = calendar.date(byAdding: .day, value: -k, to: today)!
            let value = 8000 + Double((k % 5) * 80)
            rollups.append(DayRollup(
                metric: .stepCount,
                dayStart: day,
                values: DayValues(mean: value, sum: value, count: 1)
            ))
        }
        for k in 0...6 { // recent week, clearly higher
            let day = calendar.date(byAdding: .day, value: -k, to: today)!
            rollups.append(DayRollup(
                metric: .stepCount,
                dayStart: day,
                values: DayValues(mean: 12000, sum: 12000, count: 1)
            ))
        }
        try await writer.applyRollups(upserts: rollups, deletions: [])
        return (writer, stats)
    }

    @Test func `computes recent vs baseline`() async throws {
        let now = Date()
        let (_, stats) = try await seededStore(now: now)
        let stat = try await stats.stat(for: .stepCount, comparison: .recentVsBaseline, now: now)
        #expect(stat.confident)
        #expect(stat.recent > 11000)
        #expect(stat.baseline > 7800 && stat.baseline < 8800)
        #expect(stat.pctChange > 30)
        #expect(stat.direction == .up)
    }

    // The old Verifier (which re-derived the model's *claimed* numbers) is gone: in the inverted design
    // the agent never states numbers — a `ProposedFinding` carries no figures — so the shown numbers
    // come from `MetricStatsProvider` at persist time by construction. Anti-hallucination is now
    // structural, not a re-derivation gate. `computes recent vs baseline` above pins the single source.

    @Test func `novelty guard detects duplicates`() async throws {
        let now = Date()
        let (writer, _) = try await seededStore(now: now)
        let fact = VerifiedFact(
            metric: .stepCount, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: 60
        )
        let phrasing = FindingPhrasing.phrasing(for: fact)
        #expect(try await writer.hasRecentInsight(
            metric: .stepCount,
            comparison: .recentVsBaseline,
            within: 14,
            now: now
        ) == false)
        _ = try await writer.appendInsight(fact: fact, phrasing: phrasing, jobRunID: UUID(), now: now)
        #expect(try await writer.hasRecentInsight(
            metric: .stepCount,
            comparison: .recentVsBaseline,
            within: 14,
            now: now
        ) == true)
    }

    @Test func `every comparison partitions into disjoint recent and baseline windows`() throws {
        // A recent day that also lands in the baseline contaminates the comparison — the change gets
        // diluted by its own recent values, silently weakening every finding on that window. An
        // off-by-one in a window edge is exactly how that creeps in. Give each of 500 days a unique
        // value, so a value shared between the two sides means a day landed in both.
        let now = Date()
        let calendar = Calendar.civil
        let anchor = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let values = (0...499).map { k in
            (day: calendar.date(byAdding: .day, value: -k, to: anchor)!, value: Double(k))
        }
        for comparison in ComparisonKey.allCases {
            let (recent, baseline) = MetricStatsProvider.partition(
                values: values, comparison: comparison, now: now
            )
            let shared = Set(recent).intersection(Set(baseline))
            #expect(shared.isEmpty, "\(comparison): a day fell in both windows (\(shared.sorted()))")
            #expect(!recent.isEmpty && !baseline.isEmpty, "\(comparison): a window came back empty")
        }
    }

    @Test func `sample standard deviation uses Bessel's correction and guards tiny samples`() {
        // n−1 in the denominator: SD([2,4,6]) = √((4+0+4)/2) = 2, not the population √(8/3) ≈ 1.63.
        // The whole materiality pipeline is scaled by this SD (z = effect size in baseline SDs), so a
        // slip to ÷n would silently shift every z-score and what surfaces.
        #expect(abs(MetricStatsProvider.sampleStandardDeviation([2, 4, 6]) - 2) < 1e-9)
        // Fewer than two points, or a flat series, has no spread — return 0, never a NaN or 1/0.
        #expect(MetricStatsProvider.sampleStandardDeviation([5]) == 0)
        #expect(MetricStatsProvider.sampleStandardDeviation([]) == 0)
        #expect(MetricStatsProvider.sampleStandardDeviation([3, 3, 3]) == 0)
    }

    @Test func `a flat baseline is never confident and never divides by zero`() {
        // A baseline with no variation can't establish how far is "far" — z would be 0/0. Even with
        // ample samples on both sides, the stat must come back not-confident (so no finding surfaces and
        // Q&A says it can't compare yet) and z must be a guarded 0, never NaN/inf.
        let stat = MetricStatsProvider.computeStat(
            metric: .restingHeartRate, comparison: .recentVsBaseline,
            recent: (0..<30).map { 70 + Double($0 % 3) },
            baseline: Array(repeating: 60.0, count: 30)
        )
        #expect(!stat.confident)
        #expect(stat.z == 0)
    }

    @Test func `the digest spans multiple time horizons, not just the recent week`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let stats = MetricStatsProvider(modelContainer: container)
        let now = Date()
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        // ~460 days of varying daily data so all three horizons (recent, year-over-year, all-time) are
        // confident for one metric. The digest is the only whole-picture view discovery ever sees; if
        // build() collapsed to the recent window it would reintroduce exactly the recency bias the
        // multi-horizon design exists to defeat — and roundRobin's own test wouldn't catch that.
        var rollups: [DayRollup] = []
        for k in 0..<460 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            let value = 8000 + Double((k % 11) * 120) // varies → nonzero SD → confident
            rollups.append(DayRollup(
                metric: .stepCount,
                dayStart: day,
                values: DayValues(mean: value, sum: value, count: 1)
            ))
        }
        try await writer.applyRollups(upserts: rollups, deletions: [])

        let digest = await HealthDigestBuilder(provider: stats, writer: writer).build(now: now)
        let horizons = Set(digest.entries.map(\.comparison))
        #expect(horizons.count >= 2, "digest collapsed to a single horizon (recency bias): \(horizons)")
        #expect(horizons.contains(.yearOverYear) || horizons.contains(.recentVsAllTime))
    }

    @Test func `the detector substrate excludes today's partial day`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let stats = MetricStatsProvider(modelContainer: container)
        let now = Date()
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        // Today plus the nine prior complete days. Today's rollup is still accumulating, so including it
        // would let a partial day fake a record/regime step or distort a latest-window mean/SD.
        var rollups: [DayRollup] = []
        for k in 0..<10 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            rollups.append(DayRollup(
                metric: .stepCount,
                dayStart: day,
                values: DayValues(mean: 8000, sum: 8000, count: 1)
            ))
        }
        try await writer.applyRollups(upserts: rollups, deletions: [])

        let steps = try await stats.dailySeries(now: now).first { $0.metric == .stepCount }
        #expect(steps?.values[today] == nil) // today's partial day is not in the detector substrate
        #expect(steps?.values.count == 9) // only the nine complete prior days
    }
}
