import Foundation

/// The closed vocabulary of comparisons the agent may run on a metric. The set spans **short to
/// multi-year** horizons on purpose: findings must not be recency-biased, so the engine can ask
/// "how does this week compare to a year ago?" or "to my entire history?" just as easily as
/// "to last week".
///
/// Each comparison reduces to a partition of recent daily values vs. baseline daily values;
/// `MetricStatsProvider` computes every statistic uniformly from those two sets, so all consumers
/// (the stat tools, correlation/discovery passes) agree by construction.
nonisolated enum ComparisonKey: String, CaseIterable, Codable, Identifiable, Hashable {
    /// Last 7 days vs. the prior 30 days. The everyday "is this recent or normal?" test.
    case recentVsBaseline
    /// Last 7 days vs. the 7 days before them. Week-over-week movement.
    case weekOverWeek
    /// Weekday mean vs. weekend mean over the last ~90 days (enough weekends to be stable). Behavioural
    /// pattern.
    case weekdayVsWeekend
    /// Last 90 days vs. the same 90-day window one year earlier. Annual / seasonal change.
    case yearOverYear
    /// Last 30 days vs. the entire prior history. Recent state vs. the long-term norm.
    case recentVsAllTime

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .recentVsBaseline: "vs. your recent norm"
        case .weekOverWeek: "week over week"
        case .weekdayVsWeekend: "weekday vs. weekend"
        case .yearOverYear: "vs. a year ago"
        case .recentVsAllTime: "vs. all time"
        }
    }

    /// Human label for the baseline side, used in the auditable verified-numbers line under a finding
    /// and in the Q&A fact string handed to the model (not in finding prose, which is fully LLM-written).
    var baselineLabel: String {
        switch self {
        case .recentVsBaseline: "your 30-day average"
        case .weekOverWeek: "the previous week"
        case .weekdayVsWeekend: "weekends"
        case .yearOverYear: "the same period last year"
        case .recentVsAllTime: "your long-term norm"
        }
    }

    /// Human label for the recent side, used in the auditable verified-numbers line under a finding
    /// and in the Q&A fact string handed to the model (not in finding prose, which is fully LLM-written).
    var recentLabel: String {
        switch self {
        case .recentVsBaseline: "the past week"
        case .weekOverWeek: "this past week"
        case .weekdayVsWeekend: "weekdays"
        case .yearOverYear: "the past three months"
        case .recentVsAllTime: "the past month"
        }
    }

    static let allRawValues: [String] = allCases.map(\.rawValue)
}
