import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What `analyze` does with a query that is nearly right.
///
/// It is the most flexible tool the agents have and sits in four of the six sessions. Its second
/// metric is required to resolve even for single-metric statistics — the guide asks the model to
/// "repeat the first metric" — and anything else returned the single sentence "Invalid query
/// parameters.", naming neither the offending argument nor the convention.
///
/// An agent that gets one argument wrong therefore learns nothing from the reply and cannot correct
/// itself; it reports that it could not run the check. Across three probes against the real model the
/// replication panel completed ZERO re-tests, and an uncorrectable dead end is the most likely
/// mechanism. It is also exactly the mistake made while investigating that: a hand-written probe
/// passed `secondaryMetric: ""` and spent a round concluding the tool was broken.
private extension AnalyzeTool.Arguments {
    /// Same query with a different primary metric — the only axis these near-miss cases vary.
    func with(metric: String) -> AnalyzeTool.Arguments {
        .init(
            metric: metric, secondaryMetric: secondaryMetric, statistic: statistic,
            fromDaysAgo: fromDaysAgo, toDaysAgo: toDaysAgo, dayFilter: dayFilter, lag: lag
        )
    }
}

struct AnalyzeToolForgivingTests {
    private var now: Date {
        Calendar.civil.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    private func tool() async throws -> AnalyzeTool {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(
            writer, metric: .restingHeartRate, value: 60, daysAgo: 1...120, jitter: 3, now: now
        )
        let provider = MetricStatsProvider(modelContainer: container)
        return try await AnalyzeTool(substrate: AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        ))
    }

    private func args(secondary: String) -> AnalyzeTool.Arguments {
        .init(
            metric: MetricKey.restingHeartRate.rawValue, secondaryMetric: secondary,
            statistic: AnalysisStatistic.mean.rawValue, fromDaysAgo: 90, toDaysAgo: 30,
            dayFilter: DayFilter.all.rawValue, lag: 0
        )
    }

    /// An omitted second metric means "single-metric query" — the intent the guide expresses as
    /// "repeat the first metric". Rejecting it wins nothing.
    @Test func `an omitted second metric is treated as a single-metric query`() async throws {
        let result = try await tool().call(arguments: args(secondary: ""))
        #expect(result.available, Comment(rawValue: result.description))
        #expect(result.value > 0)
    }

    /// And the documented form still works, unchanged.
    @Test func `repeating the first metric still works`() async throws {
        let result = try await tool().call(arguments: args(secondary: MetricKey.restingHeartRate.rawValue))
        #expect(result.available)
    }

    /// A genuinely unrecognised argument is named, so the agent can fix it rather than give up.
    @Test func `an unrecognised argument is named in the reply`() async throws {
        let result = try await tool().call(arguments: args(secondary: "heartRate2000"))
        #expect(!result.available)
        #expect(
            result.description.contains("secondaryMetric"),
            Comment(rawValue: "the reply does not say what was wrong: \(result.description)")
        )
        #expect(!result.description.contains("Invalid query parameters"))
    }

    /// A near-miss key is named back, because both observed failures were near misses.
    ///
    /// From analysts' own verdicts against the real model: "No data for Heart rate." and "No data
    /// exists for the metric \"restingHear\"". Neither is a guess at a different metric — one is the
    /// display name, the other a TRUNCATION of the right key. `metric` carries no `.anyOf` (the
    /// vocabulary would not fit the investigator's schema budget), so the model free-generates the
    /// string; the least the reply can do is say what it was close to.
    @Test func `a truncated key is matched to the one it was cut from`() async throws {
        let result = try await tool().call(arguments: args(secondary: "").with(metric: "restingHear"))
        #expect(!result.available)
        #expect(
            result.description.contains(MetricKey.restingHeartRate.rawValue),
            Comment(rawValue: result.description)
        )
    }

    @Test func `a display name is matched to its key`() async throws {
        let result = try await tool().call(arguments: args(secondary: "").with(metric: "Heart rate"))
        #expect(!result.available)
        #expect(result.description.lowercased().contains("heartrate"), Comment(rawValue: result.description))
    }

    /// And a genuinely unrelated string gets the generic pointer rather than a misleading guess.
    @Test func `an unrelated string is not matched to anything`() async throws {
        let result = try await tool().call(arguments: args(secondary: "").with(metric: "zzzz"))
        #expect(!result.available)
        #expect(!result.description.contains("Did you mean"), Comment(rawValue: result.description))
    }

    /// Several bad arguments are all named, not just the first — one round-trip, not four.
    @Test func `every unrecognised argument is named at once`() async throws {
        let result = try await tool().call(arguments: .init(
            metric: "nope", secondaryMetric: "", statistic: "average", fromDaysAgo: 90,
            toDaysAgo: 30, dayFilter: "sometimes", lag: 0
        ))
        #expect(!result.available)
        for expected in ["metric", "statistic", "dayFilter"] {
            #expect(
                result.description.contains(expected),
                Comment(rawValue: "\(expected) unnamed in: \(result.description)")
            )
        }
    }
}
