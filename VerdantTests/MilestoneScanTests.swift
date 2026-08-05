import Foundation
import Testing
@testable import Verdant

/// Unit tests for the milestone detector: the latest 7-day stretch sets a record vs. a long history.
struct MilestoneScanTests {
    private func series(_ metric: MetricKey, values: [Double], now: Date) -> DailySeries {
        let calendar = Calendar.civil
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        var map: [Date: Double] = [:]
        // values[last] is the most recent day (anchor), going back in time.
        for (i, v) in values.reversed().enumerated() {
            let day = calendar.date(byAdding: .day, value: -i, to: anchor)!
            map[day] = v
        }
        return DailySeries(metric: metric, values: map)
    }

    @Test func `flags a record-high recent stretch`() {
        let now = Date()
        // 200 days hovering ~50, then a final week clearly higher → record high.
        var values = (0..<193).map { _ in 50.0 }
        values += [62, 63, 64, 63, 65, 64, 66] // last 7 days well above the prior max
        let milestones = MilestoneScan().scan([series(.vo2Max, values: values, now: now)], now: now)
        #expect(milestones.count == 1)
        #expect(milestones.first?.isHigh == true)
        #expect((milestones.first?.spanDays ?? 0) > 60)
    }

    @Test func `flags a record-low recent stretch`() {
        let now = Date()
        // 200 days hovering ~50, then a final week far below anything before → record low. This whole
        // branch (a "worst stretch" milestone, shown with deliberately neutral framing) was otherwise
        // unexercised, including its margin formula `(minPrior − latest)/|minPrior|`.
        var values = (0..<193).map { _ in 50.0 }
        values += [12, 11, 13, 10, 12, 11, 13] // last 7 days well below the prior minimum
        let milestones = MilestoneScan().scan([series(.restingHeartRate, values: values, now: now)], now: now)
        #expect(milestones.count == 1)
        #expect(milestones.first?.isHigh == false) // the low-record branch fired
        #expect((milestones.first?.relativeMargin ?? 0) > 0.1) // a real, positive margin below the prior min
        #expect((milestones.first?.spanDays ?? 0) > 60)
    }

    @Test func `a marginal, short-lived record surfaces with its true margin and span`() {
        let now = Date()
        // 200 days flat at 50, then a final day nudging the last 7-day mean to 50.5 — a true record,
        // but only ~1% over the prior best and comparably extreme just yesterday. The old 2% margin
        // floor and 30-day span guard both dropped this; now it surfaces carrying the numbers, and
        // the agent judges clear-vs-marginal and month-vs-week itself.
        let values = (0..<199).map { _ in 50.0 } + [53.5] // last window mean (50*6+53.5)/7 = 50.5
        let milestones = MilestoneScan().scan([series(.vo2Max, values: values, now: now)], now: now)
        #expect(milestones.count == 1)
        #expect(milestones.first?.isHigh == true)
        let margin = milestones.first?.relativeMargin ?? 0
        #expect(margin > 0.005 && margin < 0.015) // the true ~1% margin, reported not gated
        #expect((milestones.first?.spanDays ?? .max) < 30) // short-span records emit too
    }

    @Test func `a marginal record's span reaches back to the last comparably extreme stretch`() {
        let now = Date()
        // Mostly 40s, one week at 50 about three months back, and a final week at 50.3 — a record by
        // a mere 0.6%. `spanDays` must measure to that comparable near-peak (~97 days), not the full
        // history, so the agent isn't oversold a "record" that was nearly matched recently.
        let values = (0..<96).map { _ in 40.0 }
            + (0..<7).map { _ in 50.0 }
            + (0..<90).map { _ in 40.0 }
            + (0..<7).map { _ in 50.3 }
        let milestones = MilestoneScan().scan([series(.vo2Max, values: values, now: now)], now: now)
        #expect(milestones.count == 1)
        let margin = milestones.first?.relativeMargin ?? 0
        #expect(margin > 0.004 && margin < 0.008) // (50.3 − 50) / 50
        let span = milestones.first?.spanDays ?? 0
        #expect(span > 90 && span < 105) // back to the 50-mean week, not the whole 200 days
    }

