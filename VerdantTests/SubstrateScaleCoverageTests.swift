import Foundation
import Testing
@testable import Verdant

/// Every detector must actually FIRE on a realistically shaped corpus — ten metrics with three
/// years of daily history, the smallest that still reaches all of them (seasonality alone needs two
/// years before it will speak). A fixture that quietly produced nothing would make the scans look healthy
/// while
/// covering none of them.
///
/// **There is deliberately no timing assertion here, and that is the finding.** A wall-clock bound
/// was written first, after the full precompute measured 26 s on this corpus and the correlation
/// engine measured 26.9 s of it. That number is a DEBUG artifact: `xcodebuild test` builds the
/// unoptimised configuration, and Swift numeric array code runs roughly 86× slower there — the same
/// statistical work (3,045 candidates × 1,800 rows) takes 0.217 s under `-O`. Release cannot be
/// measured from here at all, because `@testable import` needs testability, which Release disables.
///
/// So a bound loose enough to pass in Debug says nothing about shipped behaviour, and one tight
/// enough to mean something would fail every run. Performance work on these engines has to be
/// measured in an optimised build — profile the app, or measure the algorithm standalone with
/// `swift -O` — and this file's job is coverage, not timing.
struct SubstrateScaleCoverageTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// Ten metrics × three years, with enough shape that every detector has real work: a seasonal
    /// swing, a regime step, changing volatility, and occasional wild days. Kept small on purpose —
    /// correlation is O(metrics² × days), so thirty metrics × five years took 21 s of an otherwise
    /// six-second suite, all of it Debug-build overhead rather than anything shipped.
    private func realisticSeries() throws -> [DailySeries] {
        let anchor = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        )
        return try Array(MetricKey.allCases.prefix(10)).enumerated().map { index, metric in
            var values: [Date: Double] = [:]
            for ago in 0..<1100 {
                let day = try #require(calendar.date(byAdding: .day, value: -ago, to: anchor))
                let month = calendar.component(.month, from: day)
                let seasonal = month == 1 ? 6.0 : (month == 7 ? -6.0 : 0)
                let step = ago > 550 ? 0.0 : 12.0
                let wobble = Double((ago * (index + 3)) % 17) * (ago < 200 ? 1.8 : 0.6)
                values[day] = 80 + Double(index) + seasonal + step + wobble
            }
            if let wild = calendar.date(byAdding: .day, value: -(index + 5), to: anchor) {
                values[wild] = 5000
            }
            return DailySeries(metric: metric, values: values)
        }
    }

    /// Every detector reached, on data shaped the way real history is.
    @Test func `the realistic corpus gives every detector something to find`() async throws {
        let substrate = try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: realisticSeries(),
            now: now
        )
        await substrate.precompute()
        #expect(await !(substrate.correlationScan().correlations).isEmpty, "no correlations")
        #expect(await !(substrate.volatility()).isEmpty, "no volatility shifts")
        #expect(await !(substrate.regimes()).isEmpty, "no regime shifts")
        #expect(await !(substrate.seasonality()).isEmpty, "no seasonal rhythms")
        #expect(await !(substrate.unusualDays()).isEmpty, "no unusual days")
        #expect(await !(substrate.coverage()).isEmpty, "no coverage rows")
    }
}
