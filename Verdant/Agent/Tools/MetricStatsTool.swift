import Foundation
import FoundationModels
import OSLog

/// The Analyst's only tool. Returns already-computed statistics for one metric/comparison; the
/// model picks *which*, never receives raw samples, and never does arithmetic. The body is 100%
/// local (the `MetricStatsProvider` actor), preserving the zero-cloud guarantee.
nonisolated struct MetricStatsTool: Tool {
    private static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "MetricStatsTool")

    let name = "metricStats"
    let description = "Returns precomputed statistics for one health metric and comparison window. "
        + "The numbers are already calculated — use them as given; never compute your own."

    @Generable nonisolated struct Arguments {
        @Guide(description: "Metric key", .anyOf(MetricKey.allRawValues))
        let metric: String
        @Guide(description: "Comparison window", .anyOf(ComparisonKey.allRawValues))
        let comparison: String
    }

    /// Served from the per-run cache, not by re-querying. `scanAll` — memoized here and started
    /// before the first generation — is the FULL metric × comparison cross-product computed by the
    /// very same `computeStat`, so the answer is identical while the cost drops from "fetch this
    /// metric's whole history and recompute" to an in-memory lookup. That matters because this tool
    /// is called repeatedly *during* generation: every DB round-trip here is the Neural Engine
    /// waiting on the CPU. It also removes the chance of the tool's `now` drifting from the
    /// substrate the rest of the session reasons over — there is only one `now` now.
    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> MetricStatDigest {
        let stat = await substrate.allStats().first {
            $0.metric.rawValue == arguments.metric && $0.comparison.rawValue == arguments.comparison
        }
        // A digest with a REASON, not a throw and not a bare zero. Three things were measured here
        // on 2026-08-03, in this order.
        //
        // The tool returned `0/0/0/0, confident: false` for a metric with no data and the answerer
        // quoted it: "your body mass has remained stable at 0 over the past year". The source was not
        // the missing-row path below — `allStats()` MANUFACTURES a row for every (metric, comparison)
        // pair whether or not the metric has data, five bodyMass rows on a fixture with no body mass
        // at all, so the zeros arrived fully formed through the normal path.
        //
        // Throwing instead removed the number and killed the session: 5 answers of 5 came back empty,
        // because a thrown tool error is not recoverable here. An earlier check that "the session
        // survives a throw" was VACUOUS — that throw only covered out-of-vocabulary keys, which never
        // happen, so nothing was ever thrown in the run that certified it.
        //
        // What works is what `analyze` already does: `QueryResult` carries `available: false` beside
        // a plain-language `description`, and the agents demonstrably read it — "No data for Heart
        // rate" and "No data for Exercise minutes" appear verbatim in their own verdicts, where a
        // bare `confident: false` was quoted straight past. A result field costs no prefix tokens (a
        // tool's schema is its ARGUMENTS), which is what makes this affordable on a shared surface.
        //
        // The test is ABSENCE, not confidence: a stat with five real days is legitimately unconfident
        // and its numbers are still true; a stat with zero days has nothing to say.
        let hasData = stat.map { $0.recentCount > 0 || $0.baselineCount > 0 } ?? false
        guard let stat, hasData else {
            // Only an out-of-vocabulary key is an invariant violation. A valid pair with no data is
            // ordinary, and logging it as a violation filled the one log that should stay empty.
            if MetricKey(rawValue: arguments.metric) == nil
                || ComparisonKey(rawValue: arguments.comparison) == nil
            {
                Self.log.error("""
                metricStats called with out-of-vocabulary key: \
                \(arguments.metric, privacy: .public)/\(arguments.comparison, privacy: .public)
                """)
            }
            let metricName = MetricKey(rawValue: arguments.metric)?.displayName ?? arguments.metric
            // `baselineLabel`, not `displayName`: the display names are adverbial ("vs. a year
            // ago") and produced "There is no vs. a year ago data for Weight" when quoted. The
            // baseline labels are noun phrases and read as English in the same slot.
            let comparisonName = ComparisonKey(rawValue: arguments.comparison)?.baselineLabel
                ?? arguments.comparison
            return MetricStatDigest(
                metric: arguments.metric, comparison: arguments.comparison,
                baseline: 0, recent: 0, pctChange: 0, z: 0, dayCount: 0, confident: false,
                // Worded so that PARROTING it is acceptable prose. Measured: with the note phrased
                // as an internal instruction ("do not report them as values"), two answers in five
                // repeated it to the user verbatim, ALL-CAPS and all. An agent that quotes a tool
                // field is the behaviour being relied on here, so the field has to be sayable.
                // Display names for the same reason; the exact keys are echoed in `metric` and
                // `comparison` for a retry.
                note: "There is no \(metricName) data to compare against \(comparisonName) — "
                    + "nothing was measured, so there is no figure here, rather than a figure of zero."
            )
        }
        // Round at the boundary: full-precision doubles are ~10 transcript tokens each where 4
        // significant digits carry everything the model can use (see `toolRounded`).
        let digest = stat.digest
        return MetricStatDigest(
            metric: digest.metric,
            comparison: digest.comparison,
            baseline: digest.baseline.toolRounded,
            recent: digest.recent.toolRounded,
            pctChange: digest.pctChange.toolRounded,
            z: digest.z.toolRounded,
            dayCount: digest.dayCount,
            confident: digest.confident,
            note: ""
        )
    }
}