    @Test func `verifiedBasis states the margin and span plainly`() {
        let milestone = Milestone(
            metric: .vo2Max, recentMean: 50.5, isHigh: true, spanDays: 12, relativeMargin: 0.011
        )
        // The agent judges decisiveness from the basis, so both numbers must appear verbatim —
        // including sub-2% margins, which a whole-percent format would round to a misleading "1%".
        #expect(milestone.verifiedBasis.contains("1.1%"))
        #expect(milestone.verifiedBasis.contains("12 days"))
    }

    /// And the record's own VALUE, which it did not state.
    ///
    /// Every other kind's basis prints the figure its claim is about — the regime "from X to Y",
    /// volatility both standard deviations, a season its swing in real units. This one gave a margin
    /// and a span and never said what the record WAS, so the agent writing "your highest week ever"
    /// either omitted the number or spent one of four tool calls looking up something the detector
    /// had already computed. The persist route passes `recentMean` to the fidelity check, so prose
    /// quoting it was already supported — it just could not be known.
    @Test func `verifiedBasis states the record's own value`() {
        let milestone = Milestone(
            metric: .vo2Max, recentMean: 50.5, isHigh: true, spanDays: 12, relativeMargin: 0.011
        )
        #expect(
            milestone.verifiedBasis.contains(MetricFormatting.canonical(50.5, .vo2Max)),
            Comment(rawValue: milestone.verifiedBasis)
        )
    }

    /// Canonical, not locale-formatted: this line is read by the model, and a German device would
    /// otherwise hand it "50,5" — the bug that was already found once in agent-facing numbers.
    @Test func `the record's value is written for the model, not the device`() {
        let milestone = Milestone(
            metric: .stepCount, recentMean: 12400, isHigh: true, spanDays: 30, relativeMargin: 0.08
        )
        #expect(!milestone.verifiedBasis.contains("12,400"), Comment(rawValue: milestone.verifiedBasis))
    }

    @Test func `ignores a metric with no recent record`() {
        let now = Date()
        // Flat-ish with the recent week firmly mid-range → no record.
        var values = (0..<193).map { Double(40 + ($0 % 20)) } // ranges 40...59
        values += [50, 51, 49, 50, 52, 48, 50] // squarely inside the historical range
        let milestones = MilestoneScan().scan([series(.vo2Max, values: values, now: now)], now: now)
        #expect(milestones.isEmpty)
    }

    @Test func `ignores a sparsely-logged metric whose windows span weeks`() throws {
        let now = Date()
        let calendar = Calendar.civil
        let anchor = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        // 130 readings logged only every 3rd day → any 7 consecutive readings span ~18 days.
        var map: [Date: Double] = [:]
        for i in 0..<130 {
            let day = calendar.date(byAdding: .day, value: -(i * 3), to: anchor)!
            map[day] = i < 7 ? 80.0 : 50.0 // recent readings a "record" high
        }
        let shifts = MilestoneScan().scan([DailySeries(metric: .vo2Max, values: map)], now: now)
        #expect(shifts.isEmpty)
    }

    @Test func `requires a real history`() {
        let now = Date()
        let values = (0..<40).map { _ in 50.0 } + [70, 71, 72, 73, 74, 75, 76]
        let milestones = MilestoneScan().scan([series(.vo2Max, values: values, now: now)], now: now)
        #expect(milestones.isEmpty) // fewer than minHistoryDays
    }

    @Test func `ranks the most decisive record first regardless of input order`() {
        let now = Date()
        // A single elevated final day lifts only the latest 7-day window above an otherwise flat
        // history, so each record's margin is clean (no rolling-window ramp diluting it): the modest
        // metric's last window mean lands at 52 (~4% over the prior best of 50), the decisive one at 65.
        let modest = (0..<199).map { _ in 50.0 } + [64] // last window mean (50*6+64)/7 = 52
        let decisive = (0..<199).map { _ in 50.0 } + [155] // last window mean (50*6+155)/7 = 65
        // The modest metric is listed FIRST — strength ranking, not input order, must decide which the
        // orchestrator's `.prefix(budget)` keeps, so the strongest record can never be starved.
        let milestones = MilestoneScan().scan([
            series(.stepCount, values: modest, now: now),
            series(.vo2Max, values: decisive, now: now)
        ], now: now)
        #expect(milestones.count == 2)
        #expect(milestones.first?.metric == .vo2Max)
        #expect((milestones.first?.relativeMargin ?? 0) > (milestones.last?.relativeMargin ?? 1))
    }
}
