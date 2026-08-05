import Foundation

/// The auditable numbers line under a finding card, as a pure function of the stored row.
///
/// Every kind stores DIFFERENT meanings in the same four columns. `verifiedRecent` is a new baseline
/// for a regime shift, a record-setting 7-day mean for a milestone, a standard deviation for a
/// volatility shift and a month effect in SDs for an annual rhythm; `sampleCount` is variously days
/// held, days a record leads, days measured and YEARS observed. Nothing in the type system says so.
/// The contract lives in a comment beside the writer and a matching comment beside the renderer, in
/// different files, and a finding that reads its own columns wrongly prints real numbers under a
/// false label — the most convincing way this app could lie to someone.
///
/// It was unreachable by tests until now: the switch sat inside a `private func -> some View` on a
/// SwiftUI card, so the only thing that could catch a mismatch was a person reading both files. Pure
/// and separate, each kind's reading of its own columns is pinned by `FindingCardLineTests`.
///
/// The exhaustive switch is deliberate for the reason `FindingPresentation` documents at length: a
/// `default` over a closed enum silently gives a new kind some other kind's treatment, and that bug
/// has already shipped here once.
nonisolated enum FindingCardLine {
    /// The four shared columns plus the window, named as a group precisely because their MEANING is
    /// what varies by kind. Passing them individually made a seven-argument call whose arguments are
    /// only distinguishable by position — the shape most likely to get two of them swapped.
    struct Columns {
        let verifiedRecent: Double
        let verifiedBaseline: Double
        let verifiedPctChange: Double
        let sampleCount: Int
        let comparison: ComparisonKey?
    }

    static func text(kind: InsightKind?, metric: MetricKey, columns: Columns) -> String {
        let recent = MetricFormatting.formatted(columns.verifiedRecent, metric)
        let baseline = MetricFormatting.formatted(columns.verifiedBaseline, metric)
        let sampleCount = columns.sampleCount
        switch kind ?? .trend {
        case .regimeShift:
            // verifiedRecent/Baseline hold the new vs. prior baseline; sampleCount how long it's held.
            return "New baseline ~\(recent) (was ~\(baseline)) · held \(sampleCount) days"
        case .milestone:
            // verifiedRecent holds the record-setting 7-day mean; sampleCount the span it leads.
            return "\(recent) · a record over the past ~\(sampleCount) days"
        case .volatility:
            // verifiedRecent/Baseline hold the recent vs. baseline standard deviation (day-to-day swing).
            let change = MetricFormatting.signedPercent(columns.verifiedPctChange)
            return "Day-to-day swing: ±\(recent) vs ±\(baseline) · \(change) variability · \(sampleCount) days"
        case .seasonal:
            // verifiedRecent/Baseline hold the peak and opposite months' effects in SDs — deliberately
            // NOT rendered through `MetricFormatting`, which would print "+1.2 bpm" for what is a
            // standardised score. `verifiedPctChange` holds the swing in the metric's OWN units, which
            // is the figure a person can actually judge, and sampleCount the years behind it. The
            // months themselves live in the prose the agent wrote.
            let swing = MetricFormatting.formatted(columns.verifiedPctChange, metric)
            return "Repeats yearly: \(swing) between its high and low months · across \(sampleCount) years"
        case .trend, .anomaly, .correlation, .redFlag, .none:
            // `displayName` ("vs. your recent norm") is a SUFFIX, not a connective — slotting it into
            // "X <window> vs Y" produced a garbled double-"vs". Use the recent/baseline labels, which
            // read cleanly (and unambiguously) for every comparison, incl. the categorical weekday one.
            let recentLabel = columns.comparison?.recentLabel ?? "recently"
            let baselineLabel = columns.comparison?.baselineLabel ?? "usual"
            return "\(recent) (\(recentLabel)) vs \(baseline) (\(baselineLabel)) · "
                + "\(MetricFormatting.signedPercent(columns.verifiedPctChange)) · \(sampleCount) days"
        }
    }

    /// The call the card makes. Separate from the above so the switch can be exercised without a
    /// SwiftData container, while the row's own columns are still read in exactly one place.
    static func text(for insight: InsightLog, metric: MetricKey) -> String {
        text(
            kind: insight.insightKind,
            metric: metric,
            columns: Columns(
                verifiedRecent: insight.verifiedRecent,
                verifiedBaseline: insight.verifiedBaseline,
                verifiedPctChange: insight.verifiedPctChange,
                sampleCount: insight.sampleCount,
                comparison: insight.comparisonKey
            )
        )
    }
}
