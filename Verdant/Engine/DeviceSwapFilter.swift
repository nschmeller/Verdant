import Foundation

/// Identifies likely device-swap days — a new/replaced Apple Watch recalibrates several auto-measured
/// vitals at once, producing a simultaneous discontinuity across them on a single day. That one day is
/// a textbook generator of spurious findings in *every* detector (synchronized first-difference
/// correlations, inflated recent variance, false records/regimes).
///
/// **It reports; it no longer removes.** This used to expose `removingSuspectDays`, which erased every
/// suspect day from every metric's series before any agent saw the data — a deterministic decision
/// ("this was hardware, not you") taken silently on the agents' behalf, and the last place in the
/// pipeline where real observations were destroyed rather than judged. The days now stay, and the
/// signature travels with them: `UnusualDay.suspectedDeviceSwap` (and `RegimeShift.suspectedDeviceSwap`)
/// carry the verdict as a fact, stated in the `basis` prose the investigator reads. Whether a
/// simultaneous jump is a new watch or a real event is a judgment — so it belongs to the agents and the
/// skeptic panel's "measurement artifact?" lens, not to a filter.
///
/// Pure and `nonisolated`.
nonisolated enum DeviceSwapFilter {
    /// Days on which at least `minVitals` Watch vitals each jumped by more than `jumpZ` standard
    /// deviations of their own day-to-day change, mapped to HOW MANY did.
    ///
    /// The count, not just membership. Two vitals jumping together is thin evidence for a new watch
    /// and five on one day is near-certain, and a `Set<Date>` says the same thing about both — the
    /// same defect `RegimeShift.coJumpingVitals` was carrying, in the other of the two places this
    /// signature is computed. The number is already calculated here; it was being discarded on the
    /// way out.
    static func suspectDayVitals(
        in series: [DailySeries], minVitals: Int = 2, jumpZ: Double = 3.0
    ) -> [Date: Int] {
        var jumpsPerDay: [Date: Int] = [:]
        for entry in series where entry.metric.isWatchVital {
            let diffs = CorrelationEngine.firstDifferences(entry.values)
            // Chronological, never dictionary order — `sampleStandardDeviation` sums in the order
            // given and Swift's dictionary iteration order isn't stable across equal dictionaries,
            // so an unordered read let the same history produce a marginally different threshold
            // (and so a different suspect-day set) between runs.
            let sd = MetricStatsProvider
                .sampleStandardDeviation(diffs.sorted { $0.key < $1.key }.map(\.value))
            guard sd > 0 else { continue }
            for (day, delta) in diffs where abs(delta) > jumpZ * sd {
                jumpsPerDay[day, default: 0] += 1
            }
        }
        return jumpsPerDay.filter { $0.value >= minVitals }
    }

    /// Just the days, for callers that only need membership.
    static func suspectDays(in series: [DailySeries], minVitals: Int = 2, jumpZ: Double = 3.0) -> Set<Date> {
        Set(suspectDayVitals(in: series, minVitals: minVitals, jumpZ: jumpZ).keys)
    }
}
