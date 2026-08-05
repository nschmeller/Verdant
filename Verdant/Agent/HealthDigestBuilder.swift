import Foundation

/// Builds the compact `HealthDigest` that is the only whole-picture view the model ever sees. Per
/// metric it emits the signed percent move, the same move in standard deviations, the sample count
/// and the horizon — figures, not buckets. `HealthDigest.renderedText` carries the full reasoning
/// for that, including why the anti-quoting argument the buckets were built on no longer holds.
///
/// `sampleCount` was on the entry all along and was never rendered — collected, carried, dropped.
///
/// Crucially, the default digest spans **multiple time horizons** (recent, year-over-year,
/// all-time), and a `focus` lens can pin it to one — so the discovery agent reasons across years
/// and isn't biased toward only what moved this week.
nonisolated struct HealthDigestBuilder {
    let provider: MetricStatsProvider
    let writer: StoreWriter

    /// Overall cap on digest lines — keeps it compact even across many metrics × horizons.
    private static let maxEntries = 14
    /// Per-horizon cap before the overall trim.
    private static let perComparison = 6

    /// `stats` lets a caller pass a precomputed `scanAll()` result. The metric movements it derives are
    /// identical for a given `now` (the rollups don't change mid-run), so the Deep Analysis loop computes
    /// `scanAll` ONCE and reuses it across all passes/lenses instead of re-scanning the full multi-year
    /// history ~160× — only the cheap `recentInsightKinds` (which evolves as findings accumulate) is
    /// re-read each build.
    func build(
        focus: ComparisonKey? = nil,
        now: Date = .now,
        stats: [MetricStat]? = nil
    ) async -> HealthDigest {
        let allStats: [MetricStat] = if let stats {
            stats
        } else {
            await (try? provider.scanAll(now: now)) ?? []
        }
        let comparisons = focus.map { [$0] } ?? [.recentVsBaseline, .yearOverYear, .recentVsAllTime]

        let byComparison: [[HealthDigest.Entry]] = comparisons.map { comparison in
            allStats
                .filter { $0.comparison == comparison && $0.confident && $0.recentCount > 0 }
                .sorted { abs($0.z) > abs($1.z) } // biggest movers first
                .prefix(Self.perComparison)
                .map { stat in
                    HealthDigest.Entry(
                        metric: stat.metric,
                        comparison: comparison,
                        pctChange: stat.pctChange,
                        z: stat.z,
                        sampleCount: stat.recentCount
                    )
                }
        }

        // Interleave by rank across horizons (recent #1, year-over-year #1, all-time #1, recent #2, …)
        // so the overall `maxEntries` cap trims every horizon EVENLY. Appending one horizon fully
        // before the next would let the recent lens fill the budget and starve the long-horizon lens —
        // the recency bias the multi-horizon digest exists to avoid.
        let entries = Self.roundRobin(byComparison)

        let kinds = await (try? writer.recentInsightKinds(now: now)) ?? []
        return HealthDigest(entries: Array(entries.prefix(Self.maxEntries)), recentInsightKinds: kinds)
    }

    /// Flatten rank-sorted columns by taking each column's #1, then each #2, and so on. A later
    /// "keep the first N" trim then removes the weakest rank from every column roughly evenly,
    /// rather than emptying the last column first. Pure and generic so the fairness is unit-tested.
    static func roundRobin<T>(_ columns: [[T]]) -> [T] {
        var out: [T] = []
        let deepest = columns.map(\.count).max() ?? 0
        for rank in 0..<deepest {
            for column in columns where rank < column.count {
                out.append(column[rank])
            }
        }
        return out
    }
}
