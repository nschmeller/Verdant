import Foundation

// MARK: - Milestone

/// A record extreme: the latest rolling 7-day stretch of a metric is its highest (or lowest) in a
/// long span — "your best week of resting heart rate in 8 months." A milestone the level/trend
/// comparisons can't express, and a genuinely motivating, couldn't-compute-it-yourself finding.
nonisolated struct Milestone: Equatable, Identifiable {
    let metric: MetricKey
    /// The latest 7-day mean that set the record.
    let recentMean: Double
    /// `true` = record high, `false` = record low.
    let isHigh: Bool
    /// How far back the record stands, in days.
    let spanDays: Int
    /// Fractional margin by which the record beats the prior best/worst (0.08 = beat it by 8%) —
    /// the statistical-strength term distinguishing a decisive record from one squeaking past.
    let relativeMargin: Double
    /// A change of recording source inside the span this record compares over — see
    /// `RegimeShift.sourceChangeNote`. The most alarming of the three to get wrong: "your highest
    /// 7-day weight ever" is exactly what a new scale reading two pounds heavy produces, and the
    /// record is then a record against a field measured by different equipment.
    var sourceChangeNote: String?

    var id: String {
        metric.rawValue
    }

    /// Confirmed statistics phrased for the adversarial skeptic (grounds the "is it decisive?" lens).
    /// States the margin and span plainly — marginal and short-span records surface too, so the
    /// agent reads these two numbers and judges clear-vs-marginal and month-vs-week itself.
    var verifiedBasis: String {
        // The record's own VALUE. Every other kind's basis states the figure its claim is about —
        // the regime prints "from X to Y", volatility both standard deviations, a season its swing in
        // real units — and this one printed a margin and a span and never said what the record WAS.
        // The most human part of "your highest week ever" is the number, the persist route already
        // passes `recentMean` to the fidelity check so prose quoting it is supported, and the agent
        // had no way to learn it short of spending one of four tool calls looking it up.
        let core = String(
            format: "A record %@ 7-day stretch at %@: beats the prior extreme by %.1f%% and has "
                + "stood for %d days.",
            isHigh ? "high" : "low",
            MetricFormatting.canonical(recentMean, metric),
            relativeMargin * 100,
            spanDays
        )
        guard let sourceChangeNote else { return core }
        return "\(core) Caveat: \(sourceChangeNote)."
    }
}
