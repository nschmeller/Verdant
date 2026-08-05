import Foundation
import Testing
@testable import Verdant

/// Why `seasonal` is the one pattern kind with no provenance caveat — measured, not argued.
///
/// The other three carry one: a device swap fakes a regime shift outright, sets a record on its own,
/// and changes the spread. The claim made when they were annotated was that an annual rhythm is
/// different, because `SeasonalityScan` removes a per-year least-squares line and a single step at a
/// single date cannot make the same month move the same way across years. That was an argument
/// offered in the same breath as three annotations that turned out to be necessary, so it is worth
/// more as a number.
///
/// It is also why the caveat would be actively harmful here rather than merely unnecessary. A
/// seasonal claim's comparison window is the metric's WHOLE history — so the window rule that keeps
/// the other three notes rare would annotate every seasonal finding of any metric that ever changed
/// device, on the rarest and most valuable finding type. A note on every finding is the same as a
/// note on none.
///
/// What protects the scan is CROSS-YEAR AVERAGING — a month's deviation is the mean of that month
/// across every year it appears in, so a one-time step speaks in one year and is divided by the
/// rest. Replacing that mean with the most extreme year triples the artifact below (0.40 → 1.21) and
/// breaks the bound. That is the property these tests pin, and it is worth stating precisely because
/// the obvious answer is wrong: the per-year LINE de-trending — which sounds like what would absorb
/// a step, and was itself a real bug fixed during this scan's development — turns out not to be
/// doing this job at all. Reverting it to a per-year mean leaves every assertion HERE passing.
///
/// That is not a case for removing it. The same injection run against `SeasonalityScanTests` fails
/// two tests at once — a straight line scoring a 1.52 SD "seasonal" peak. The two defences guard
/// different things: the line de-trending stops a multi-year TREND posing as a season, the averaging
/// stops a one-time STEP posing as one. Weaken either and a different artifact gets through.
struct SeasonalProvenanceTests {
    private let calendar = Calendar.civil

    /// Three full years ending mid-2026, so every month has data in at least two years.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// The step and the seasonal effect are the SAME size, so the comparison is about how each is
    /// treated rather than how big either is.
    private static let effect = 3.0

    private func series(_ value: (Int, Date) -> Double) -> [DailySeries] {
        var values: [Date: Double] = [:]
        let anchor = calendar.startOfDay(for: now)
        for ago in 1...1100 {
            let day = calendar.date(byAdding: .day, value: -ago, to: anchor)!
            values[day] = value(ago, day)
        }
        return [DailySeries(metric: .restingHeartRate, values: values)]
    }

    private func swing(_ series: [DailySeries]) -> SeasonalSwing? {
        SeasonalityScan().scan(series, now: now).first
    }

    /// A genuine January effect, recovered nearly whole. This is the yardstick: without it the
    /// numbers below are merely small, with no scale to be small against.
    private func realSeason() -> SeasonalSwing? {
        swing(series { _, day in
            let month = calendar.component(.month, from: day)
            return 60 + (month == 1 ? Self.effect : 0)
                + Double(calendar.component(.day, from: day) % 3) * 0.1
        })
    }

    @Test func `a real annual effect is recovered nearly whole`() throws {
        let season = try #require(realSeason(), "the detector is inert — everything below is vacuous")
        #expect(season.peakMonth == 1)
        #expect(season.swingInUnits > Self.effect * 0.8, "recovered only \(season.swingInUnits)")
    }

    /// A device swap partway through the history, the same size as that January effect. The scan
    /// still REPORTS a swing — it reports every computable one and lets the agent weigh it, which is
    /// the design — so the question is never whether a number appears but how big it is.
    @Test func `a mid-history device swap is attenuated to a fraction of a real season`() throws {
        let season = try #require(realSeason())
        let stepped = try #require(swing(series { ago, day in
            60 + (ago < 550 ? Self.effect : 0)
                + Double(calendar.component(.day, from: day) % 3) * 0.1
        }))
        // Measured at ~7x weaker. A third is a generous bound that still fails loudly if a month
        // stops being averaged across the years it appears in.
        #expect(
            stepped.swingInUnits < season.swingInUnits / 3,
            "a swap produced \(stepped.swingInUnits) against a real season's \(season.swingInUnits)"
        )
    }

    /// A swap dated to the turn of a year — the alignment that would most resemble a season — is
    /// absorbed almost perfectly (~1,800x). This one IS the per-year centering rather than the
    /// averaging: a step on a year boundary leaves each year internally constant, and subtracting a
    /// per-year fit removes a constant entirely. Mean or line, either does it.
    @Test func `a swap at a year boundary is absorbed almost entirely`() throws {
        let season = try #require(realSeason())
        let boundary = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        let stepped = try #require(swing(series { _, day in
            60 + (day >= boundary ? Self.effect : 0)
                + Double(calendar.component(.day, from: day) % 3) * 0.1
        }))
        #expect(
            stepped.swingInUnits < season.swingInUnits / 100,
            "a New Year swap produced \(stepped.swingInUnits)"
        )
    }
}
