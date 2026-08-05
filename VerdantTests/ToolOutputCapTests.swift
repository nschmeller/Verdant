import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Every stat tool caps how many rows it returns, and those caps are load-bearing rather than
/// cosmetic: the on-device window is 4,096 tokens shared across instructions, tool schemas, the
/// transcript and the output, and ARCHITECTURE records real field overflows ("singleExtend errors")
/// traced to exactly this — a maxed-out `patternScan` was ~1,400 tokens on its own. Blow a cap and
/// the failure is not a wrong number, it is an investigator dying mid-exploration.
///
/// The token harness pins each role's SCHEMA size. Nothing pinned the OUTPUT sizes, so these do —
/// and they push the arguments a small model might actually produce, including values the `.range`
/// guides say are impossible, because a guide is a constraint on generation and not a promise about
/// what reaches the function.
struct ToolOutputCapTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// A deliberately rich substrate: twelve metrics with 200 days of varied history, so every
    /// detector has far more to say than any cap allows and truncation is actually exercised.
    private func richSubstrate() throws -> AnalysisSubstrate {
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let metrics = Array(MetricKey.allCases.prefix(12))
        let series = metrics.enumerated().map { index, metric -> DailySeries in
            var values: [Date: Double] = [:]
            for ago in 0..<200 {
                let base = ago < 40 ? 100.0 + Double(index) * 7 : 60.0 + Double(index) * 3
                values[calendar.date(byAdding: .day, value: -ago, to: anchor)!] =
                    base + Double((ago * (index + 3)) % 17)
            }
            // A wild day per metric, so the unusual-days pool is deep.
            values[calendar.date(byAdding: .day, value: -(index + 2), to: anchor)!] = 5000
            return DailySeries(metric: metric, values: values)
        }
        return try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: series,
            now: now
        )
    }

    /// Limits a guided model should never emit, but which the function must survive: below the
    /// range, above it, and absurd.
    private let hostileLimits = [-99, -1, 0, 1, 3, 6, 7, 50, 9999, Int.max]

    @Test func `correlationScan never returns more rows than its cap`() async throws {
        let tool = try CorrelationScanTool(substrate: richSubstrate())
        for limit in hostileLimits {
            let result = try await tool.call(arguments: .init(limit: limit))
            #expect(
                result.correlations.count <= CorrelationScanTool.maxRows,
                "limit \(limit) returned \(result.correlations.count)"
            )
            #expect(!result.correlations.isEmpty, "limit \(limit) returned nothing at all")
        }
    }

    @Test func `patternScan never returns more of each kind than its cap`() async throws {
        let tool = try PatternScanTool(substrate: richSubstrate())
        for perKind in hostileLimits {
            let result = try await tool.call(arguments: .init(perKind: perKind))
            for kind in PatternKind.allRawValues {
                let count = result.patterns.count { $0.kind == kind }
                #expect(
                    count <= PatternScanTool.maxPerKind,
                    "perKind \(perKind) returned \(count) of \(kind)"
                )
            }
            // A TOTAL cap, not per-kind × kinds: adding a fourth detector must buy diversity
            // inside the same token budget rather than a third more output.
            #expect(
                result.patterns.count <= PatternScanTool.maxTotal,
                "perKind \(perKind) returned \(result.patterns.count)"
            )
        }
    }

    @Test func `coverage and unusualDays never exceed their row caps`() async throws {
        let substrate = try richSubstrate()
        let coverage = CoverageTool(substrate: substrate)
        let unusual = UnusualDaysTool(substrate: substrate)
        for limit in hostileLimits {
            #expect(try await coverage.call(arguments: .init(limit: limit)).metrics.count
                <= CoverageTool.maxMetrics)
            #expect(try await unusual.call(arguments: .init(metric: "all", limit: limit, offset: 0)).days
                .count <= UnusualDaysTool.maxDays)
        }
    }

    @Test func `eventWindow never exceeds its row cap, whatever radius or limit it is given`() async throws {
        let tool = try EventWindowTool(substrate: richSubstrate())
        for limit in hostileLimits {
            for radius in [-5, 0, 7, 400] {
                let result = try await tool.call(
                    arguments: .init(daysAgo: 5, radius: radius, limit: limit)
                )
                #expect(
                    result.days.count <= EventWindowTool.maxMetrics,
                    "limit \(limit)/radius \(radius): \(result.days.count)"
                )
                // One row per metric — a single metric having a rough week must not fill the answer.
                #expect(Set(result.days.map(\.metric)).count == result.days.count)
            }
        }
    }

    /// A negative or zero offset must not crash the pager or silently re-serve page one forever.
    @Test func `unusualDays paging is bounded and never duplicates within a page`() async throws {
        let tool = try UnusualDaysTool(substrate: richSubstrate())
        for offset in [-10, 0, 3, 9999] {
            let page = try await tool.call(
                arguments: .init(metric: "all", limit: 6, offset: offset)
            )
            #expect(page.days.count <= 6)
            let identities = page.days.map { "\($0.metric)|\($0.daysAgo)" }
            #expect(Set(identities).count == identities.count, "offset \(offset) repeated a day")
        }
    }

    /// Paging must actually ADVANCE. The check above proves a page has no repeats inside itself,
    /// which an offset that was silently ignored would also satisfy — every page would just be page
    /// one, and an agent working through the pool would burn its whole call budget re-reading the
    /// same six days and conclude there was nothing more to find.
    @Test func `unusualDays paging advances through the pool`() async throws {
        let tool = try UnusualDaysTool(substrate: richSubstrate())
        let first = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 0)).days
        let second = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 6)).days
        #expect(first.count == 6, "the fixture must be deep enough to page")
        #expect(!second.isEmpty, "page two was empty on a 12-metric substrate")

        let firstIDs = Set(first.map { "\($0.metric)|\($0.daysAgo)" })
        let secondIDs = Set(second.map { "\($0.metric)|\($0.daysAgo)" })
        #expect(firstIDs.isDisjoint(with: secondIDs), "page two re-served page one")

        // Walking past the end stops rather than wrapping — an agent that keeps paging must be able
        // to tell it has reached the bottom.
        let far = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 9999)).days
        #expect(far.isEmpty, "an offset past the pool returned \(far.count) rows")
    }

    /// The director's journal tool was the one capped tool with no coverage here. Its rows are
    /// model-written text (a finding's title, a panel's reason, a barren angle's lens) and they ride
    /// into the director's 4k window, so an uncapped read is the same overflow as any other.
    @Test func `researchJournal never returns more than its line cap`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let run = UUID()
        for index in 0..<30 {
            try await writer.recordJournal(
                kind: .rejected, text: "claim \(index)", reason: "coincidence",
                jobRunID: run, now: now
            )
        }
        let tool = ResearchJournalTool(writer: writer, now: now)
        for limit in hostileLimits {
            let lines = try await tool.call(arguments: .init(kind: "rejected", limit: limit)).lines
            #expect(lines.count <= ResearchJournalTool.maxLines, "limit \(limit): \(lines.count)")
            #expect(!lines.isEmpty, "limit \(limit) returned nothing at all")
        }
        // An unrecognized kind is refused rather than coerced into one the director didn't ask for.
        let bogus = try await tool.call(arguments: .init(kind: "notAKind", limit: 4)).lines
        #expect(bogus.isEmpty)
    }
}
