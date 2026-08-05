import Foundation
import SwiftData

/// The single source of numeric truth — meaning the single source of the DATA, which is the part
/// that is actually guaranteed.
///
/// This said "every statistic the app surfaces … is computed here", and that was never true of the
/// engine scans: `RegimeShiftScan` computes Cohen's d, pooled standard deviations and medians,
/// `VolatilityScan` coefficients of variation, `SeasonalityScan` de-trended residuals — none of them
/// here. Someone chasing a wrong figure in a finding would have come looking in this file, and the
/// arithmetic they wanted would have been three directories away.
///
/// What IS true, and is enforced by `NumericTruthSourceTests`: this actor is the only reader of
/// `MetricRollup` in the app. Every statistic anywhere — this actor's own comparisons, every engine
/// scan, every persist-time recheck — derives from one set of daily rollups read through one actor,
/// so no two of them can be looking at different days. They can still tell different stories about
/// the same days; that is what the panels are for.
///
/// The comparisons this actor does own reduce to a (recent values, baseline values) partition of
/// those rollups; the same `computeStat` then derives mean, %change, and a z-score (effect size in
/// baseline standard deviations) uniformly.
@ModelActor
actor MetricStatsProvider {
    // Read horizon: ALL ingested history. There is deliberately no day floor on any analysis
    // read — findings must not be recency-biased, `recentVsAllTime` should mean genuinely
    // all-time, and ingestion backfills from each metric's EARLIEST HealthKit sample. Volume is
    // bounded by reality: HealthKit begins in 2014, so even a maximal history is a few thousand
    // daily rollups per metric.

    func stat(for metric: MetricKey, comparison: ComparisonKey, now: Date = .now) throws -> MetricStat {
        let values = try dailyValues(for: metric, now: now)
        let (recent, baseline) = Self.partition(values: values, comparison: comparison, now: now)
        return Self.computeStat(metric: metric, comparison: comparison, recent: recent, baseline: baseline)
    }

    /// String-keyed entry point for the Analyst's tool, where metric/comparison arrive as raw
    /// model output. Returns `nil` if the model somehow named something outside the vocabulary.
    func stat(forRaw metricRaw: String, comparisonRaw: String, now: Date = .now) throws -> MetricStat? {
        guard let metric = MetricKey(rawValue: metricRaw),
              let comparison = ComparisonKey(rawValue: comparisonRaw) else { return nil }
        return try stat(for: metric, comparison: comparison, now: now)
    }

    /// Every metric × comparison — the full cross-product the deterministic scan walks.
    func scanAll(now: Date = .now) throws -> [MetricStat] {
        var out: [MetricStat] = []
        out.reserveCapacity(MetricKey.allCases.count * ComparisonKey.allCases.count)
        for metric in MetricKey.allCases {
            let values = try dailyValues(for: metric, now: now)
            for comparison in ComparisonKey.allCases {
                let (recent, baseline) = Self.partition(values: values, comparison: comparison, now: now)
                out.append(Self.computeStat(
                    metric: metric,
                    comparison: comparison,
                    recent: recent,
                    baseline: baseline
                ))
            }
        }
        return out
    }

    /// Aligned daily series for every metric that has data, over the ENTIRE ingested history — the
    /// substrate ALL detectors run on (correlations, volatility, milestones, regime shifts), so
    /// associations and drifts can emerge across every season and year on record. Metrics with no
    /// rollups are omitted. Today's rollup is EXCLUDED: it's still accumulating, so a partial day
    /// would distort a latest-window mean/SD or fake a record/regime step — the same "anchor on the
    /// last complete day" invariant the mean-comparison partition honors. (Detectors that take
    /// `now` and re-anchor are then simply consistent with the substrate they're handed.)
    func dailySeries(now: Date = .now) throws -> [DailySeries] {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        var out: [DailySeries] = []
        for metric in MetricKey.allCases {
            let raw = metric.rawValue
            let descriptor = FetchDescriptor<MetricRollup>(
                predicate: #Predicate { $0.metric == raw && $0.dayStart < today }
            )
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { continue }
            var values: [Date: Double] = [:]
            for row in rows {
                values[calendar.startOfDay(for: row.dayStart)] = row.dayValue(for: metric)
            }
            out.append(DailySeries(metric: metric, values: values))
        }
        return out
    }

    /// Per metric, which HealthKit sources produced each stored day — the input to `ProvenanceScan`.
    ///
    /// A second pass over the same rows `dailySeries` reads, rather than a field on `DailySeries`:
    /// that type is the numeric substrate every scan and correlation runs on, and threading a string
    /// through it would put provenance in the hot path of code that never looks at it.
    ///
    /// The cost is one extra pass over the same rows per SUBSTRATE BUILD — not per tool call, and not
    /// per pass. Worth stating at its real scale rather than as "one extra fetch": there is no
    /// backfill cap (see `Ingestor`), so a long-standing user's rollup table is every tracked metric
    /// times every day since their HealthKit history began — order 10^5 rows. It is affordable
    /// because a build happens at a pass boundary and `precompute` runs it behind generation, not
    /// because it is small.
    func sourceHistory(now: Date = .now) throws -> [SourceHistory] {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        var out: [SourceHistory] = []
        for metric in MetricKey.allCases {
            let raw = metric.rawValue
            let descriptor = FetchDescriptor<MetricRollup>(
                predicate: #Predicate { $0.metric == raw && $0.dayStart < today }
            )
            var signatures: [Date: String] = [:]
            for row in try modelContext.fetch(descriptor) where !row.sourceSignature.isEmpty {
                signatures[calendar.startOfDay(for: row.dayStart)] = row.sourceSignature
            }
            guard !signatures.isEmpty else { continue }
            out.append(SourceHistory(metric: metric, signatures: signatures))
        }
        return out
    }

    /// Sorted daily points for one metric over the last `days` — the data behind sparklines and the
    /// dual-line correlation charts. Excludes today's still-accumulating partial day, matching
    /// `dailySeries`: the correlation chart is documented as plotting "the same signal the coefficient
    /// was computed on," and the coefficient runs on the today-excluded substrate — so the chart must
    /// exclude it too, and a partial last point would misrepresent a level sparkline regardless.
    func recentSeries(for metric: MetricKey, days: Int = 30, now: Date = .now) throws -> [DailyPoint] {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -days, to: today)!
        let raw = metric.rawValue
        let descriptor = FetchDescriptor<MetricRollup>(
            predicate: #Predicate { $0.metric == raw && $0.dayStart >= from && $0.dayStart < today },
            sortBy: [SortDescriptor(\.dayStart)]
        )
        return try modelContext.fetch(descriptor).map {
            DailyPoint(day: calendar.startOfDay(for: $0.dayStart), value: $0.dayValue(for: metric))
        }
    }

    private func dailyValues(for metric: MetricKey, now _: Date) throws -> [(day: Date, value: Double)] {
        let calendar = Calendar.civil
        let raw = metric.rawValue
        // No day floor: `recentVsAllTime` means ALL time. The partition's window filters (all
        // anchored on the last complete day) bound every other comparison.
        //
        // Sorted, and it matters. An unsorted fetch returns rows in an order the store does not
        // promise, `partition` preserves that order into its arrays, and `mean` /
        // `sampleStandardDeviation` then sum in it — so the SAME data could yield last-ULP-different
        // means, percent changes and z-scores depending on how rows came back. Those figures are
        // what gets persisted onto a finding and shown to the user, and this is the one numeric-truth
        // source they all pass through. Same reasoning as the chronological reads in the scan
        // engines; the database does the ordering for free.
        let descriptor = FetchDescriptor<MetricRollup>(
            predicate: #Predicate { $0.metric == raw },
            sortBy: [SortDescriptor(\.dayStart)]
        )
        return try modelContext.fetch(descriptor).map {
            (calendar.startOfDay(for: $0.dayStart), $0.dayValue(for: metric))
        }
    }

    // MARK: - Pure statistics (nonisolated: no actor state, callable from anywhere)

    nonisolated static func partition(
        values: [(day: Date, value: Double)],
        comparison: ComparisonKey,
        now: Date
    ) -> (recent: [Double], baseline: [Double]) {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        // Anchor on the last COMPLETE day: today is partial, and for cumulative metrics a partial
        // day would drag the recent mean down and manufacture a spurious "decrease".
        let anchor = calendar.date(byAdding: .day, value: -1, to: today)!
        func daysAgo(_ count: Int) -> Date {
            calendar.date(byAdding: .day, value: -count, to: anchor)!
        }

        switch comparison {
        case .recentVsBaseline:
            let recentCut = daysAgo(6), baseStart = daysAgo(36), baseEnd = daysAgo(7)
            return (
                values.filter { $0.day >= recentCut && $0.day <= anchor }.map(\.value),
                values.filter { $0.day >= baseStart && $0.day <= baseEnd }.map(\.value)
            )
        case .weekOverWeek:
            let recentCut = daysAgo(6), priorStart = daysAgo(13), priorEnd = daysAgo(7)
            return (
                values.filter { $0.day >= recentCut && $0.day <= anchor }.map(\.value),
                values.filter { $0.day >= priorStart && $0.day <= priorEnd }.map(\.value)
            )
        case .weekdayVsWeekend:
            // ~90 days so the weekend side isn't ~4 noisy points; weekdays/weekends alternate
            // evenly through the window, so any slow trend averages out of both sides.
            let windowStart = daysAgo(89)
            let window = values.filter { $0.day >= windowStart && $0.day <= anchor }
            return (
                window.filter { !calendar.isDateInWeekend($0.day) }.map(\.value),
                window.filter { calendar.isDateInWeekend($0.day) }.map(\.value)
            )
        case .yearOverYear:
            // Last 90 days vs. the same 90-day window one year earlier (seasonal/annual change).
            let recentCut = daysAgo(89)
            let baseStart = daysAgo(454), baseEnd = daysAgo(365)
            return (
                values.filter { $0.day >= recentCut && $0.day <= anchor }.map(\.value),
                values.filter { $0.day >= baseStart && $0.day <= baseEnd }.map(\.value)
            )
        case .recentVsAllTime:
            // Last 30 days vs. the entire prior history (the long-term norm).
            let recentCut = daysAgo(29), baselineEnd = daysAgo(30)
            return (
                values.filter { $0.day >= recentCut && $0.day <= anchor }.map(\.value),
                values.filter { $0.day <= baselineEnd }.map(\.value)
            )
        }
    }

    /// Minimum sample counts for a comparison to be trustworthy. These are comparison-specific:
    /// week-over-week and weekday/weekend baselines are inherently small windows, so a flat 14-day
    /// baseline minimum (right for recent-vs-baseline) would make them permanently non-confident.
    nonisolated static func requiredSamples(
        for comparison: ComparisonKey,
        rule: MetricRule
    ) -> (recent: Int, baseline: Int) {
        switch comparison {
        case .recentVsBaseline: (rule.minRecentSamples, rule.minBaselineSamples)
        case .weekOverWeek: (4, 4)
        case .weekdayVsWeekend: (20, 8)
        case .yearOverYear: (21, 21)
        case .recentVsAllTime: (14, 30)
        }
    }

    nonisolated static func computeStat(
        metric: MetricKey,
        comparison: ComparisonKey,
        recent: [Double],
        baseline: [Double]
    ) -> MetricStat {
        let recentMean = mean(recent)
        let baselineMean = mean(baseline)
        let baselineSD = sampleStandardDeviation(baseline)
        let pct = baselineMean == 0 ? 0 : (recentMean - baselineMean) / baselineMean * 100
        // `z` is a standardized *effect size*: how many baseline daily standard deviations the
        // recent mean sits from the baseline mean. It is not a sampling z / p-value; materiality
        // pairs it with a minimum effect size as a conservative strength heuristic, not formal FWER.
        let z = baselineSD == 0 ? 0 : (recentMean - baselineMean) / baselineSD
        let rule = MetricCatalog.rule(for: metric)
        let required = requiredSamples(for: comparison, rule: rule)
        let confident = recent.count >= required.recent
            && baseline.count >= required.baseline
            && baselineSD > 0
        return MetricStat(
            metric: metric,
            comparison: comparison,
            recent: recentMean,
            baseline: baselineMean,
            pctChange: pct,
            z: z,
            baselineSD: baselineSD,
            recentCount: recent.count,
            baselineCount: baseline.count,
            confident: confident
        )
    }

    nonisolated static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    nonisolated static func sampleStandardDeviation(_ xs: [Double]) -> Double {
        guard xs.count >= 2 else { return 0 }
        let m = mean(xs)
        let variance = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return variance.squareRoot()
    }
}
