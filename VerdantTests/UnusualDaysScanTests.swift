import Foundation
import Testing
@testable import Verdant

/// The every-data-point sweep behind the `unusualDays` tool: every day of every metric is tested
/// against its own robust baseline; only genuinely wild days surface, with the daysAgo the agent
/// plugs into `analyze`.
struct UnusualDaysScanTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// `day(1)` is the last complete day (daysAgo 0); `day(n)` is n−1 days before it.
    private func day(_ index: Int) -> Date {
        calendar.date(byAdding: .day, value: -index, to: calendar.startOfDay(for: now))!
    }

    private func series(_ metric: MetricKey, _ values: [Int: Double]) -> DailySeries {
        DailySeries(
            metric: metric,
            values: Dictionary(uniqueKeysWithValues: values.map { (day($0.key), $0.value) })
        )
    }

    @Test func `flags a wild day with the right distance and direction`() {
        var values: [Int: Double] = [:]
        for i in 1...60 {
            values[i] = i.isMultiple(of: 2) ? 99 : 101
        }
        values[6] = 200 // five days before the last complete day
        let found = UnusualDaysScan.scan(series: [series(.stepCount, values)], now: now)
        #expect(found.count == 1)
        #expect(found.first?.metric == .stepCount)
        #expect(found.first?.daysAgo == 5)
        #expect((found.first?.zScore ?? 0) > UnusualDaysScan.zThreshold)
        #expect(found.first?.basis.contains("above") == true)
    }

    @Test func `constant series yields nothing`() {
        var values: [Int: Double] = [:]
        for i in 1...60 {
            values[i] = 100
        }
        #expect(UnusualDaysScan.scan(series: [series(.stepCount, values)], now: now).isEmpty)
    }

    @Test func `too little history yields nothing`() {
        var values: [Int: Double] = [:]
        for i in 1...10 {
            values[i] = Double(i)
        }
        values[3] = 1000
        #expect(UnusualDaysScan.scan(series: [series(.stepCount, values)], now: now).isEmpty)
    }

    @Test func `the full ranked pool surfaces with no per-metric truncation`() {
        var values: [Int: Double] = [:]
        for i in 1...90 {
            values[i] = i.isMultiple(of: 2) ? 99 : 101
        }
        values[5] = 300
        values[15] = 400
        values[25] = 500
        values[35] = 600
        let found = UnusualDaysScan.scan(series: [series(.stepCount, values)], now: now)
        // All four wild days emit (the old scan-level prefix(3) kept only three); ranking, not
        // truncation, bounds the pool — the tool layer caps each call. Numbers inform, agents decide.
        #expect(found.count == 4)
        #expect(found.first?.value == 600)
        #expect(found.last?.value == 300)
        #expect(zip(found, found.dropFirst()).allSatisfy { abs($0.zScore) >= abs($1.zScore) })
    }

    @Test func `a borderline 2-3 sigma day surfaces with its numeric z`() {
        var values: [Int: Double] = [:]
        for i in 1...60 {
            values[i] = i.isMultiple(of: 2) ? 99 : 101
        }
        values[6] = 104.7 // ≈2.5σ above the robust baseline — below the old 3.0 threshold
        let found = UnusualDaysScan.scan(series: [series(.stepCount, values)], now: now)
        #expect(found.count == 1)
        let z = found.first?.zScore ?? 0
        #expect(z >= 2.0 && z < 3.0) // surfaces now, carrying the number the agent judges by
        #expect(found.first?.daysAgo == 5)
    }
}

/// The `unusualDays` tool over a real substrate: the per-call cap holds, `zScore` rides as a
/// number, and `offset` pages deeper into the scan's full ranked pool across passes.
struct UnusualDaysToolTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// One metric with eight wild days of strictly decreasing extremity — a pool bigger than any
    /// single call's cap, so paging is observable.
    private func substrate() throws -> AnalysisSubstrate {
        var values: [Date: Double] = [:]
        let anchor = calendar.startOfDay(for: now)
        for i in 1...90 {
            values[calendar.date(byAdding: .day, value: -i, to: anchor)!] = i.isMultiple(of: 2) ? 99 : 101
        }
        for (rank, daysBack) in [5, 11, 21, 31, 41, 51, 61, 71].enumerated() {
            values[calendar.date(byAdding: .day, value: -daysBack, to: anchor)!] = 1000 - Double(rank) * 100
        }
        let container = try TestSupport.inMemoryContainer()
        return AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: container),
            series: [DailySeries(metric: .stepCount, values: values)],
            now: now
        )
    }

    @Test func `caps each call and carries the numeric z`() async throws {
        let tool = try UnusualDaysTool(substrate: substrate())
        let result = try await tool.call(
            arguments: .init(metric: "all", limit: 6, offset: 0)
        )
        #expect(result.days.count == 6) // pool holds 8; the per-call cap still bounds output
        let zs = result.days.map(\.zScore)
        #expect(zs.allSatisfy { $0 >= 2.0 }) // numeric, not prose-only
        #expect(zip(zs, zs.dropFirst()).allSatisfy { $0 >= $1 }) // most extreme first
    }

    @Test func `offset pages deeper into the ranked pool`() async throws {
        let tool = try UnusualDaysTool(substrate: substrate())
        let first = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 0))
        let second = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 6))
        #expect(second.days.count == 2) // the two days the first page couldn't fit
        let firstFloor = first.days.map(\.zScore).min() ?? 0
        #expect(second.days.allSatisfy { $0.zScore < firstFloor }) // strictly deeper, no overlap
        let beyond = try await tool.call(arguments: .init(metric: "all", limit: 6, offset: 100))
        #expect(beyond.days.isEmpty) // paging past the pool is empty, not an error
    }

    @Test func `a nil offset means the first page`() async throws {
        let tool = try UnusualDaysTool(substrate: substrate())
        let explicit = try await tool.call(arguments: .init(metric: "all", limit: 3, offset: 0))
        let omitted = try await tool.call(arguments: .init(metric: "all", limit: 3, offset: nil))
        #expect(omitted.days.map(\.daysAgo) == explicit.days.map(\.daysAgo))
    }
}

/// The deep run's hypothesis fleet: thematic angles plus a rotating slice of per-metric
/// investigators, covering the whole roster across passes.
struct DeepLensFleetTests {
    @Test func `deep lenses rotate through every metric across passes`() {
        let metrics = Array(MetricKey.allCases.prefix(30))
        var covered = Set<MetricKey>()
        for pass in 1...3 {
            let lenses = Instructions.deepLenses(pass: pass, metrics: metrics)
            #expect(lenses.count == Instructions.investigationLenses.count + 12)
            for metric in metrics
                where lenses.contains(where: {
                    $0.contains("about \(metric.displayName) specifically")
                })
            {
                covered.insert(metric)
            }
        }
        // 3 passes × 12-metric slices ≥ 30 — every metric got its own investigator.
        #expect(covered.count == metrics.count)
    }

    @Test func `no data means thematic lenses only`() {
        #expect(Instructions.deepLenses(pass: 1, metrics: []) == Instructions.investigationLenses)
    }
}
