import Foundation
import Testing
@testable import Verdant

/// The device-swap detector REPORTS; it does not remove. These pin its core signature — a single day
/// on which several Watch vitals jump at once (a recalibration) — its non-triggers, and the property
/// that matters most now: the day survives into the data the agents read, carrying the verdict as a
/// flag they can judge instead of being deleted before anyone sees it.
struct DeviceSwapFilterTests {
    private let calendar = Calendar.civil
    /// One fixed instant for the whole suite, so a run that straddles midnight can't shift the
    /// anchor between two `series(...)` calls in the same test.
    private let now = Date()

    private var anchor: Date {
        calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
    }

    private func series(_ metric: MetricKey, _ values: [Double]) -> DailySeries {
        var map: [Date: Double] = [:]
        for (i, value) in values.reversed().enumerated() {
            map[calendar.date(byAdding: .day, value: -i, to: anchor)!] = value
        }
        return DailySeries(metric: metric, values: map)
    }

    /// The date of `values[index]` for a series of `count` days built by `series(_:_:)` — index 0 is
    /// the oldest day, `count - 1` the most recent complete one.
    private func date(index: Int, of count: Int) -> Date {
        calendar.date(byAdding: .day, value: -(count - 1 - index), to: anchor)!
    }

    /// A flat-ish series with one wild day — an OUTLIER, unlike `stepping*`'s level change. A step is
    /// invisible to the strange-day sweep (both levels are ordinary), so only a spike can carry the
    /// flag into `unusualDays`, which is where an agent meets it.
    private func spiking(_ base: Double, spike: Double, at index: Int, count: Int = 60) -> [Double] {
        (0..<count).map { i in i == index ? spike : base + Double((i * 7) % 3) }
    }

    /// Two Watch vitals each step to a new level on the SAME day — the recalibration signature.
    private var steppingRHR: [Double] {
        Array(repeating: 55.0, count: 20) + Array(repeating: 65.0, count: 20)
    }

    private var steppingHRV: [Double] {
        Array(repeating: 40.0, count: 20) + Array(repeating: 30.0, count: 20)
    }

    @Test func `a day where two Watch vitals step together is a suspected device swap`() {
        let suspect = DeviceSwapFilter.suspectDays(in: [
            series(.restingHeartRate, steppingRHR),
            series(.heartRateVariabilitySDNN, steppingHRV)
        ])
        #expect(suspect.count == 1) // exactly the one shared step day
    }

    /// The conversion this file exists to guard: the suspect day is still THERE, and the strange-day
    /// sweep hands it to the agent flagged rather than silently omitting it. Deleting it was the last
    /// place real observations were discarded by a rule instead of judged.
    /// The COUNT, not just the flag — the same evidence `RegimeShift.coJumpingVitals` carries, in
    /// the other place this signature is computed. Two vitals jumping together is thin evidence for
    /// a new watch and five on one day is near-certain; a `Set<Date>` said the same thing about both.
    ///
    /// THREE vitals here, deliberately: a hard-coded 2 would satisfy the two-vital fixture used by
    /// every other test in this suite.
    @Test func `the strange-day caveat states how many vitals jumped`() {
        let spikeIndex = 30
        let input = [
            series(.restingHeartRate, spiking(55, spike: 95, at: spikeIndex)),
            series(.heartRateVariabilitySDNN, spiking(40, spike: 5, at: spikeIndex)),
            series(.respiratoryRate, spiking(14, spike: 30, at: spikeIndex))
        ]
        let swapDay = date(index: spikeIndex, of: 60)

        let suspect = DeviceSwapFilter.suspectDayVitals(in: input)
        #expect(suspect[swapDay] == 3, "counted \(suspect[swapDay] ?? 0)")

        let flagged = UnusualDaysScan.scan(series: input, now: now, suspectDays: suspect)
        let onSwapDay = flagged.filter { $0.day == swapDay }
        #expect(!onSwapDay.isEmpty, "the swap day never reached the strange-day pool")
        let counted = onSwapDay.allSatisfy { $0.coJumpingVitals == 3 }
        #expect(counted, "carried \(onSwapDay.map(\.coJumpingVitals))")
        let stated = onSwapDay.allSatisfy { $0.basis.contains("3 Watch vitals jumped") }
        #expect(stated, "the count never reached the line the agent reads")
    }

