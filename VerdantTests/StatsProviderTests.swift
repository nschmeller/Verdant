import Foundation
import SwiftData
import Testing
@testable import Verdant

struct StatsProviderTests {
    private func makeStore() throws -> (StoreWriter, MetricStatsProvider) {
        let container = try TestSupport.inMemoryContainer()
        return (StoreWriter(modelContainer: container), MetricStatsProvider(modelContainer: container))
    }

    @Test func `computes recent vs baseline`() async throws {
        let now = Date()
        let (writer, stats) = try makeStore()
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)

        let stat = try await stats.stat(for: .stepCount, comparison: .recentVsBaseline, now: now)
        #expect(stat.confident)
        #expect(stat.recent > 11000 && stat.recent < 13000)
        #expect(stat.baseline > 7000 && stat.baseline < 9000)
        #expect(stat.pctChange > 30)
        #expect(stat.direction == .up)
    }

    @Test func `analysis reads are ALL-TIME — a decade-old rollup is analyzed, not floored away`(
    ) async throws {
        let now = Date()
        let (writer, stats) = try makeStore()
        // Older than the former 1,825-day cap: reintroducing ANY day floor on either read path
        // (dailySeries or the stat partition fetch) is exactly the regression this pins.
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 9000, daysAgo: 2000...2000, jitter: 0, now: now
        )
        let calendar = Calendar.civil
        let oldDay = try #require(calendar.date(
            byAdding: .day, value: -2000, to: calendar.startOfDay(for: now)
        ))

        let series = try await stats.dailySeries(now: now)
        let steps = try #require(series.first { $0.metric == .stepCount })
        #expect(steps.values[oldDay] == 9000)

        let allTime = try await stats.stat(for: .stepCount, comparison: .recentVsAllTime, now: now)
        #expect(allTime.baselineCount == 1) // the decade-old day IS the all-time baseline
    }

    @Test func `excludes partial current day from recent window`() async throws {
        let now = Date()
        let (writer, stats) = try makeStore()
        // A wildly high partial "today" must not pollute the recent average.
        try await TestSupport.seed(
            writer,
            metric: .stepCount,
            value: 100_000,
            daysAgo: 0...0,
            jitter: 0,
            now: now
        )
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)

        let stat = try await stats.stat(for: .stepCount, comparison: .recentVsBaseline, now: now)
        #expect(stat.recent < 20000) // today's 100k excluded
    }

    @Test func `week over week is confident with seven day windows`() async throws {
        // Regression for the bug where a flat 14-day baseline minimum made this comparison dead.
        let now = Date()
        let (writer, stats) = try makeStore()
        try await TestSupport.seed(writer, metric: .stepCount, value: 11000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...14, now: now)

        let stat = try await stats.stat(for: .stepCount, comparison: .weekOverWeek, now: now)
        #expect(stat.confident)
        #expect(stat.direction == .up)
    }

    @Test func `weekday vs weekend is confident across A quarter`() async throws {
        let now = Date()
        let (writer, stats) = try makeStore()
        // ~90-day window needs enough of both weekdays and weekends to be confident.
        try await TestSupport.seed(writer, metric: .stepCount, value: 9000, daysAgo: 1...80, now: now)

        let stat = try await stats.stat(for: .stepCount, comparison: .weekdayVsWeekend, now: now)
        #expect(stat.confident)
    }

    @Test func `zero variance baseline is not confident`() async throws {
        let now = Date()
        let (writer, stats) = try makeStore()
        try await TestSupport.seed(
            writer,
            metric: .stepCount,
            value: 12000,
            daysAgo: 1...7,
            jitter: 0,
            now: now
        )
        try await TestSupport.seed(
            writer,
            metric: .stepCount,
            value: 8000,
            daysAgo: 8...37,
            jitter: 0,
            now: now
        )

        let stat = try await stats.stat(for: .stepCount, comparison: .recentVsBaseline, now: now)
        #expect(!stat.confident) // baselineSD == 0
    }

    @Test func `insufficient recent data is not confident`() async throws {
        let now = Date()
        let (writer, stats) = try makeStore()
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...2, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)

        let stat = try await stats.stat(for: .stepCount, comparison: .recentVsBaseline, now: now)
        #expect(!stat.confident) // only 2 recent days
    }

    @Test func `zero baseline mean yields zero percent not na N`() {
        let stat = MetricStatsProvider.computeStat(
            metric: .stepCount, comparison: .recentVsBaseline, recent: [10, 12, 11], baseline: [0, 0, 0]
        )
        #expect(stat.pctChange == 0)
        #expect(!stat.confident) // zero spread
    }
}
