import Foundation
import Testing
@testable import Verdant

/// The `eventWindow` tool: "what ELSE moved around day X?" — the follow-up the investigator is
/// explicitly instructed to make and previously could not afford (one `analyze` call per metric,
/// ~72 of them, against a four-call budget). It is a view over the already-memoized every-data-point
/// sweep, so these pin the view's contract: the window bounds it, one row per metric, strongest
/// first, deterministically.
struct EventWindowToolTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// Three metrics over 120 quiet days. Two of them spike together 30 days ago — the event — and a
    /// third spikes on its own 80 days ago, far outside any window centred on the event.
    private func substrate() throws -> AnalysisSubstrate {
        // The sweep anchors on the last COMPLETE day, so `daysAgo` counts back from yesterday.
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        func day(_ ago: Int) -> Date {
            calendar.date(byAdding: .day, value: -ago, to: anchor)!
        }

        func series(_ metric: MetricKey, base: Double, spikes: [Int: Double]) -> DailySeries {
            var values: [Date: Double] = [:]
            for ago in 0..<120 {
                values[day(ago)] = base + Double((ago * 7) % 3)
            }
            for (ago, value) in spikes {
                values[day(ago)] = value
            }
            return DailySeries(metric: metric, values: values)
        }

        let container = try TestSupport.inMemoryContainer()
        return AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: container),
            series: [
                // Steps spikes hardest on the event day; energy spikes the day after it.
                series(.stepCount, base: 8000, spikes: [30: 40000]),
                series(.activeEnergyBurned, base: 500, spikes: [29: 3000]),
                series(.restingHeartRate, base: 55, spikes: [80: 200])
            ],
            now: now
        )
    }

    @Test func `the window gathers what moved near a day and excludes what didn't`() async throws {
        let tool = try EventWindowTool(substrate: substrate())
        let result = try await tool.call(arguments: .init(daysAgo: 30, radius: 2, limit: 8))

        let metrics = Set(result.days.map(\.metric))
        // Both halves of the event are caught, including the one a day off-centre…
        #expect(metrics.contains(MetricKey.stepCount.rawValue))
        #expect(metrics.contains(MetricKey.activeEnergyBurned.rawValue))
        // …and the unrelated spike 50 days away is not swept in.
        #expect(!metrics.contains(MetricKey.restingHeartRate.rawValue))
        // Strongest first, as a number the agent can weigh.
        #expect(result.days.first?.metric == MetricKey.stepCount.rawValue)
        #expect(abs(result.days[0].zScore) >= abs(result.days[1].zScore))
    }

    @Test func `a radius of zero sees only the day itself`() async throws {
        let tool = try EventWindowTool(substrate: substrate())
        let result = try await tool.call(arguments: .init(daysAgo: 30, radius: 0, limit: 8))

        #expect(result.days.map(\.metric) == [MetricKey.stepCount.rawValue])
        #expect(result.days.allSatisfy { $0.daysAgo == 30 })
    }

    /// One row per metric: a metric having a rough week must not crowd out the cross-signal picture
    /// the agent asked for.
    @Test func `a metric strange on several days in the window appears once, at its strongest`() async throws {
        let anchor = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        var values: [Date: Double] = [:]
        for ago in 0..<120 {
            try values[#require(calendar.date(byAdding: .day, value: -ago, to: anchor))] = 8000 +
                Double((ago * 7) % 3)
        }
        for (ago, value) in [29: 30000.0, 30: 45000.0, 31: 25000.0] {
            try values[#require(calendar.date(byAdding: .day, value: -ago, to: anchor))] = value
        }
        let container = try TestSupport.inMemoryContainer()
        let substrate = AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: container),
            series: [DailySeries(metric: .stepCount, values: values)],
            now: now
        )
        let result = try await EventWindowTool(substrate: substrate)
            .call(arguments: .init(daysAgo: 30, radius: 3, limit: 8))

        #expect(result.days.count == 1)
        #expect(result.days.first?.daysAgo == 30) // the strongest of the three, not the first seen
    }
}
