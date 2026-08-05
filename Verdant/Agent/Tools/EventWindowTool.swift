import Foundation
import FoundationModels

/// A **logical tool** that answers the one question the investigator is explicitly told to ask and
/// could not afford: *"what else moved around day X?"*
///
/// `unusualDays` hands the agent a strange day, and the instructions say to chase what else happened
/// near it — but doing that with `analyze` costs one call per metric (~72), against a four-call
/// budget the 4k window forces. So the most valuable follow-up in the whole tool surface was, in
/// practice, unreachable.
///
/// It needs no new computation. `UnusualDaysScan` already tests EVERY day of EVERY metric against
/// that metric's own robust baseline, and the substrate memoizes the whole ranked pool — this is a
/// view over numbers already sitting in memory: filter to the window, keep each metric's strongest
/// day, rank. One call replaces seventy-two. 100% local.
///
/// Honest limitation, stated in the tool's own description: it can only report metrics that reached
/// the sweep's 2σ bar near that day. A metric that drifted mildly will not appear, and the agent is
/// told so rather than left to read absence as evidence.
nonisolated struct EventWindowTool: Tool {
    let name = "eventWindow"
    /// Deliberately terse: tool SCHEMAS dominate this session's prefix (the six-tool surface is
    /// ~1,900 of the ~2,048-token bound `TokenHarnessTests` pins), so every word here is taken from
    /// the exploration itself. The one thing worth the tokens is the limitation — without it an agent
    /// reads a metric's absence as evidence it held steady.
    let description = "What ELSE moved around a given day. Give daysAgo (e.g. from unusualDays) and "
        + "a radius; returns the metrics most unusual near it, strongest first — one call instead of "
        + "one per metric. Only metrics ≥2σ near that day appear; absence is not evidence of no change."

    /// The row cap, stated once: it was written three times — in the guide's prose, in the
    /// `.range`, and in the clamp — and transcriptions like that are what silently disagree.
    static let maxMetrics = 8
    /// Days either side of the anchor day the window may span.
    static let maxRadius = 7

    @Generable nonisolated struct Arguments {
        @Guide(description: "Centre day, in days ago (0 = most recent complete day)")
        let daysAgo: Int
        @Guide(
            description: "Days either side to include (0 = that day alone)",
            .range(0...EventWindowTool.maxRadius)
        )
        let radius: Int
        @Guide(
            description: "Max metrics to return (1-\(EventWindowTool.maxMetrics))",
            .range(1...EventWindowTool.maxMetrics)
        )
        let limit: Int
    }

    /// The per-run cache — the every-data-point sweep this reads was computed once for the whole run.
    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> UnusualDaysResult {
        let radius = max(0, min(Self.maxRadius, arguments.radius))
        let limit = max(1, min(Self.maxMetrics, arguments.limit))
        let near = await substrate.unusualDays()
            .filter { abs($0.daysAgo - arguments.daysAgo) <= radius }

        // One row per metric — its most extreme day inside the window — so a single metric having a
        // rough week can't crowd out the cross-signal picture the agent asked for.
        var strongestPerMetric: [MetricKey: UnusualDay] = [:]
        for day in near {
            let standing = strongestPerMetric[day.metric]
            if abs(day.zScore) > abs(standing?.zScore ?? 0) { strongestPerMetric[day.metric] = day }
        }
        // Metric key breaks |z| ties: dictionary iteration order is not stable across equal
        // dictionaries, and an unstable sort would otherwise let the same window return a different
        // set past `limit` from one call to the next.
        let ranked = strongestPerMetric.values
            .sorted {
                abs($0.zScore) != abs($1.zScore)
                    ? abs($0.zScore) > abs($1.zScore)
                    : $0.metric.rawValue < $1.metric.rawValue
            }
            .prefix(limit)

        let days = ranked.map {
            UnusualDayLead(
                metric: $0.metric.rawValue,
                daysAgo: $0.daysAgo,
                zScore: $0.zScore.toolRounded,
                basis: $0.basis
            )
        }
        // A different silence from `unusualDays`': this window was asked about specifically, so
        // finding nothing in it is a fact about the window rather than about the metric.
        return UnusualDaysResult(
            days: Array(days),
            note: days.isEmpty
                ? "Nothing in the other metrics stood out around those days. They moved as usual "
                + "while this one did not."
                : ""
        )
    }
}
