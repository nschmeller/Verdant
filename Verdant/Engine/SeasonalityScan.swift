import Foundation

/// Detects an **annual rhythm** — a metric that reliably runs high in some months and low in others,
/// year after year. This is a finding class every other detector structurally cannot produce:
/// `analyze`'s `dayFilter` reaches weekday shape but nothing reaches month-of-year, the
/// `yearOverYear` comparison measures a LEVEL against the same window last year rather than a
/// repeating cycle, and volatility/regime/milestone all look at one stretch against another. "Your
/// resting heart rate climbs every winter and settles every spring" is invisible to all of them, and
/// with a few years of history it is exactly the kind of thing a person cannot see for themselves.
///
/// **The trap this engine is built around: a trend is not a season.** A metric that drifted steadily
/// upward for eighteen months has high "summer" values and low "winter" values purely because summer
/// came later, and a naive month-mean comparison reports that as a beautiful seasonal swing. Two
/// things prevent it here:
///
/// 1. **A linear trend is removed from each year before any month is measured.** Subtracting the
///    year's MEAN is not enough, and the first version of this engine got that wrong: a steady climb
///    leaves January below its year's average and December above it in *every* year, so all years
///    agree on a rhythm that does not exist — a pure straight line scored a 1.52 SD "seasonal" peak.
///    A per-year least-squares line is the right thing to remove, because a genuine annual cycle
///    returns to where it started each year and therefore has almost no linear component within a
///    year, while a multi-year drift is almost entirely linear within one.
/// 2. **A month must repeat across at least two years to count at all**, and the scan reports
///    `yearsAgreeing` — how many of those years actually moved the same way. One year with a rough
///    January is not a season, and the number that says so travels with the finding.
///
/// Pure and `nonisolated` — fully unit-testable. Numbers inform, agents decide: every metric with a
/// computable rhythm surfaces, ranked by the size of its peak swing, with no significance gate. The
/// agent (and the skeptic and replication panels behind it) judges whether a 0.4-SD swing that two
/// of three years agreed on is worth telling.
nonisolated struct SeasonalityScan {
    nonisolated struct Config {
        /// Days needed in a (year, month) cell before its mean is used at all. A handful of days
        /// cannot represent a month, and a single day would make the deviation pure noise.
        var minDaysPerMonth = 7
        /// Distinct years a month must appear in. Two is the floor at which "it happens every year"
        /// is a statement about anything — one year is an anecdote, not a rhythm.
        var minYearsPerMonth = 2
        /// Distinct years of data the metric needs overall.
        var minYears = 2

        static let `default` = Config()
    }

    let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    func scan(_ series: [DailySeries], now: Date = .now) -> [SeasonalSwing] {
        let calendar = Calendar.civil
        // Anchor on the last complete day, matching every other scan's window convention.
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        // Biggest swing first — the strongest-first ranking is what bounds what token-budgeted
        // consumers (`patternScan`'s cap) actually see.
        return series
            .compactMap { swing(for: $0, anchor: anchor, calendar: calendar) }
            .sorted { abs($0.peakEffect) > abs($1.peakEffect) }
    }

    /// One metric's rhythm, or `nil` when there isn't a computable one.
    private func swing(
        for entry: DailySeries, anchor: Date, calendar: Calendar
    ) -> SeasonalSwing? {
        // Chronological, never dictionary order — the same reason every other scan sorts: Swift's
        // dictionary iteration order is not stable across separately-built dictionaries holding
        // equal pairs, and the sums below would otherwise differ in the last ULP and flip a near-tie
        // in the ranking (which decides what survives `patternScan`'s cap).
        let days = entry.values.filter { $0.key <= anchor }.sorted { $0.key < $1.key }
        guard days.count >= 2 else { return nil }

        var yearDays: [Int: [(day: Date, value: Double)]] = [:]
        for (day, value) in days {
            guard let year = calendar.dateComponents([.year], from: day).year else { continue }
            yearDays[year, default: []].append((day, value))
        }
        guard yearDays.count >= config.minYears else { return nil }

        let (residualsByCell, allResiduals) = detrended(yearDays, calendar: calendar)
        // Scale is the spread of DAILY residuals, so a swing is reported in units of the metric's
        // own de-trended day-to-day variability rather than of its raw magnitude.
        let scale = MetricStatsProvider.sampleStandardDeviation(allResiduals)
        // `scale > 0` is NOT enough, and this is the second time that exact insufficiency has bitten
        // in this codebase (see `VolatilityScan`'s `recentSD > 0`). When a per-year line explains
        // essentially all the variance — a perfectly linear series — the residuals are floating-point
        // noise around 1e-14, and dividing noise by noise yields an arbitrary O(1) number: a straight
        // line scored a 0.71 SD "seasonal" peak. The floor has to be relative to the data's own
        // magnitude, not merely non-zero.
        let magnitude = max(abs(MetricStatsProvider.mean(days.map(\.value))), 1)
        guard scale > 1e-9 * magnitude else { return nil }

        // Only months seen in enough distinct years can be part of a rhythm.
        let repeating = monthDeviations(residualsByCell)
            .filter { $0.value.count >= config.minYearsPerMonth }
        guard repeating.count >= 2 else { return nil }
        // Kept in the metric's own units as well as in SDs. An effect measured only in standard
        // deviations of a nearly-flat residual can read as enormous while being physically nothing —
        // "a 2.3 SD winter swing" that amounts to 0.002 kg — and the agent has no way to tell without
        // the raw figure, which is why `verifiedBasis` states both.
        let rawByMonth = repeating.mapValues { MetricStatsProvider.mean($0) }
        let averaged = rawByMonth.mapValues { $0 / scale }.sorted { $0.key < $1.key }
        guard let peak = averaged.max(by: { abs($0.value) < abs($1.value) }) else { return nil }
        // The opposite extreme: the month furthest the OTHER way from the peak, which is what makes
        // a swing a swing rather than one odd month.
        let opposite = peak.value >= 0
            ? averaged.min(by: { $0.value < $1.value })
            : averaged.max(by: { $0.value < $1.value })
        guard let low = opposite, peak.value.isFinite, low.value.isFinite else { return nil }
        let peakDeviations = repeating[peak.key] ?? []
        let rawSwing = abs((rawByMonth[peak.key] ?? 0) - (rawByMonth[low.key] ?? 0))
        guard rawSwing.isFinite else { return nil }

        return SeasonalSwing(
            metric: entry.metric,
            swingInUnits: rawSwing,
            peakMonth: peak.key,
            peakEffect: peak.value,
            oppositeMonth: low.key,
            oppositeEffect: low.value,
            monthsCompared: averaged.count,
            yearsObserved: peakDeviations.count,
            yearsAgreeing: peakDeviations.count(where: { ($0 >= 0) == (peak.value >= 0) })
        )
    }

    /// One deviation per (month, year) cell that has enough days to represent its month — the input
    /// to "does this month repeat".
    private func monthDeviations(_ byCell: [YearMonth: [Double]]) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        for cell in byCell.keys.sorted() {
            guard let values = byCell[cell], values.count >= config.minDaysPerMonth else { continue }
            out[cell.month, default: []].append(MetricStatsProvider.mean(values))
        }
        return out
    }

    /// Residuals of a per-year least-squares fit, bucketed by (year, month) — the de-trending step
    /// the whole engine turns on. See the type's doc for why the year MEAN is not enough.
    private func detrended(
        _ yearDays: [Int: [(day: Date, value: Double)]], calendar: Calendar
    ) -> (byCell: [YearMonth: [Double]], all: [Double]) {
        var byCell: [YearMonth: [Double]] = [:]
        var all: [Double] = []
        for year in yearDays.keys.sorted() {
            let points = yearDays[year] ?? []
            guard points.count >= 2 else { continue }
            let xs = points.map { Double(calendar.ordinality(of: .day, in: .year, for: $0.day) ?? 0) }
            let ys = points.map(\.value)
            let slope = AnalysisQueryEngine.slope(x: xs, y: ys)
            let meanX = MetricStatsProvider.mean(xs)
            let meanY = MetricStatsProvider.mean(ys)
            for (index, point) in points.enumerated() {
                let residual = point.value - (meanY + slope * (xs[index] - meanX))
                guard residual.isFinite else { continue }
                let month = calendar.component(.month, from: point.day)
                byCell[YearMonth(year: year, month: month), default: []].append(residual)
                all.append(residual)
            }
        }
        return (byCell, all)
    }

    /// A (year, month) cell, ordered so bucketing iterates chronologically.
    private struct YearMonth: Hashable, Comparable {
        let year: Int
        let month: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.year, lhs.month) < (rhs.year, rhs.month)
        }
    }
}
