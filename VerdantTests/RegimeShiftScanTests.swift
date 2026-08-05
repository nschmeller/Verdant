import Foundation
import Testing
@testable import Verdant

/// Unit tests for the regime-shift detector: a clear, sustained step in level is found and located,
/// and — numbers inform, agents decide — weaker or suspect candidates now SURFACE with the evidence
/// fields the old guards used to drop on (score floor, median echo, segment trend, post-gap, device
/// swap), ranked strongest-first so downstream caps still see the best candidates.
struct RegimeShiftScanTests {
    private func series(_ metric: MetricKey, values: [Double], now: Date) -> DailySeries {
        let calendar = Calendar.civil
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        var map: [Date: Double] = [:]
        for (i, v) in values.reversed().enumerated() {
            let day = calendar.date(byAdding: .day, value: -i, to: anchor)!
            map[day] = v
        }
        return DailySeries(metric: metric, values: map)
    }

    @Test func `median handles odd, even, and empty inputs`() {
        // `medianStepSD` (the anti-spike evidence field) is |median(after) − median(before)| in SD
        // units, so the even-count averaging (an off-by-one-prone spot) and the empty guard must be exact.
        #expect(RegimeShiftScan.median([3, 1, 2]) == 2) // odd → middle of the sorted values
        #expect(RegimeShiftScan.median([1, 2, 3, 4]) == 2.5) // even → mean of the two middle
        #expect(RegimeShiftScan.median([10, 2]) == 6) // even, n=2 → mean of both
        #expect(RegimeShiftScan.median([]) == 0) // empty guard, never a crash
    }

    @Test func `finds a clear sustained step and which way it moved, with clean evidence fields`() {
        let now = Date()
        // 60 days around 55, then 40 days around 62 → a settled higher baseline.
        let before = (0..<60).map { 55.0 + ($0 % 2 == 0 ? 1.0 : -1.0) }
        let after = (0..<40).map { 62.0 + ($0 % 2 == 0 ? 1.0 : -1.0) }
        let shifts = RegimeShiftScan().scan(
            [series(.restingHeartRate, values: before + after, now: now)],
            now: now
        )
        #expect(shifts.count == 1)
        #expect(shifts.first?.roseUp == true)
        #expect((shifts.first?.score ?? 0) >= 1.2)
        #expect((shifts.first?.postDays ?? 0) >= 21)
        // A textbook step carries clean evidence: strong median echo, flat segments, no post gap,
        // no device-swap cluster — so the basis carries no caveats.
        #expect((shifts.first?.medianStepSD ?? 0) >= 0.4)
        #expect((shifts.first?.maxSegmentTrendR ?? 1) < 0.6)
        #expect((shifts.first?.maxPostGapDays ?? .max) <= 1)
        #expect(shifts.first?.suspectedDeviceSwap == false)
        #expect(shifts.first?.verifiedBasis.lowercased().contains("not a transient blip") == true)
    }

    @Test func `surfaces a steady ramp with the segment-trend evidence set (a drift, not a step)`() {
        let now = Date()
        // A steady linear rise — segmentation finds a "best" split, but each half trends internally.
        // The old anti-ramp guard dropped this; now it surfaces carrying `maxSegmentTrendR` so the
        // agent (and the skeptic panel) can judge "drift the split bisected" themselves.
        let values: [Double] = (0..<120).map { i in
            let noise: Double = i.isMultiple(of: 2) ? 0.5 : -0.5
            return Double(i) * 0.3 + noise
        }
        let shifts = RegimeShiftScan().scan([series(.bodyMass, values: values, now: now)], now: now)
        #expect(shifts.count == 1)
        #expect((shifts.first?.maxSegmentTrendR ?? 0) >= 0.6)
        #expect(shifts.first?.verifiedBasis.contains("trends internally") == true)
    }

    @Test func `surfaces a flat series as a sub-floor candidate (score below the old 1.2 cutoff)`() {
        let now = Date()
        let values = (0..<120).map { 55.0 + ($0 % 2 == 0 ? 1.0 : -1.0) }
        let shifts = RegimeShiftScan().scan([series(.restingHeartRate, values: values, now: now)], now: now)
        // The old minScore=1.2 floor dropped this; the computability epsilon keeps it, and the tiny
        // score IS the evidence the agent uses to dismiss it.
        #expect(shifts.count == 1)
        #expect((shifts.first?.score ?? .infinity) < 1.2)
    }

