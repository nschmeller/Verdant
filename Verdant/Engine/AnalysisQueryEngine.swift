import Foundation

/// The statistics an agent-defined analysis query may compute over the daily series.
nonisolated enum AnalysisStatistic: String, CaseIterable {
    case mean, median, stdDev, coefficientOfVariation, slope, correlation

    var label: String {
        switch self {
        case .mean: "mean"
        case .median: "median"
        case .stdDev: "standard deviation"
        case .coefficientOfVariation: "coefficient of variation"
        case .slope: "per-day trend (slope)"
        case .correlation: "change-correlation"
        }
    }

    /// Readings this statistic needs to be DEFINED — a computability floor, never a worth judgment.
    /// A blanket `>= 3` used to gate every query, which silently made the most obvious follow-up in
    /// the app impossible: `unusualDays` and `eventWindow` hand the agent a specific strange day and
    /// the instructions tell it to chase that day, but a one-day window holds one reading, so
    /// "what was the actual value?" always came back unavailable. A mean of one reading IS that
    /// reading; only the spread statistics genuinely need more.
    var minimumSamples: Int {
        switch self {
        // A single day's mean or median is just that day's value — exactly the raw read an agent
        // needs when chasing a flagged day.
        case .mean, .median: 1
        // A *sample* SD divides by (n − 1), so two is the floor; CV is built from it.
        case .stdDev, .coefficientOfVariation: 2
        // A line needs two points.
        case .slope: 2
        // Paired change-correlations: enough overlap that r means anything at all.
        case .correlation: 5
        }
    }

    static let allRawValues: [String] = allCases.map(\.rawValue)
}

/// A day-set restriction an agent can apply to its query — so it can ask "…but only on Mondays" or
/// "…only on weekends", views the fixed `ComparisonKey` menu could never express.
nonisolated enum DayFilter: String, CaseIterable {
    case all, weekdays, weekends, mon, tue, wed, thu, fri, sat, sun

    var label: String {
        switch self {
        case .all: "all days"
        case .weekdays: "weekdays"
        case .weekends: "weekends"
        case .mon: "Mondays"
        case .tue: "Tuesdays"
        case .wed: "Wednesdays"
        case .thu: "Thursdays"
        case .fri: "Fridays"
        case .sat: "Saturdays"
        case .sun: "Sundays"
        }
    }

    /// Exhaustive, with no `default`. A filter that silently stops filtering is a failure this file
    /// has already had once — `correlate` used to ignore `dayFilter` entirely while still LABELLING
    /// its answer "weekends only", so an agent asking whether a link survived on weekends got the
    /// all-days number under a weekend heading. A `default` here would reintroduce that shape from
    /// the other direction: a new case (a locale-aware weekend, say — the open question in
    /// ARCHITECTURE) would have fallen through to the single-weekday branch and compared against a
    /// weekday number of 0, which no day equals — quietly excluding EVERY day.
    func allows(_ day: Date, _ calendar: Calendar) -> Bool {
        // Calendar.weekday: 1 = Sunday … 7 = Saturday.
        let weekday = calendar.component(.weekday, from: day)
        return switch self {
        case .all: true
        case .weekdays: !calendar.isDateInWeekend(day)
        case .weekends: calendar.isDateInWeekend(day)
        case .sun: weekday == 1
        case .mon: weekday == 2
        case .tue: weekday == 3
        case .wed: weekday == 4
        case .thu: weekday == 5
        case .fri: weekday == 6
        case .sat: weekday == 7
        }
    }

    static let allRawValues: [String] = allCases.map(\.rawValue)
}

/// A resolved, agent-defined analysis view. The window is the day range `[toDaysAgo … fromDaysAgo]`
/// (anchored on the last complete day), optionally restricted to `dayFilter`.
nonisolated struct AnalysisSpec: Equatable {
    let metric: MetricKey
    let secondaryMetric: MetricKey
    let statistic: AnalysisStatistic
    let fromDaysAgo: Int
    let toDaysAgo: Int
    let dayFilter: DayFilter
    let lag: Int
}

nonisolated struct AnalysisOutcome: Equatable {
    let value: Double
    let sampleCount: Int
    let available: Bool
    let description: String

    /// A query that cannot be answered, with the honest reason — never a fabricated zero.
    static func unavailable(_ reason: String) -> AnalysisOutcome {
        AnalysisOutcome(value: 0, sampleCount: 0, available: false, description: reason)
    }
}