    @Test func `a suspected swap day survives into the data, flagged rather than deleted`() {
        // Both Watch vitals go wild on the same day — a recalibration that is also a strange day.
        let spikeIndex = 30
        let input = [
            series(.restingHeartRate, spiking(55, spike: 95, at: spikeIndex)),
            series(.heartRateVariabilitySDNN, spiking(40, spike: 5, at: spikeIndex))
        ]
        let swapDay = date(index: spikeIndex, of: 60)
        let suspect = DeviceSwapFilter.suspectDayVitals(in: input)
        #expect(suspect[swapDay] == 2, "counted \(suspect[swapDay] ?? 0) jumping vitals")

        // Still present in every metric's series — nothing was removed.
        for entry in input {
            #expect(entry.values.count == 60)
            #expect(entry.values[swapDay] != nil)
        }

        // And the sweep marks it, so the investigator reads the caveat instead of never seeing the day.
        let flagged = UnusualDaysScan.scan(series: input, now: now, suspectDays: suspect)
        let onSwapDay = flagged.filter { $0.day == swapDay }
        let everyOneFlagged = onSwapDay.allSatisfy(\.suspectedDeviceSwap)
        let everyOneSaysSo = onSwapDay.allSatisfy { $0.basis.contains("possibly a device change") }
        // A day the detector did NOT suspect is never dressed up as hardware.
        let othersUnflagged = flagged
            .filter { suspect[$0.day] == nil }
            .allSatisfy { !$0.suspectedDeviceSwap }
        #expect(!onSwapDay.isEmpty)
        #expect(everyOneFlagged)
        #expect(everyOneSaysSo)
        #expect(othersUnflagged)
    }

    @Test func `a single vital stepping alone is not a device swap`() {
        // Only one vital steps; the >=2-vitals requirement means no day is suspect (a real physiological
        // shift in one metric must not be discarded as a recalibration).
        let suspect = DeviceSwapFilter.suspectDays(in: [
            series(.restingHeartRate, steppingRHR),
            series(.heartRateVariabilitySDNN, Array(repeating: 40.0, count: 40)) // flat
        ])
        #expect(suspect.isEmpty)
    }

    /// The WIRING, as opposed to the mechanism.
    ///
    /// The test above hands `suspectDays` to the sweep itself. Production does not: the substrate
    /// runs the filter and threads the result into `UnusualDaysScan` in `unusualDaysTask`. And
    /// `suspectDays` is DEFAULTED to `[]`, so dropping that argument compiles silently — the caveat
    /// would disappear from every basis the agent reads while the test above stayed green.
    ///
    /// What that costs is not cosmetic. The caveat is the only thing standing between a Watch
    /// recalibration and a confident finding about the user's physiology; the day is deliberately
    /// kept in the data (flagged, not deleted) precisely so an agent can judge it, and it can only
    /// judge what it is told.
    @Test func `the substrate threads the swap flag into the days the agent reads`() async throws {
        let spikeIndex = 30
        let input = [
            series(.restingHeartRate, spiking(55, spike: 95, at: spikeIndex)),
            series(.heartRateVariabilitySDNN, spiking(40, spike: 5, at: spikeIndex))
        ]
        let swapDay = date(index: spikeIndex, of: 60)
        let substrate = try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: input, now: now
        )

        // Through the real memoized path, not the scan called directly.
        #expect(await substrate.suspectDays()[swapDay] == 2)
        let days = await substrate.unusualDays()
        let onSwapDay = days.filter { $0.day == swapDay }
        #expect(!onSwapDay.isEmpty, "the swap day never reached the strange-day pool")
        let flagged = onSwapDay.allSatisfy(\.suspectedDeviceSwap)
        let explained = onSwapDay.allSatisfy { $0.basis.contains("possibly a device change") }
        #expect(flagged, "the substrate lost the swap flag on the way to the agent")
        #expect(explained, "the flag survived but the agent-facing basis never says so")
    }
}