    @Test func `flags simultaneous watch-vital steps as a suspected device swap, not dropped`() {
        let now = Date()
        // Two Watch vitals step at the same point → looks like a new Watch, not physiology. The old
        // filter suppressed both; now both surface flagged, with the basis warning the panels.
        let rhr = (0..<60).map { 55.0 + ($0 % 2 == 0 ? 1 : -1) } + (0..<40)
            .map { 62.0 + ($0 % 2 == 0 ? 1 : -1) }
        let hrv = (0..<60).map { 40.0 + ($0 % 2 == 0 ? 1 : -1) } + (0..<40)
            .map { 30.0 + ($0 % 2 == 0 ? 1 : -1) }
        let shifts = RegimeShiftScan().scan([
            series(.restingHeartRate, values: rhr, now: now),
            series(.heartRateVariabilitySDNN, values: hrv, now: now)
        ], now: now)
        #expect(shifts.count == 2)
        // A keypath inside #expect expands to a potentially-throwing call the macro can't mark
        // with try, so this one stays a closure.
        // swiftformat:disable:next preferKeyPath
        #expect(shifts.allSatisfy { $0.suspectedDeviceSwap })
        #expect(shifts.allSatisfy { $0.verifiedBasis.contains("possible device change") })
    }

    /// The COUNT, not just the flag. Two vitals moving together is thin evidence for a device change
    /// and five on the same day is near-certain; the boolean says the same thing about both, and the
    /// number that separates them was computed and discarded. Three vitals here rather than two, so
    /// a hard-coded 2 would not pass.
    @Test func `the basis states how many vitals stepped together, not merely that some did`() {
        let now = Date()
        let step = { (low: Double, high: Double) in
            (0..<60).map { low + ($0.isMultiple(of: 2) ? 1 : -1) }
                + (0..<40).map { high + ($0.isMultiple(of: 2) ? 1 : -1) }
        }
        let shifts = RegimeShiftScan().scan([
            series(.restingHeartRate, values: step(55, 62), now: now),
            series(.heartRateVariabilitySDNN, values: step(40, 30), now: now),
            series(.respiratoryRate, values: step(14, 17), now: now)
        ], now: now)

        #expect(shifts.count == 3)
        // swiftformat:disable:next preferKeyPath
        #expect(shifts.allSatisfy { $0.coJumpingVitals == 3 }, "counted \(shifts.map(\.coJumpingVitals))")
        #expect(shifts.allSatisfy { $0.verifiedBasis.contains("3 watch-measured vitals") })
    }

    /// And a shift with no companions carries zero rather than an unset-looking default that happens
    /// to read the same — the flag and the count must agree.
    @Test func `a lone vital step reports no co-jumping vitals`() {
        let now = Date()
        let rhr = (0..<60).map { 55.0 + ($0.isMultiple(of: 2) ? 1 : -1) }
            + (0..<40).map { 62.0 + ($0.isMultiple(of: 2) ? 1 : -1) }
        let shifts = RegimeShiftScan().scan([series(.restingHeartRate, values: rhr, now: now)], now: now)
        let shift = shifts.first
        #expect(shift?.coJumpingVitals == 0)
        #expect(shift?.suspectedDeviceSwap == false)
        #expect(shift?.verifiedBasis.contains("watch-measured vitals") == false)
    }

    @Test func `an isolated non-vital regime shift amid a device swap stays unflagged`() {
        let now = Date()
        let rhr = (0..<60).map { 55.0 + ($0 % 2 == 0 ? 1 : -1) } + (0..<40)
            .map { 62.0 + ($0 % 2 == 0 ? 1 : -1) }
        let hrv = (0..<60).map { 40.0 + ($0 % 2 == 0 ? 1 : -1) } + (0..<40)
            .map { 30.0 + ($0 % 2 == 0 ? 1 : -1) }
        // A sleep step (not a Watch auto-vital) must never inherit the device-swap suspicion.
        let sleep = (0..<60).map { 7.0 + ($0 % 2 == 0 ? 0.1 : -0.1) } + (0..<40)
            .map { 8.5 + ($0 % 2 == 0 ? 0.1 : -0.1) }
        let shifts = RegimeShiftScan().scan([
            series(.restingHeartRate, values: rhr, now: now),
            series(.heartRateVariabilitySDNN, values: hrv, now: now),
            series(.sleepDurationHours, values: sleep, now: now)
        ], now: now)
        let sleepShift = shifts.first { $0.metric == .sleepDurationHours }
        #expect(sleepShift?.suspectedDeviceSwap == false)
        // The clustered vitals still surface — flagged, not dropped.
        #expect(shifts.first { $0.metric == .restingHeartRate }?.suspectedDeviceSwap == true)
        #expect(shifts.first { $0.metric == .heartRateVariabilitySDNN }?.suspectedDeviceSwap == true)
    }

