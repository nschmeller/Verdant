import Foundation
import Testing
@testable import Verdant

/// Unit tests for the volatility-shift detector. Numbers inform, agents decide: it emits a candidate
/// for EVERY metric with computable recent/baseline CVs — no ratio band, no 2-SE gate — carrying
/// `seZ` (|log CV ratio| in standard errors, the old gate's exact statistic) so the agent judges
/// significance, with |log ratio|-descending ranking bounding what capped consumers see.
struct VolatilityScanTests {
    private func series(_ metric: MetricKey, recent: [Double], baseline: [Double], now: Date) -> DailySeries {
        let calendar = Calendar.civil
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        var values: [Date: Double] = [:]
        // Recent block: the last `recent.count` days ending at the anchor.
        for (i, v) in recent.enumerated() {
            let day = calendar.date(byAdding: .day, value: -i, to: anchor)!
            values[day] = v
        }
        // Baseline block: starts just before the 30-day recent window.
        for (i, v) in baseline.enumerated() {
            let day = calendar.date(byAdding: .day, value: -(30 + i), to: anchor)!
            values[day] = v
        }
        return DailySeries(metric: metric, values: values)
    }

    /// Same mean, much wider recent spread → flagged as more erratic, with a decisive seZ.
    @Test func `flags a metric that becomes more erratic with a steady mean`() {
        let now = Date()
        // Recent: oscillates widely around 7. Baseline: tight around 7.
        let recent = (0..<28).map { 7.0 + ($0 % 2 == 0 ? 2.5 : -2.5) }
        let baseline = (0..<90).map { 7.0 + ($0 % 2 == 0 ? 0.2 : -0.2) }
        let shifts = VolatilityScan().scan(
            [series(.sleepDurationHours, recent: recent, baseline: baseline, now: now)],
            now: now
        )
        #expect(shifts.count == 1)
        #expect((shifts.first?.sdRatio ?? 0) > 1) // toward MORE variability, in the SD terms the card uses
        #expect(shifts.first?.meanHeld == true)
        #expect((shifts.first?.cvRatio ?? 0) > 1.6)
        // A ~12.5× CV ratio over 28/90 days is many standard errors from no-change.
        #expect((shifts.first?.seZ ?? 0) >= 2)
        #expect(shifts.first?.verifiedBasis.contains("standard errors from no-change") == true)
    }

    /// Steady spread → still emitted (no drop), with a near-1 ratio and a small seZ the agent can
    /// read as "noise". This pins the old ratio-band and 2-SE gates staying gone.
    /// The mean CHANGE, not just the verdict on it.
    ///
    /// `meanHeld` thresholds a 10% move, so "the average barely moved" spans everything from 0% to
    /// 9.9% — and the entire appeal of a volatility finding is that the spread changed while the
    /// LEVEL did not, which is a claim about exactly that number. An earlier sweep of engine booleans
    /// passed over this one because both means are carried on the struct. They are, and no agent
    /// reads the struct: the basis is what the panels see.
    @Test func `the basis quantifies how much the average moved`() {
        let held = VolatilityShift(
            metric: .restingHeartRate, recentSD: 4, baselineSD: 2, recentMean: 60.5,
            baselineMean: 60, cvRatio: 2, seZ: 3, n: 30
        )
        #expect(held.meanHeld)
        #expect(held.verifiedBasis.contains("barely moved (0.8%)"), Comment(rawValue: held.verifiedBasis))

        let moved = VolatilityShift(
            metric: .restingHeartRate, recentSD: 4, baselineSD: 2, recentMean: 72,
            baselineMean: 60, cvRatio: 2, seZ: 3, n: 30
        )
        #expect(!moved.meanHeld)
        #expect(moved.verifiedBasis.contains("also shifted (20.0%)"), Comment(rawValue: moved.verifiedBasis))
    }

