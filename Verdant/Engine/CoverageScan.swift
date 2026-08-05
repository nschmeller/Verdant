import Foundation

/// One metric's observational footprint — what data EXISTS, where it starts and stops, and where
/// the holes are. Every other scan reports patterns in the data that is there and silently says
/// nothing about the data that isn't; this is the map of the territory itself, so the discovery
/// fleet can aim at unexplored corners instead of re-walking the well-lit ones.
nonisolated struct MetricCoverage: Equatable {
    let metric: MetricKey
    /// Days with an actual observation (up to the last complete day).
    let observedDays: Int
    /// Calendar span from first to last observation, inclusive.
    let spanDays: Int
    let firstDaysAgo: Int
    let lastDaysAgo: Int
    /// The longest run of consecutive unobserved days inside the span.
    let largestGapDays: Int
    /// Terse, already-verified sentence for the model.
    let basis: String

    /// Fraction of the span that has observations — the "how holey" score.
    var density: Double {
        spanDays > 0 ? Double(observedDays) / Double(spanDays) : 0
    }
}

/// Deterministic coverage sweep: for every metric, how much history exists, how fresh and how old
/// it is, and the largest hole in it. Pure and unit-tested; the model only reads the result.
nonisolated enum CoverageScan {
    static func scan(
        series: [DailySeries],
        now: Date,
        calendar: Calendar = .civil
    ) -> [MetricCoverage] {
        // Anchor on the last complete day, like every other scan — today is always "missing".
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        return series.compactMap { oneSeries in
            let days = oneSeries.values.keys.filter { $0 <= anchor }.sorted()
            guard let first = days.first, let last = days.last else { return nil }
            let spanDays = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            var largestGap = 0
            for (previous, next) in zip(days, days.dropFirst()) {
                let separation = calendar.dateComponents([.day], from: previous, to: next).day ?? 1
                largestGap = max(largestGap, separation - 1)
            }
            let firstDaysAgo = calendar.dateComponents([.day], from: first, to: anchor).day ?? 0
            let lastDaysAgo = calendar.dateComponents([.day], from: last, to: anchor).day ?? 0
            let gapNote = largestGap > 0 ? "; largest gap \(largestGap)d" : ""
            let basis = "\(oneSeries.metric.displayName): \(days.count) of \(spanDays) days observed, "
                + "from \(firstDaysAgo)d ago to \(lastDaysAgo)d ago\(gapNote)"
            return MetricCoverage(
                metric: oneSeries.metric,
                observedDays: days.count,
                spanDays: spanDays,
                firstDaysAgo: firstDaysAgo,
                lastDaysAgo: lastDaysAgo,
                largestGapDays: largestGap,
                basis: basis
            )
        }
    }
}
