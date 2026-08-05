import Foundation
import Testing
@testable import Verdant

/// Every tool here returns a well-formed answer. These tests ask the harder question: is it an
/// answer to the question that was ASKED?
///
/// The distinction is not academic — it is the shape of nearly every real defect this codebase has
/// produced. `unusualDays` paging was pinned against duplicates within a page, which an offset that
/// was silently ignored would satisfy perfectly, since every page would be page one. `correlate`
/// once ignored `dayFilter` entirely while still labelling its answer "weekends only". A finding
/// carried real numbers that answered a different question than its own prose. None of these throw,
/// none produce a malformed result, and none fail any test that checks only structure.
///
/// So: for each argument an agent can set, does changing it change the answer in the way the tool's
/// own description promises? An agent cannot tell the difference, and neither can a cap test.
struct ToolArgumentsHonouredTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// Twelve metrics, each with its wild day on a DIFFERENT day-offset, so a window centred on one
    /// offset must return a genuinely different set from a window centred on another.
    private func substrate() throws -> AnalysisSubstrate {
        let anchor = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        )
        let metrics = Array(MetricKey.allCases.prefix(12))
        let series = try metrics.enumerated().map { index, metric -> DailySeries in
            var values: [Date: Double] = [:]
            // Uneven history lengths AND uneven gappiness. The lengths alone were not enough: with
            // every day present, every metric has density 1.0, so the sparsest-first assertion below
            // held no matter how the rows were ordered. Reversing the sort was caught only once the
            // densities actually differed — the fixture, not the check, was the weak part.
            for ago in 0..<(60 + index * 25) {
                // Metric `index` drops every (index + 2)th day, so densities run from ~1/2 to ~12/13.
                guard !ago.isMultiple(of: index + 2) || index == 0 else { continue }
                let day = try #require(calendar.date(byAdding: .day, value: -ago, to: anchor))
                values[day] = 100 + Double(index) + Double((ago * (index + 3)) % 11)
            }
            // Each metric's spike sits `index * 3` days back — far enough apart to separate windows.
            let spike = try #require(
                calendar.date(byAdding: .day, value: -(2 + index * 3), to: anchor)
            )
            values[spike] = 9000
            return DailySeries(metric: metric, values: values)
        }
        return try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: series, now: now
        )
    }

    /// `eventWindow`'s whole purpose is "what else moved around THIS day". A centre that was ignored
    /// would return the same strongest days every time — plausible rows, answering nothing the agent
    /// asked, on the tool the instructions point at most insistently.
    @Test func `eventWindow centres on the day it was given`() async throws {
        let tool = try EventWindowTool(substrate: substrate())
        let early = try await tool.call(arguments: .init(daysAgo: 2, radius: 1, limit: 8)).days
        let late = try await tool.call(arguments: .init(daysAgo: 26, radius: 1, limit: 8)).days

        #expect(!early.isEmpty && !late.isEmpty, "both windows must find something to compare")
        // Every returned day must actually lie inside the requested window.
        #expect(early.allSatisfy { abs($0.daysAgo - 2) <= 1 }, "outside the window: \(early.map(\.daysAgo))")
        #expect(late.allSatisfy { abs($0.daysAgo - 26) <= 1 }, "outside the window: \(late.map(\.daysAgo))")
        #expect(Set(early.map(\.metric)).isDisjoint(with: Set(late.map(\.metric))))
    }

    /// Radius is the other half of the same promise: a wider window must be able to see more.
    @Test func `eventWindow widens with its radius`() async throws {
        let tool = try EventWindowTool(substrate: substrate())
        let narrow = try await tool.call(arguments: .init(daysAgo: 8, radius: 0, limit: 8)).days
        let wide = try await tool.call(arguments: .init(daysAgo: 8, radius: 7, limit: 8)).days
        #expect(wide.count > narrow.count, "radius 7 saw \(wide.count), radius 0 saw \(narrow.count)")
    }

    /// `unusualDays` takes a metric filter. Ignoring it would hand an agent asking about one metric
    /// a pool dominated by eleven others — and the rows would all be real.
    @Test func `unusualDays honours its metric filter`() async throws {
        let tool = try UnusualDaysTool(substrate: substrate())
        let all = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 0)).days
        #expect(Set(all.map(\.metric)).count > 1, "the fixture must span metrics")

        let target = try #require(all.first).metric
        let filtered = try await tool.call(
            arguments: .init(metric: target, limit: 6, offset: 0)
        ).days
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { $0.metric == target }, "filter leaked: \(filtered.map(\.metric))")
    }

    /// An unknown metric key must return nothing rather than silently falling back to everything —
    /// the difference between "no strange days for that metric" and a pool about other metrics
    /// entirely, which an agent would read as an answer about the one it named.
    @Test func `an unknown metric filter returns nothing, not everything`() async throws {
        let tool = try UnusualDaysTool(substrate: substrate())
        let days = try await tool.call(
            arguments: .init(metric: "notARealMetric", limit: 6, offset: 0)
        ).days
        #expect(days.isEmpty, "an unrecognised key returned \(days.count) rows")
    }

    /// Both tools promise an ORDER in their descriptions — "sparsest coverage first", "the strongest
    /// associations". The cap tests take a prefix of whatever order exists; if the sort were wrong,
    /// the cap would faithfully return the least interesting rows.
    @Test func `coverage really does return the sparsest first`() async throws {
        let rows = try await CoverageTool(substrate: substrate())
            .call(arguments: .init(limit: 6)).metrics
        #expect(rows.count > 1, "need at least two rows to have an order")
        let densities = rows.map { Double($0.observedDays) / Double(max(1, $0.spanDays)) }
        #expect(densities == densities.sorted(), "not sparsest-first: \(densities)")
    }

    @Test func `correlationScan really does return the strongest first`() async throws {
        let rows = try await CorrelationScanTool(substrate: substrate())
            .call(arguments: .init(limit: 6)).correlations
        #expect(rows.count > 1, "need at least two rows to have an order")
        let strengths = rows.map { abs($0.coefficient) }
        #expect(strengths == strengths.sorted(by: >), "not strongest-first: \(strengths)")
    }
}
