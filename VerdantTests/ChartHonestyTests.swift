import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What the charts plot must be the signal the numbers were computed on.
///
/// `MetricStatsProvider.recentSeries` feeds every sparkline and the dual-line correlation chart, and
/// it documents a specific promise: it excludes today's still-accumulating partial day, "matching
/// `dailySeries`", because the coefficient runs on the today-excluded substrate and the chart is
/// described to the user as showing the same signal.
///
/// Nothing tested that. Including today would end every sparkline on a partial value — a step count
/// mid-morning looks like a collapse — and would put a point on the correlation chart that the
/// coefficient never saw, under a caption saying otherwise. Neither throws, neither is malformed,
/// and both are wrong in exactly the way a person would believe.
struct ChartHonestyTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 11))!
    }

    private func seeded() async throws -> (MetricStatsProvider, Date) {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let today = calendar.startOfDay(for: now)
        var rollups: [DayRollup] = []
        for ago in 0..<20 {
            let day = try #require(calendar.date(byAdding: .day, value: -ago, to: today))
            // Today's row is deliberately a fraction of a normal day — the partial-day shape.
            let value = ago == 0 ? 900.0 : 9000.0
            rollups.append(DayRollup(
                metric: .stepCount, dayStart: day, values: DayValues(mean: value, sum: value, count: 1)
            ))
        }
        try await writer.applyRollups(upserts: rollups, deletions: [])
        return (MetricStatsProvider(modelContainer: container), today)
    }

    @Test func `a sparkline never ends on today's partial day`() async throws {
        let (provider, today) = try await seeded()
        let points = try await provider.recentSeries(for: .stepCount, days: 30, now: now)

        #expect(!points.isEmpty, "nothing to plot — the check would be vacuous")
        #expect(points.allSatisfy { $0.day < today }, "today is on the chart")
        // The partial value must not appear at all, at any position.
        #expect(points.allSatisfy { $0.value != 900 }, "the partial day's value reached the chart")
        #expect(points.last?.value == 9000)
    }

    /// The "same signal" promise, checked directly: the days the chart plots are exactly the days the
    /// statistics were computed over, for the same window.
    @Test func `the chart plots the same days the statistics ran on`() async throws {
        let (provider, _) = try await seeded()
        let points = try await provider.recentSeries(for: .stepCount, days: 30, now: now)
        let series = try await provider.dailySeries(now: now)
        let analysed = try #require(series.first { $0.metric == .stepCount }).values

        let plotted = Set(points.map(\.day))
        #expect(!plotted.isEmpty)
        #expect(
            plotted.isSubset(of: Set(analysed.keys)),
            "the chart plots days the statistics never saw"
        )
        // And the values agree, not just the days.
        for point in points {
            #expect(analysed[point.day] == point.value, "chart and statistics disagree on \(point.day)")
        }
    }
}
