import Foundation
import Testing
@testable import Verdant

/// Every engine is well covered for ordinary data. The gaps live at the degenerate edges — and one
/// was real: a perfectly flat recent window gave `VolatilityScan` a CV ratio of exactly 0, and since
/// both its statistic and its ranking are `log(cvRatio)`, the metric surfaced with an INFINITE `seZ`
/// sorted first, ahead of every genuine shift.
///
/// This is the net for that whole class. Real health data does go degenerate — a weight logged
/// identically for a month, a sensor stuck on a constant, a metric that is zero every day — and no
/// number an agent reads may ever be infinite or NaN, because the model will quote it.
struct EngineFinitenessTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// A named series built from a generator over day offsets, so failures say which shape broke.
    private func series(_ metric: MetricKey, _ value: (Int) -> Double, days: Int = 900) -> DailySeries {
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        var values: [Date: Double] = [:]
        for ago in 0..<days {
            values[calendar.date(byAdding: .day, value: -ago, to: anchor)!] = value(ago)
        }
        return DailySeries(metric: metric, values: values)
    }

    /// Shapes that break naive statistics: no spread, no magnitude, extreme magnitude, and the
    /// mixed case that produced the real bug (a varying past, a frozen present).
    private var degenerateShapes: [(name: String, generator: (Int) -> Double)] {
        [
            ("all zero", { _ in 0 }),
            ("constant non-zero", { _ in 70 }),
            ("frozen recent, varying baseline", { $0 < 30 ? 70 : 70 + Double($0 % 5) }),
            ("varying recent, frozen baseline", { $0 < 30 ? 70 + Double($0 % 5) : 70 }),
            ("one spike in a flat series", { $0 == 10 ? 9999 : 5 }),
            ("enormous values", { _ in 1e12 }),
            ("vanishing values", { _ in 1e-9 }),
            ("alternating sign", { $0.isMultiple(of: 2) ? 1 : -1 })
        ]
    }

    @Test func `no engine emits a non-finite number for any degenerate series`() {
        for shape in degenerateShapes {
            let one = series(.bodyMass, shape.generator)
            // A second, differently-shaped metric so the correlation engine has a pair to judge.
            let two = series(.restingHeartRate) { shape.generator($0) * 2 }
            let input = [one, two]

            for shift in VolatilityScan().scan(input, now: now) {
                #expect(shift.seZ.isFinite, "\(shape.name): volatility seZ")
                #expect(shift.cvRatio.isFinite, "\(shape.name): cvRatio")
                #expect(shift.sdRatio.isFinite, "\(shape.name): sdRatio")
            }
            for milestone in MilestoneScan().scan(input, now: now) {
                #expect(milestone.relativeMargin.isFinite, "\(shape.name): milestone margin")
                #expect(milestone.recentMean.isFinite, "\(shape.name): milestone mean")
            }
            for regime in RegimeShiftScan().scan(input, now: now) {
                #expect(regime.score.isFinite, "\(shape.name): regime score")
                #expect(regime.medianStepSD.isFinite, "\(shape.name): regime medianStepSD")
            }
            for swing in SeasonalityScan().scan(input, now: now) {
                #expect(swing.peakEffect.isFinite, "\(shape.name): seasonal peak")
                #expect(swing.oppositeEffect.isFinite, "\(shape.name): seasonal opposite")
                #expect(swing.amplitude.isFinite, "\(shape.name): seasonal amplitude")
                #expect(swing.swingInUnits.isFinite, "\(shape.name): seasonal raw swing")
            }
            for day in UnusualDaysScan.scan(series: input, now: now) {
                #expect(day.zScore.isFinite, "\(shape.name): unusual-day z")
            }
            for coverage in CoverageScan.scan(series: input, now: now) {
                #expect(coverage.density.isFinite, "\(shape.name): coverage density")
            }
            for correlation in CorrelationEngine().scan(in: input).correlations {
                #expect(correlation.r.isFinite, "\(shape.name): r")
                #expect(correlation.partialR.isFinite, "\(shape.name): partialR")
                #expect(correlation.spearman.isFinite, "\(shape.name): spearman")
                #expect(correlation.pValue.isFinite, "\(shape.name): pValue")
                #expect(correlation.nEff.isFinite, "\(shape.name): nEff")
            }
        }
    }

    /// The same guarantee for the agent-defined query surface, which reaches every statistic through
    /// one entry point and hands the number straight to the model.
    @Test func `agent-defined queries never return a non-finite value`() {
        for shape in degenerateShapes {
            let input = [
                series(.bodyMass, shape.generator),
                series(.restingHeartRate) { shape.generator($0) * 2 }
            ]
            for statistic in AnalysisStatistic.allCases {
                for (from, to) in [(30, 0), (5, 5), (365, 0), (2, 0)] {
                    // `lag` is bounded only by a `.range(0...7)` GUIDE — nothing clamps it before it
                    // reaches the engine, and a guide constrains generation rather than promising
                    // anything about the argument that arrives. A lag longer than the window empties
                    // the shifted series; a negative one shifts the wrong way.
                    for lag in [0, 1, 7, -3, 500, Int.max, Int.min] {
                        let outcome = AnalysisQueryEngine.evaluate(
                            AnalysisSpec(
                                metric: .bodyMass, secondaryMetric: .restingHeartRate,
                                statistic: statistic, fromDaysAgo: from, toDaysAgo: to,
                                dayFilter: .all, lag: lag
                            ),
                            series: input, now: now
                        )
                        #expect(
                            outcome.value.isFinite,
                            "\(shape.name)/\(statistic.rawValue)/\(to)–\(from)d/lag \(lag) was not finite"
                        )
                        // And whatever the engine returns, the tool boundary must keep it finite.
                        #expect(
                            outcome.value.toolRounded.isFinite,
                            "\(shape.name)/\(statistic.rawValue)/lag \(lag)"
                        )
                    }
                }
            }
        }
    }
}
