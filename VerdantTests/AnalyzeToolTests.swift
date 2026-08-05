import Foundation
import Testing
@testable import Verdant

/// `analyze` is the agent's most powerful tool — it defines its OWN view of the data rather than
/// picking from a menu — and it was the only one with no direct test. The engine beneath it is
/// covered thoroughly; the tool's own boundary is not the same thing.
///
/// That boundary is where model-written strings become a query: four raw strings resolved against
/// closed vocabularies, plus two window bounds and a lag. Resolving a name the registry does not
/// know, or accepting a nonsense window, would hand the agent a confident number about the wrong
/// thing — and every number this app shows is meant to be one the engine actually computed.
struct AnalyzeToolTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    private func substrate() throws -> AnalysisSubstrate {
        let anchor = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        )
        let series = try [MetricKey.stepCount, .restingHeartRate].map { metric -> DailySeries in
            var values: [Date: Double] = [:]
            for ago in 0..<120 {
                let day = try #require(calendar.date(byAdding: .day, value: -ago, to: anchor))
                values[day] = metric == .stepCount ? 9000 + Double(ago % 7) * 100 : 60 + Double(ago % 5)
            }
            return DailySeries(metric: metric, values: values)
        }
        return try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: series, now: now
        )
    }

    private func tool() throws -> AnalyzeTool {
        try AnalyzeTool(substrate: substrate())
    }

    /// A metric name the registry does not know must be REFUSED, not coerced. The closed vocabulary
    /// is the boundary that lets the agent name things without being able to invent them; a silent
    /// fallback to some default metric would return a real number about the wrong signal.
    @Test func `an unknown metric is refused rather than resolved to something else`() async throws {
        let result = try await tool().call(arguments: .init(
            metric: "notARealMetric", secondaryMetric: MetricKey.stepCount.rawValue,
            statistic: "mean", fromDaysAgo: 30, toDaysAgo: 0, dayFilter: "all", lag: 0
        ))
        #expect(!result.available)
        #expect(result.value == 0, "an unavailable result must carry no value")
        #expect(!result.description.isEmpty, "a refusal must say why")
    }

    /// The same for the other three closed vocabularies, each of which the model supplies as a raw
    /// string.
    @Test func `unknown statistics and day filters are refused too`() async throws {
        let bogusStatistic = try await tool().call(arguments: .init(
            metric: MetricKey.stepCount.rawValue, secondaryMetric: MetricKey.stepCount.rawValue,
            statistic: "geometricMean", fromDaysAgo: 30, toDaysAgo: 0, dayFilter: "all", lag: 0
        ))
        #expect(!bogusStatistic.available)

        let bogusFilter = try await tool().call(arguments: .init(
            metric: MetricKey.stepCount.rawValue, secondaryMetric: MetricKey.stepCount.rawValue,
            statistic: "mean", fromDaysAgo: 30, toDaysAgo: 0, dayFilter: "fullMoons", lag: 0
        ))
        #expect(!bogusFilter.available)
    }

    /// A well-formed query must actually answer — otherwise the refusals above would pass trivially.
    @Test func `a valid query returns a real, finite number and names its window`() async throws {
        let result = try await tool().call(arguments: .init(
            metric: MetricKey.stepCount.rawValue, secondaryMetric: MetricKey.stepCount.rawValue,
            statistic: "mean", fromDaysAgo: 30, toDaysAgo: 0, dayFilter: "all", lag: 0
        ))
        #expect(result.available)
        #expect(result.value.isFinite && result.value > 8000)
        #expect(result.sampleCount > 0)
        #expect(result.description.contains("days 0–30 ago"), "\(result.description)")
    }

    /// The tool rounds at its boundary, so the agent never reads a number with more precision than
    /// the app is willing to defend — and never a non-finite one.
    @Test func `every returned value is rounded and finite, whatever is asked`() async throws {
        let tool = try tool()
        for statistic in AnalysisStatistic.allCases {
            for (from, to) in [(365, 0), (30, 0), (1, 0), (0, 0), (7, 7)] {
                let result = try await tool.call(arguments: .init(
                    metric: MetricKey.stepCount.rawValue,
                    secondaryMetric: MetricKey.restingHeartRate.rawValue,
                    statistic: statistic.rawValue, fromDaysAgo: from, toDaysAgo: to,
                    dayFilter: "all", lag: 0
                ))
                #expect(result.value.isFinite, "\(statistic.rawValue)/\(to)-\(from)")
                #expect(result.value == result.value.toolRounded, "unrounded \(statistic.rawValue)")
            }
        }
    }

    /// A reversed window is a plausible thing for a model to emit, and must not silently mean
    /// "nothing" — the engine orders the bounds itself.
    @Test func `a reversed window is read the way it was obviously meant`() async throws {
        let forward = try await tool().call(arguments: .init(
            metric: MetricKey.stepCount.rawValue, secondaryMetric: MetricKey.stepCount.rawValue,
            statistic: "mean", fromDaysAgo: 30, toDaysAgo: 0, dayFilter: "all", lag: 0
        ))
        let reversed = try await tool().call(arguments: .init(
            metric: MetricKey.stepCount.rawValue, secondaryMetric: MetricKey.stepCount.rawValue,
            statistic: "mean", fromDaysAgo: 0, toDaysAgo: 30, dayFilter: "all", lag: 0
        ))
        #expect(reversed.available)
        #expect(reversed.value == forward.value, "the same window read two ways gave two answers")
    }
}