    @Test func `a step whose new level has an unobserved calendar gap surfaces with the gap on it`() throws {
        let now = Date()
        let calendar = Calendar.civil
        let day0 = try #require(calendar.date(byAdding: .day, value: -200, to: calendar.startOfDay(for: now)))
        var map: [Date: Double] = [:]
        func put(_ offset: Int, _ value: Double) {
            map[calendar.date(byAdding: .day, value: offset, to: day0)!] = value
        }
        // A clean 50→60 step (long, flat segments — a textbook regime) BUT the new level is observed
        // in two clusters separated by a ~30-day gap: we never saw whether it "held" across the gap.
        // The old calendar-density guard rejected it; now `maxPostGapDays` carries the gap and the
        // basis states it, so the agent can discount the tenure claim itself.
        for i in 0..<65 {
            put(i, 50.0 + (i.isMultiple(of: 2) ? 1 : -1))
        } // before
        for i in 0..<27 {
            put(65 + i, 60.0 + (i.isMultiple(of: 2) ? 1 : -1))
        } // after, cluster 1
        for i in 0..<8 {
            put(
                122 + i,
                60.0 + (i.isMultiple(of: 2) ? 1 : -1)
            )
        } // after, cluster 2 (30-day gap)
        let shifts = RegimeShiftScan().scan([DailySeries(metric: .restingHeartRate, values: map)], now: now)
        #expect(shifts.count == 1)
        #expect((shifts.first?.maxPostGapDays ?? 0) >= 30)
        #expect(shifts.first?.verifiedBasis.contains("unobserved stretch") == true)
    }

    @Test func `a brief recent spike surfaces with a weak median echo (not a settled regime)`() {
        let now = Date()
        // Long stable stretch, then only 5 elevated days at the end. The best split's after-segment
        // is mostly stable days plus the spike, so the MEDIANS barely move — the anti-spike evidence
        // the old guard dropped on. Now the shift surfaces with `medianStepSD` small and the basis
        // saying "possibly a few outlier days"; the agent judges.
        let stable = (0..<115).map { 55.0 + ($0 % 2 == 0 ? 1.0 : -1.0) }
        let spike = (0..<5).map { _ in 75.0 }
        let shifts = RegimeShiftScan().scan(
            [series(.restingHeartRate, values: stable + spike, now: now)],
            now: now
        )
        #expect(shifts.count == 1)
        #expect((shifts.first?.medianStepSD ?? 1) < 0.4)
        #expect(shifts.first?.verifiedBasis.contains("outlier days") == true)
    }

    @Test func `ranking is strongest score first`() {
        let now = Date()
        // A decisive step (small noise) vs. a mushy one (large noise): the decisive one must rank first
        // regardless of series order — the strongest-first ordering is what bounds what the capped
        // patternScan output actually shows the agent.
        let decisive = (0..<60).map { 55.0 + ($0 % 2 == 0 ? 0.5 : -0.5) } + (0..<40)
            .map { 65.0 + ($0 % 2 == 0 ? 0.5 : -0.5) }
        let mushy = (0..<60).map { 7.0 + ($0 % 2 == 0 ? 1.5 : -1.5) } + (0..<40)
            .map { 8.0 + ($0 % 2 == 0 ? 1.5 : -1.5) }
        let shifts = RegimeShiftScan().scan([
            series(.sleepDurationHours, values: mushy, now: now),
            series(.bodyMass, values: decisive, now: now)
        ], now: now)
        #expect(shifts.count == 2)
        #expect(shifts.first?.metric == .bodyMass)
        #expect((shifts.first?.score ?? 0) > (shifts.last?.score ?? 0))
    }
}
