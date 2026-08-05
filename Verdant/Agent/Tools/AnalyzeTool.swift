import Foundation
import FoundationModels

/// The result of an agent-defined analysis query — a single deterministic number plus a plain-language
/// statement of exactly what was computed, so the agent can quote it faithfully.
@Generable nonisolated struct QueryResult {
    @Guide(description: "Whether the query returned a usable result")
    let available: Bool
    @Guide(description: "The computed value")
    let value: Double
    @Guide(description: "How many days it was computed over")
    let sampleCount: Int
    @Guide(description: "A plain-language statement of exactly what was computed")
    let description: String
}

/// A **logical tool that lets the agent define its OWN view of the data** — the app's answer to "don't
/// give the agents a fixed set of views." Instead of picking from the 5 preset `ComparisonKey` windows,
/// the agent specifies a metric (or two, for a correlation), a statistic, a day window, an optional
/// day-filter, and a lag; the deterministic engine computes it and hands back real numbers. The agent
/// can define the view but never invent the number — it can only ask the engine for one. 100% local.
nonisolated struct AnalyzeTool: Tool {
    let name = "analyze"
    /// The statistic and dayFilter VALUES are deliberately not spelled out here — each argument's
    /// `.anyOf` guide already enumerates them verbatim to the model, and this session's prefix is
    /// pinned under half the 4k window by `TokenHarnessTests`. What the guides cannot express is
    /// SEMANTICS, so the budget is spent on that instead: slope's unit, and the fact that dayFilter
    /// reaches the correlation path (it silently didn't, while still being named in the result).
    let description = "Run a CUSTOM analysis query you design over the user's data — you define the view. "
        + "Pick a metric (or a second metric for a correlation), a statistic, a day window "
        + "(fromDaysAgo/toDaysAgo, 0 = most recent day), an optional dayFilter, and a lag for "
        + "correlations. slope is units per DAY; dayFilter applies to correlations too (on the leading "
        + "metric's day). Returns real, already-computed numbers — never calculate your own. Use "
        + "it to test views the standard tools can't express (e.g. a metric on Mondays only, a slope "
        + "over a custom span, or a correlation restricted to one window)."

    @Generable nonisolated struct Arguments {
        /// No .anyOf on either metric: with the full registry the vocabulary is heavy, and it already
        /// rides in this session once (metricStats.Arguments.metric — the anchored list the model picks
        /// from). The registry resolve in `call` rejects unknown keys, so nothing unverifiable gets a
        /// number; the token harness pins the session prefix under budget.
        @Guide(description: "The metric to analyze (exact metric key, as used by metricStats)")
        let metric: String
        /// No .anyOf: the registry resolve in `call` rejects unknown keys, and duplicating the full
        /// vocabulary here would bloat the session's context window.
        @Guide(
            description: "A second metric for a correlation (exact metric key); otherwise repeat the first metric"
        )
        let secondaryMetric: String
        @Guide(description: "The statistic to compute", .anyOf(AnalysisStatistic.allRawValues))
        let statistic: String
        @Guide(
            description: "Window start in days ago (0 = most recent complete day)",
            .range(0...AnalysisQueryEngine.maxDaysAgo)
        )
        let fromDaysAgo: Int
        @Guide(
            description: "Window end in days ago (0 = most recent complete day)",
            .range(0...AnalysisQueryEngine.maxDaysAgo)
        )
        let toDaysAgo: Int
        @Guide(description: "Restrict the window to these days", .anyOf(DayFilter.allRawValues))
        let dayFilter: String
        @Guide(
            description: "For a correlation, days the first metric leads the second (0 = same day)",
            .range(0...7)
        )
        let lag: Int
    }

    let substrate: AnalysisSubstrate

    /// Name the key the caller probably meant.
    ///
    /// Observed from the real model, in analysts' own verdicts: "No data for Heart rate." and "No
    /// data exists for the metric \"restingHear\"". Neither is a guess at a different metric — they
    /// are the display name and a TRUNCATION of the right key. `metric` deliberately carries no
    /// `.anyOf` (the full vocabulary would not fit the investigator's schema budget), so the model
    /// free-generates the string and mangles it, and the reply told it nothing it could act on.
    ///
    /// A near-miss is recoverable if the tool says what it was near. Matching is prefix-or-contains
    /// on a case- and separator-insensitive form, which covers both observed shapes: "restingHear"
    /// is a prefix of "restingHeartRate", and "Heart rate" normalises into it.
    static func suggestion(for metric: String, _ secondary: String) -> String {
        let candidates = [metric, secondary]
            .map { $0.lowercased().filter(\.isLetter) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else {
            return " Use the exact metric keys the other tools report."
        }
        let matches = MetricKey.allCases.filter { key in
            let flat = key.rawValue.lowercased()
            return candidates.contains { flat.hasPrefix($0) || flat.contains($0) || $0.contains(flat) }
        }
        guard !matches.isEmpty else {
            return " Use the exact metric keys the other tools report."
        }
        return " Did you mean " + matches.prefix(3).map(\.rawValue).joined(separator: ", ") + "?"
    }

    func call(arguments: Arguments) async throws -> QueryResult {
        // An omitted second metric means "this is a single-metric query", which is what the guide
        // asks for in a more demanding way: "otherwise repeat the first metric". A model that leaves
        // it blank has expressed exactly that intent, and rejecting it wins nothing — a correlation
        // asked for with no partner is caught below on the statistic, not here.
        let secondaryRaw = arguments.secondaryMetric.trimmingCharacters(in: .whitespaces)
        let secondaryKey = secondaryRaw.isEmpty ? arguments.metric : secondaryRaw

        // Say WHICH argument failed. "Invalid query parameters." names nothing, so an agent that gets
        // one convention wrong learns nothing from the answer and cannot correct itself — it reports
        // that it could not run the check. The replication panel completed ZERO re-tests across three
        // probes against the real model, and an uncorrectable dead end is the most likely mechanism.
        // (Also the mistake made while investigating that: `secondaryMetric: ""` was passed by hand,
        // and the tool's reply gave no hint what was wrong with it.)
        var invalid: [String] = []
        if MetricKey(rawValue: arguments.metric) == nil { invalid.append("metric “\(arguments.metric)”") }
        if MetricKey(rawValue: secondaryKey) == nil {
            invalid.append("secondaryMetric “\(secondaryRaw)”")
        }
        if AnalysisStatistic(rawValue: arguments.statistic) == nil {
            invalid.append("statistic “\(arguments.statistic)”")
        }
        if DayFilter(rawValue: arguments.dayFilter) == nil {
            invalid.append("dayFilter “\(arguments.dayFilter)”")
        }
        guard let metric = MetricKey(rawValue: arguments.metric),
              let secondary = MetricKey(rawValue: secondaryKey),
              let statistic = AnalysisStatistic(rawValue: arguments.statistic),
              let filter = DayFilter(rawValue: arguments.dayFilter)
        else {
            return QueryResult(
                available: false,
                value: 0,
                sampleCount: 0,
                description: "Not a valid query — unrecognised \(invalid.joined(separator: ", "))."
                    + Self.suggestion(for: arguments.metric, secondaryKey)
            )
        }
        let spec = AnalysisSpec(
            metric: metric,
            secondaryMetric: secondary,
            statistic: statistic,
            fromDaysAgo: arguments.fromDaysAgo,
            toDaysAgo: arguments.toDaysAgo,
            dayFilter: filter,
            lag: arguments.lag
        )
        let outcome = AnalysisQueryEngine.evaluate(spec, series: substrate.series, now: substrate.now)
        return QueryResult(
            available: outcome.available,
            value: outcome.value.toolRounded,
            sampleCount: outcome.sampleCount,
            description: outcome.description
        )
    }
}