/// Evaluates an agent-defined `AnalysisSpec` over the (whole, today-excluded) daily
/// series. This is the engine behind the `analyze` tool — it lets agents define **their own views** of
/// the data (any window, any day-filter, any statistic, custom-window correlations) instead of picking
/// from a fixed menu. Pure and unit-tested; the numbers are deterministic, so an agent that defines a
/// view still can only *ask for* a number, never invent one.
nonisolated enum AnalysisQueryEngine {
    /// The resolved day range a query runs over, bundled so the branches that need all of it take
    /// one parameter instead of four. `label` is the phrasing every outcome describes itself with,
    /// built once at the top so the reported window can never disagree with the computed one.
    private struct Window {
        let calendar: Calendar
        let start: Date
        let end: Date
        let label: String
    }

    /// Schema-side ceiling for agent-defined windows (rides in the `analyze` tool's `.range`
    /// guides). NOT an analysis horizon — the data is unbounded (ingestion reaches each metric's
    /// earliest HealthKit sample) and 20 years comfortably exceeds any possible history (HealthKit
    /// began in 2014); the `coverage` tool tells the agent how far back the real data goes.
    static let maxDaysAgo = 7300

    // One dispatch over the statistic kinds — branchy by nature, like HealthTypeMapping's unit map.
    // swiftlint:disable:next cyclomatic_complexity
    static func evaluate(_ spec: AnalysisSpec, series: [DailySeries], now: Date) -> AnalysisOutcome {
        let calendar = Calendar.civil
        // Anchor on the last COMPLETE day, matching every other detector's "exclude today" invariant.
        let anchor = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let from = max(spec.fromDaysAgo, spec.toDaysAgo)
        let to = min(spec.fromDaysAgo, spec.toDaysAgo)
        let windowStart = calendar.date(byAdding: .day, value: -from, to: anchor)!
        let windowEnd = calendar.date(byAdding: .day, value: -to, to: anchor)!
        let filterLabel = spec.dayFilter == .all ? "" : ", \(spec.dayFilter.label) only"
        let windowLabel = "days \(to)–\(from) ago\(filterLabel)"
        let window = Window(
            calendar: calendar, start: windowStart, end: windowEnd, label: windowLabel
        )

        guard let values = series.first(where: { $0.metric == spec.metric })?.values else {
            return .unavailable("No data for \(spec.metric.displayName).")
        }

        if spec.statistic == .correlation {
            return correlate(spec, values: values, series: series, window: window)
        }

        let points = values
            .filter { $0.key >= windowStart && $0.key <= windowEnd && spec.dayFilter.allows($0.key, calendar)
            }
            .sorted { $0.key < $1.key }
        let xs = points.map(\.value)
        guard xs.count >= spec.statistic.minimumSamples else {
            return .unavailable(
                "Not enough data for \(spec.statistic.label) of \(spec.metric.displayName) over "
                    + "\(windowLabel) — \(xs.count) reading\(xs.count == 1 ? "" : "s"), needs "
                    + "\(spec.statistic.minimumSamples)."
            )
        }

        let value: Double = switch spec.statistic {
        case .mean: MetricStatsProvider.mean(xs)
        case .median: RegimeShiftScan.median(xs)
        case .stdDev: MetricStatsProvider.sampleStandardDeviation(xs)
        case .coefficientOfVariation:
            MetricStatsProvider.mean(xs) == 0
                ? 0
                : MetricStatsProvider.sampleStandardDeviation(xs) / abs(MetricStatsProvider.mean(xs))
        case .slope:
            // Regressed against each reading's DAY OFFSET, not its position in the array, so the
            // statistic is genuinely "per day" as its label claims. Position-based regression is only
            // equivalent when readings are consecutive and unfiltered — with gaps in the history, or
            // under a dayFilter (Mondays are 7 days apart), it silently returns a per-READING slope
            // and overstates the trend by the spacing factor. These are exactly the long-horizon,
            // gappy, day-filtered queries the multi-year-drift lens asks for.
            slope(x: points.map { $0.key.timeIntervalSince(windowStart) / 86400 }, y: xs)
        case .correlation: 0 // handled above
        }
        // Exhaustive: a statistic in the metric's own units must be FORMATTED in them, and one that
        // is dimensionless (a ratio, a per-day slope) must not be — a new case inheriting the wrong
        // branch would show "8.5e+03" where "8,500 steps" belongs, or stamp a unit on a bare ratio.
        // The agent quotes this string, so the choice is not cosmetic.
        let shown = switch spec.statistic {
        case .mean, .median: MetricFormatting.canonical(value, spec.metric)
        case .stdDev, .coefficientOfVariation, .slope, .correlation: String(format: "%.3g", value)
        }
        return AnalysisOutcome(
            value: value, sampleCount: xs.count, available: true,
            description: "\(spec.statistic.label) of \(spec.metric.displayName) over \(windowLabel) = \(shown)"
        )
    }

    /// The change-correlation branch, lifted out of `evaluate` so each stays inside its length
    /// limit — the paired-alignment logic (lag targeting, day-filtering the LEAD day, chronological
    /// ordering) is a self-contained job and reads better on its own.
    private static func correlate(
        _ spec: AnalysisSpec,
        values: [Date: Double],
        series: [DailySeries],
        window: Window
    ) -> AnalysisOutcome {
        let calendar = window.calendar
        let windowStart = window.start
        let windowEnd = window.end
        let windowLabel = window.label
        guard spec.secondaryMetric != spec.metric,
              let other = series.first(where: { $0.metric == spec.secondaryMetric })?.values
        else { return .unavailable("A correlation needs two different metrics.") }
        let changesA = CorrelationEngine.winsorize(CorrelationEngine.firstDifferences(values))
        let changesB = CorrelationEngine.winsorize(CorrelationEngine.firstDifferences(other))
        var xs: [Double] = [], ys: [Double] = []
        // Chronological, never dictionary order: `pearson` sums the paired arrays in the order
        // built, and Swift's dictionary iteration order isn't stable across equal dictionaries —
        // so the same window could return a marginally different r between identical calls.
        //
        // `dayFilter` is applied to the LEAD day (the day of the first metric's change), which is
        // what "correlate these on Mondays only" means when a lag is in play. It used to be
        // skipped entirely here while `windowLabel` still announced it — so an agent asking
        // "does this link survive on weekends?" got the all-days number labelled "weekends only",
        // and proposed (or replicated) a finding on a claim the engine never tested.
        for (day, deltaA) in changesA.sorted(by: { $0.key < $1.key })
            where day >= windowStart && day <= windowEnd && spec.dayFilter.allows(day, calendar)
        {
            // `lag` is the only `calendar.date(byAdding:)` offset in the app that comes from the
            // MODEL rather than from a constant, and it is bounded by a `.range(0...7)` guide alone
            // — which constrains generation without promising anything about the argument that
            // arrives. Foundation does in fact absorb `Int.max`/`Int.min` here (verified in
            // `EngineFinitenessTests`), but that is undocumented behaviour to be force-unwrapping on
            // a shipping path. No target day simply means no pair.
            let shifted = spec.lag == 0
                ? day
                : calendar.date(byAdding: .day, value: spec.lag, to: day)
            guard let shifted else { continue }
            let target = spec.lag == 0 ? day : calendar.startOfDay(for: shifted)
            if let deltaB = changesB[target] { xs.append(deltaA); ys.append(deltaB) }
        }
        guard xs.count >= AnalysisStatistic.correlation.minimumSamples,
              let r = CorrelationEngine.pearson(xs, ys)
        else {
            return .unavailable(
                "Not enough overlapping days to correlate \(spec.metric.displayName) and "
                    + "\(spec.secondaryMetric.displayName) over \(windowLabel)."
            )
        }
        let timing = spec.lag == 0 ? "same-day" : "\(spec.metric.displayName) leading by \(spec.lag)d"
        return AnalysisOutcome(
            value: r, sampleCount: xs.count, available: true,
            description: "\(timing) change-correlation of \(spec.metric.displayName) & "
                + "\(spec.secondaryMetric.displayName) over \(windowLabel) = \(String(format: "%.2f", r))"
        )
    }

    /// OLS slope of `y` regressed on `x` — the estimator alone, so the caller decides what `x` means
    /// (the query path passes day offsets, making the result units-per-day).
    static func slope(x: [Double], y: [Double]) -> Double {
        let n = Double(y.count)
        guard n >= 2, x.count == y.count else { return 0 }
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXX = x.reduce(0) { $0 + $1 * $1 }
        let sumXY = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = n * sumXX - sumX * sumX
        return denominator == 0 ? 0 : (n * sumXY - sumX * sumY) / denominator
    }
}
