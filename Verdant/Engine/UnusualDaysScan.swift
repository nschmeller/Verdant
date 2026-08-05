import Foundation

/// One day that sits far outside a metric's own typical range — a per-data-point lead the
/// investigator turns into hypotheses ("what else moved around that day?").
nonisolated struct UnusualDay: Equatable {
    let metric: MetricKey
    let day: Date
    /// Days before the last complete day — plugs straight into `analyze` windows.
    let daysAgo: Int
    /// Robust (MAD-based) z-score of the day against the metric's whole history.
    let zScore: Double
    let value: Double
    /// True when `DeviceSwapFilter` flagged this day — several Watch vitals jumped together, the
    /// recalibration signature. Carried, never dropped: whether a strange day is a body event or a
    /// hardware event is exactly the kind of judgment that belongs to the agents (and the skeptic
    /// panel's "measurement artifact?" lens), not to a filter that deletes the day before anyone
    /// can look at it.
    let suspectedDeviceSwap: Bool
    /// How many Watch vitals jumped on this day — the number behind the flag above, which is just
    /// this being at least two. Two is thin evidence for a new watch; five on one day is not, and a
    /// bare flag says the same thing about both.
    var coJumpingVitals = 0
    /// Terse, already-verified statement of what happened, with the real numbers.
    let basis: String
}

/// The every-data-point sweep: EVERY day of EVERY metric is tested against that metric's own robust
/// baseline (median/MAD, so outliers can't inflate their own yardstick), and the days that stand
/// outside it surface as hypothesis seeds. Deterministic and unit-tested; the model only ever reads
/// these and decides which deserve a hypothesis — it never derives them.
///
/// Returns the FULL |z|-ranked pool — nothing is pre-truncated per metric. Strongest-first ranking
/// is the size-bounding mechanism; the tool layer caps what any one call returns (and pages deeper
/// via its `offset`). The numbers inform, the agents decide.
nonisolated enum UnusualDaysScan {
    /// Robust |z| a day must reach to enter the ranked pool. Deliberately low: borderline (2–3σ)
    /// days surface carrying their numeric z for the agent to judge; only statistically
    /// unremarkable days stay out.
    static let zThreshold = 2.0
    /// Minimum days of history before "unusual" means anything.
    static let minSamples = 30
    /// MAD → standard-deviation-equivalent scale for a normal distribution.
    private static let madScale = 1.4826

    static func scan(
        series: [DailySeries],
        now: Date,
        suspectDays: [Date: Int] = [:],
        calendar: Calendar = .civil
    ) -> [UnusualDay] {
        // Exclude today: a partial day is always "unusually low" for cumulative metrics.
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        var out: [UnusualDay] = []
        for oneSeries in series {
            let complete = oneSeries.values.filter { $0.key <= anchor }
            guard complete.count >= minSamples else { continue }
            // Chronological, never dictionary order. Swift's dictionary iteration order is NOT
            // stable across separately-built dictionaries holding the same pairs, and two things
            // here are order-sensitive: the float summation in `sampleStandardDeviation`, and the
            // (unstable) |z| sort at the end, whose tie order follows input order. Reading unordered
            // therefore made the same data yield last-ULP-different scale and a different set of
            // days surviving the tool's cap from one run to the next.
            let byDay = complete.sorted { $0.key < $1.key }
            let values = byDay.map(\.value)
            let center = RegimeShiftScan.median(values)
            let mad = RegimeShiftScan.median(values.map { abs($0 - center) })
            // A zero MAD (metric is 0 or constant most days) would flag every ordinary active day;
            // fall back to the standard deviation, and skip truly constant series.
            let scale = mad > 0
                ? mad * Self.madScale
                : MetricStatsProvider.sampleStandardDeviation(values)
            guard scale > 0 else { continue }

            let flagged = byDay
                .compactMap { day, value -> UnusualDay? in
                    let z = (value - center) / scale
                    guard abs(z) >= Self.zThreshold else { return nil }
                    let daysAgo = calendar.dateComponents([.day], from: day, to: anchor).day ?? 0
                    let dayLabel = Calendar.civilDayLabel(day)
                    let direction = z > 0 ? "above" : "below"
                    let jumpingVitals = suspectDays[day] ?? 0
                    let swap = jumpingVitals > 0
                    // Said out loud in the basis, not just carried as a bool: `basis` is the line the
                    // investigator actually reads and quotes, so the caveat has to travel with it.
                    let swapNote = swap
                        ? " (\(jumpingVitals) Watch vitals jumped this same day — possibly a device "
                        + "change, not the body)"
                        : ""
                    let basis = "\(oneSeries.metric.displayName) "
                        + "\(MetricFormatting.canonical(value, oneSeries.metric)) on \(dayLabel) — "
                        + "\(String(format: "%.1f", abs(z)))σ \(direction) its usual "
                        + MetricFormatting.canonical(center, oneSeries.metric) + swapNote
                    return UnusualDay(
                        metric: oneSeries.metric,
                        day: day,
                        daysAgo: daysAgo,
                        zScore: z,
                        value: value,
                        suspectedDeviceSwap: swap,
                        coJumpingVitals: jumpingVitals,
                        basis: basis
                    )
                }
            out.append(contentsOf: flagged)
        }
        // Strongest first — the ranking, not truncation here, bounds what a tool call surfaces.
        return out.sorted { abs($0.zScore) > abs($1.zScore) }
    }
}