    /// The figure the basis prints and the figure the fidelity check accepts are the SAME
    /// expression.
    ///
    /// They were not: the basis computed the mean shift inline while the persist route passed only
    /// `n` — under a comment claiming it passed the percentage too. A comment describing behaviour
    /// the code does not have is worse than none, because it stops the next reader looking.
    @Test func `the stated mean shift is the one the fidelity check is given`() {
        let moved = VolatilityShift(
            metric: .restingHeartRate, recentSD: 4, baselineSD: 2, recentMean: 72,
            baselineMean: 60, cvRatio: 2, seZ: 3, n: 30
        )
        let percent = try? #require(moved.meanShiftPercent)
        #expect(percent == 20)
        // Printed in the basis…
        #expect(moved.verifiedBasis.contains("20.0%"))
        // …and accepted from prose, via the same value.
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "The average moved about 20%.",
            basis: moved.verifiedBasis,
            verified: [
                moved.recentSD,
                moved.baselineSD,
                moved.recentMean,
                moved.baselineMean,
                moved.cvRatio,
                moved.sdRatio,
                moved.seZ
            ]
                + [moved.meanShiftPercent].compactMap(\.self),
            counts: [Double(moved.n)]
        )
        #expect(unsupported.isEmpty, "\(unsupported)")
    }

    /// A zero baseline has no percentage to state, and must not print one.
    @Test func `a zero baseline mean states no percentage`() {
        let shift = VolatilityShift(
            metric: .stepCount, recentSD: 4, baselineSD: 2, recentMean: 100,
            baselineMean: 0, cvRatio: 2, seZ: 3, n: 30
        )
        #expect(!shift.verifiedBasis.contains("%)"), Comment(rawValue: shift.verifiedBasis))
    }

    @Test func `surfaces a stable-variability metric with a near-one ratio and small seZ`() {
        let now = Date()
        let recent = (0..<28).map { 7.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }
        let baseline = (0..<90).map { 7.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }
        let shifts = VolatilityScan().scan(
            [series(.sleepDurationHours, recent: recent, baseline: baseline, now: now)],
            now: now
        )
        #expect(shifts.count == 1)
        let shift = shifts.first
        #expect(abs((shift?.cvRatio ?? 0) - 1) < 0.1) // well inside the old 0.62…1.6 dead band
        #expect((shift?.seZ ?? .infinity) < 2) // and the basis carries HOW insignificant it is
        #expect(shift?.verifiedBasis.contains("standard errors from no-change") == true)
    }

    /// seZ carries the exact statistic the old gate computed: |log cvRatio| / delta-method SE.
    @Test func `seZ matches the hand-computed log-ratio standard-error statistic`() throws {
        let now = Date()
        let recent = (0..<28).map { 7.0 + ($0 % 2 == 0 ? 0.8 : -0.8) }
        let baseline = (0..<90).map { 7.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }
        let shifts = VolatilityScan().scan(
            [series(.sleepDurationHours, recent: recent, baseline: baseline, now: now)],
            now: now
        )
        let shift = try #require(shifts.first)
        let se = (1.0 / (2.0 * Double(28 - 1)) + 1.0 / (2.0 * Double(90 - 1))).squareRoot()
        #expect(abs(shift.seZ - abs(log(shift.cvRatio)) / se) < 1e-9)
    }

    /// The count floors are computability only (a sample SD and its SE need ≥ 2 observations):
    /// a handful of recent days now surfaces — with the wide-uncertainty seZ that sample deserves —
    /// while a single recent day stays out because no spread statistic exists to hand the agent.
    @Test func `count floors are computability, not worth`() {
        let now = Date()
        let baseline = (0..<90).map { 7.0 + ($0 % 2 == 0 ? 0.2 : -0.2) }
        // 5 recent days: the old minRecent=20 floor dropped this; now it surfaces with its seZ.
        let fiveRecent = (0..<5).map { 7.0 + ($0 % 2 == 0 ? 2.5 : -2.5) }
        let five = VolatilityScan().scan(
            [series(.sleepDurationHours, recent: fiveRecent, baseline: baseline, now: now)],
            now: now
        )
        #expect(five.count == 1)
        #expect((five.first?.n ?? 0) == 5)
        #expect((five.first?.seZ ?? -1) >= 0)
        // 1 recent day: a sample SD is undefined — nothing computable to emit.
        let one = VolatilityScan().scan(
            [series(.sleepDurationHours, recent: [7.0], baseline: baseline, now: now)],
            now: now
        )
        #expect(one.isEmpty)
    }

    /// Biggest change in either direction first — the strongest-first ranking is the size-bounding
    /// mechanism for capped downstream consumers, so it must hold across weak and strong candidates.
    @Test func `ranks by absolute log CV ratio, strongest first`() {
        let now = Date()
        let tightBaseline = (0..<90).map { 7.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }
        let big = series(
            .sleepDurationHours,
            recent: (0..<28).map { 7.0 + ($0 % 2 == 0 ? 2.5 : -2.5) }, // ~5× CV
            baseline: tightBaseline, now: now
        )
        let small = series(
            .restingHeartRate,
            recent: (0..<28).map { 55.0 + ($0 % 2 == 0 ? 0.65 : -0.65) }, // ~1.3× CV, sub-band
            baseline: (0..<90).map { 55.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }, now: now
        )
        let steady = series(
            .bodyMass,
            recent: (0..<28).map { 80.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }, // ~1× CV
            baseline: (0..<90).map { 80.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }, now: now
        )
        let shifts = VolatilityScan().scan([steady, small, big], now: now)
        #expect(shifts.count == 3) // every computable candidate surfaces
        #expect(shifts.map(\.metric) == [.sleepDurationHours, .restingHeartRate, .bodyMass])
    }

    /// A perfectly flat recent window used to yield `cvRatio == 0`, and this scan's statistic AND
    /// its ranking are both `log(cvRatio)` — so `seZ` came out infinite and the metric sorted FIRST,
    /// presenting the steadiest possible signal to the agents as the most significant volatility
    /// shift in the data. Every emitted candidate must carry finite numbers.
    @Test func `a flat recent window yields no candidate, and never an infinite statistic`() throws {
        let now = Date()
        let calendar = Calendar.civil
        let anchor = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        var values: [Date: Double] = [:]
        // Baseline varies; the most recent 30 days are identical.
        for ago in 30..<150 {
            try values[#require(calendar.date(byAdding: .day, value: -ago, to: anchor))] = 70 +
                Double(ago % 5)
        }
        for ago in 0..<30 {
            try values[#require(calendar.date(byAdding: .day, value: -ago, to: anchor))] = 70
        }
        let shifts = VolatilityScan().scan([DailySeries(metric: .bodyMass, values: values)], now: now)

        #expect(!shifts.contains { $0.metric == .bodyMass })
        let allFinite = shifts.allSatisfy { $0.seZ.isFinite && $0.cvRatio.isFinite && $0.cvRatio > 0 }
        #expect(allFinite)
    }
}
