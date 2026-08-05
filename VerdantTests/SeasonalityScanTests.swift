import Foundation
import Testing
@testable import Verdant

/// The annual-rhythm detector. Its whole difficulty is one confusion: **a trend is not a season.**
/// A metric that drifted steadily upward for two years has high late-year values and low early-year
/// ones purely because later came later, and a naive month-mean comparison reports that as a
/// beautiful seasonal swing — a confident, completely false finding of exactly the kind this app
/// exists to avoid. Most of these tests are about that.
struct SeasonalityScanTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// A series built from a function of the calendar date, so a test states the shape it means
    /// ("+8 in winter") rather than an opaque array.
    private func series(
        _ metric: MetricKey, days: Int, _ value: (_ date: Date, _ index: Int) -> Double
    ) -> DailySeries {
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        var values: [Date: Double] = [:]
        for ago in 0..<days {
            let day = calendar.date(byAdding: .day, value: -ago, to: anchor)!
            values[day] = value(day, ago)
        }
        return DailySeries(metric: metric, values: values)
    }

    private func month(_ date: Date) -> Int {
        calendar.component(.month, from: date)
    }

    /// Three years of a metric that runs high in January and low in July, on a flat level.
    private func winterPeaking(_ metric: MetricKey = .restingHeartRate) -> DailySeries {
        series(metric, days: 1100) { date, index in
            let m = month(date)
            let seasonal = m == 1 ? 8.0 : (m == 7 ? -8.0 : 0)
            // Light deterministic jitter so the within-month spread is non-zero.
            return 60 + seasonal + Double(index % 3) - 1
        }
    }

    @Test func `a metric that repeats high every January is found`() {
        let swings = SeasonalityScan().scan([winterPeaking()], now: now)
        let swing = try? #require(swings.first)
        #expect(swing?.metric == .restingHeartRate)
        // The swing must connect the two months that actually differ. WHICH of them is named the
        // peak is a property of the fixture, not of the claim: the series ends mid-July, so the
        // partial final year weights the two ends slightly differently, and asserting a direction
        // here would be pinning an artifact of where the window happens to stop.
        #expect(Set([swing?.peakMonth, swing?.oppositeMonth].compactMap(\.self)) == [1, 7])
        #expect((swing?.peakEffect ?? 0) * (swing?.oppositeEffect ?? 0) < 0, "ends must oppose")
        #expect((swing?.amplitude ?? 0) > 1, "an 8-unit swing on a ±1 jitter is enormous")
        // Every year that has the peak month ran the same way — that is what makes it a rhythm.
        #expect(swing?.yearsObserved ?? 0 >= 2)
        #expect(swing?.yearsAgreeing == swing?.yearsObserved)
    }

    /// The test this engine exists for. A pure linear climb has no rhythm at all, but its raw month
    /// means rise monotonically — de-trending against each year's OWN mean is what stops that from
    /// being reported. If the effect survives at all it must be tiny, and the years must not agree.
    @Test func `a steady multi-year trend is not reported as a season`() {
        let climbing = series(.bodyMass, days: 1100) { _, index in
            // Oldest day lowest, newest highest — a clean two-and-a-half-year rise.
            100 - Double(index) * 0.05
        }
        let swings = SeasonalityScan().scan([climbing], now: now)
        for swing in swings {
            let peakName = SeasonalSwing.monthName(swing.peakMonth)
            #expect(
                abs(swing.peakEffect) < 0.5,
                "a pure trend produced a \(swing.peakEffect) SD seasonal peak in \(peakName)"
            )
        }
    }

    /// The realistic version of the same trap, and the one that actually exercises the de-trending.
    /// The test above uses a perfectly straight line, whose residuals collapse to floating-point
    /// noise and are caught by the relative-scale floor — so on its own it would not prove the
    /// per-year fit works. A NOISY climb leaves genuine residuals, so the only thing standing
    /// between it and a fabricated season is the regression.
    @Test func `a noisy multi-year climb is not reported as a season`() {
        let climbing = series(.bodyMass, days: 1100) { _, index in
            // A clear upward drift with day-to-day scatter several times the daily step.
            100 - Double(index) * 0.05 + Double((index * 7) % 11) * 0.4
        }
        for swing in SeasonalityScan().scan([climbing], now: now) {
            let peakName = SeasonalSwing.monthName(swing.peakMonth)
            #expect(
                abs(swing.peakEffect) < 0.5,
                "a noisy trend produced a \(swing.peakEffect) SD seasonal peak in \(peakName)"
            )
        }
    }

    /// A real rhythm riding ON a trend must still be found — de-trending has to remove the drift
    /// without removing the signal, which is the other half of getting this right.
    @Test func `a seasonal swing survives being layered on a trend`() throws {
        let both = series(.restingHeartRate, days: 1100) { date, index in
            let seasonal = month(date) == 1 ? 8.0 : (month(date) == 7 ? -8.0 : 0)
            return 60 - Double(index) * 0.02 + seasonal + Double(index % 3) - 1
        }
        let swing = try #require(SeasonalityScan().scan([both], now: now).first)
        #expect(Set([swing.peakMonth, swing.oppositeMonth]) == [1, 7])
        #expect(swing.amplitude > 1)
    }

    /// A single memorable year is an anecdote. The rhythm must repeat, and when it doesn't the
    /// disagreement has to be visible in `yearsAgreeing` rather than hidden.
    @Test func `one bad January does not make a January rhythm`() {
        let oneOffSpike = series(.restingHeartRate, days: 1100) { date, index in
            let isTargetJanuary = month(date) == 1
                && calendar.component(.year, from: date) == 2025
            return 60 + (isTargetJanuary ? 10 : 0) + Double(index % 3) - 1
        }
        let swings = SeasonalityScan().scan([oneOffSpike], now: now)
        for swing in swings where swing.peakMonth == 1 {
            // Some years had a flat January and one did not, so they cannot all agree.
            #expect(swing.yearsAgreeing < swing.yearsObserved || abs(swing.peakEffect) < 0.5)
        }
    }

    @Test func `less than two years of data yields nothing`() {
        let short = series(.stepCount, days: 200) { date, _ in
            month(date) == 1 ? 12000 : 8000
        }
        #expect(SeasonalityScan().scan([short], now: now).isEmpty)
    }

    /// Computability guards, not worth judgments — the same posture as every other scan.
    @Test func `degenerate series produce no candidate rather than a broken one`() {
        let flat = series(.bodyMass, days: 1100) { _, _ in 70 }
        #expect(SeasonalityScan().scan([flat], now: now).isEmpty, "zero spread has no scale")
        #expect(SeasonalityScan().scan([], now: now).isEmpty)
        let single = DailySeries(metric: .bodyMass, values: [calendar.startOfDay(for: now): 70])
        #expect(SeasonalityScan().scan([single], now: now).isEmpty)
    }

    /// Sparse months must not contribute: a month represented by two days is noise, and its
    /// deviation would swamp the ranking.
    @Test func `a month with only a couple of days is not compared`() {
        let full = series(.restingHeartRate, days: 1100) { date, index in
            60 + (month(date) == 3 ? 40 : 0) + Double(index % 3) - 1
        }
        // Keep only the first two days of every March; leave every other month intact.
        let sparse = full.values.filter { day, _ in
            month(day) != 3 || calendar.component(.day, from: day) <= 2
        }
        let swings = SeasonalityScan().scan(
            [DailySeries(metric: .restingHeartRate, values: sparse)], now: now
        )
        #expect(swings.allSatisfy { $0.peakMonth != 3 }, "a 2-day March drove the ranking")
    }

    /// Every number in the basis line is read by an agent and quoted back to the user, so none of
    /// them may be non-finite and the consistency figure must always be present.
    @Test func `the basis line states the swing and how many years agreed`() throws {
        let swing = try #require(SeasonalityScan().scan([winterPeaking()], now: now).first)
        #expect(swing.peakEffect.isFinite)
        #expect(swing.oppositeEffect.isFinite)
        #expect(swing.amplitude.isFinite)
        let basis = swing.verifiedBasis
        #expect(basis.contains("January"))
        #expect(basis.contains("July"))
        #expect(basis.contains("years"))
        #expect(!basis.contains("nan") && !basis.contains("inf"))
    }
}
