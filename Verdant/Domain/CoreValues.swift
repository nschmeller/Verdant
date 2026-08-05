import Foundation

/// Direction of a change, recent vs. baseline.
nonisolated enum Direction: String, Codable {
    case up, down, flat

    var word: String {
        switch self {
        case .up: "higher"
        case .down: "lower"
        case .flat: "about the same"
        }
    }
}

/// Coarse magnitude bucket, carried on a persisted `VerifiedFact`.
///
/// It is no longer what any agent sees. The `HealthDigest` used to render these as adverbs —
/// "moderately higher" — and that is where the bucketing did real damage, so the digest now renders
/// the figures themselves (`HealthDigest.renderedText`). The `adverb` property went with it rather
/// than lingering as the kind of dead helper the next author assumes is load-bearing.
nonisolated enum MagnitudeBucket: String, Codable {
    case slight, moderate, large
}

/// Category of an insight. `none` means "not worth surfacing". `redFlag` is retained only as a
/// reserved raw value (the app no longer produces deterministic clinical findings) so persisted
/// rows and the closed model vocabulary stay stable.
/// `CaseIterable` so a test can sweep every kind. Without it, a suite checking "each kind renders
/// something a person can read" has to list the cases by hand — and a hand-written list is blind to
/// exactly the case that gets added later, which is the failure mode `FindingPresentation` exists to
/// stop.
nonisolated enum InsightKind: String, Codable, CaseIterable {
    case trend, anomaly, correlation, milestone, redFlag, volatility, regimeShift, seasonal, none

    /// Values the on-device model is allowed to choose from for a single-metric lead. Deliberately
    /// excludes `correlation`/`milestone`/`regimeShift` — those are produced only by their own
    /// detectors, and letting the Analyst claim them would route a lead to a false card template.
    static let modelFacingRawValues: [String] = ["trend", "anomaly", "none"]

    /// The finding kinds the agentic investigator may propose. Every kind is resolved from the shared
    /// stat substrate at persist time (the agent names it; the numbers come from the engine), so unlike
    /// `modelFacingRawValues` this spans all card types the agent can now surface itself.
    static let investigatorFacingRawValues: [String] =
        ["trend", "anomaly", "correlation", "volatility", "milestone", "regimeShift", "seasonal"]
}

/// The single numeric-truth value for one (metric, comparison). Computed only by
/// `MetricStatsProvider`; consumed by the Analyst's tool (as a slim digest), the
/// deterministic engine, and the persist-time resolve — so they cannot disagree.
nonisolated struct MetricStat: Equatable {
    let metric: MetricKey
    let comparison: ComparisonKey
    /// Mean of the recent window.
    let recent: Double
    /// Mean of the baseline window.
    let baseline: Double
    /// `(recent - baseline) / baseline * 100`; `0` when baseline is `0`.
    let pctChange: Double
    /// `(recent - baseline) / baselineSD`; effect size in baseline standard deviations.
    let z: Double
    /// Sample standard deviation of baseline daily values.
    let baselineSD: Double
    let recentCount: Int
    let baselineCount: Int
    /// `false` when either window is too small or the baseline has no spread.
    let confident: Bool

    /// Conservative sample count used by minimum-sample gating.
    var n: Int {
        min(recentCount, baselineCount)
    }

    var direction: Direction {
        let delta = recent - baseline
        let rel = baseline == 0 ? 0 : abs(delta) / abs(baseline)
        guard rel >= 0.01 else { return .flat }
        return delta > 0 ? .up : .down
    }
}

/// A change that has passed deterministic verification (fidelity-to-aggregate,
/// materiality, novelty). Only these numbers — never the model's claims — are persisted
/// or displayed.
nonisolated struct VerifiedFact {
    let metric: MetricKey
    let comparison: ComparisonKey
    let recent: Double
    let baseline: Double
    let pctChange: Double
    let z: Double
    let n: Int
    let kind: InsightKind
    let direction: Direction
    let magnitude: MagnitudeBucket
    /// Salience 0–100 used for ranking and archival. Clamped on construction.
    let salience: Int

    /// Confirmed statistics phrased for the adversarial skeptic so its "is this just noise?" judgment
    /// is grounded in the real effect size, not the prose alone.
    var verifiedBasis: String {
        String(
            format: "A ~%.0f%% shift versus baseline over %d days, about %.1f standard deviations "
                + "from this metric's typical movement.",
            pctChange, n, abs(z)
        )
    }
}

/// A compact (≤ ~300-token) snapshot of recent movement across all metrics. This is the
/// only whole-picture view the LLM ever sees; raw time series never cross the boundary.
nonisolated struct HealthDigest {
    nonisolated struct Entry {
        let metric: MetricKey
        /// The horizon this movement was measured over (recent, year-over-year, all-time, …) so the
        /// model can reason across time and isn't biased toward only this week's changes.
        let comparison: ComparisonKey
        /// The move in the metric's own terms, signed. Its sign is the direction.
        let pctChange: Double
        /// The same move in standard deviations of the baseline — the figure the digest is SORTED by,
        /// and the only one that compares across metrics.
        let z: Double
        let sampleCount: Int
    }

    let entries: [Entry]
    /// Kinds of insights surfaced recently, so Discovery avoids re-treading them.
    let recentInsightKinds: [String]

    /// Renders to terse lines the model can read cheaply, e.g.
    /// `- Steps: +18.4% (2.1 SD, n=90) vs. a year ago`.
    ///
    /// Figures, not adverbs. This used to read `Steps: moderately higher (vs. a year ago)`, bucketing
    /// the standardized move at 1.5 and 3 — so 1.6 and 2.9 arrived identical, as did 3.0 and 12.0.
    /// The digest is the first thing a scout or an investigator reads and the only whole-picture view
    /// any agent gets; it is SORTED by |z| and then hid the sort key, leaving the agent unable to
    /// rank within a bucket or to see that the top line was in a different league from the second.
    /// Choosing what counts as a big move is the agent's job here, and it needs the number to do it.
    ///
    /// The buckets were there so "the model can't quote numbers it wasn't given". That reasoning is
    /// spent: `NumericFidelity` now checks every figure in a finding's prose against the verified
    /// ones and hands the mismatches to the skeptic panel, and the agent already receives raw numbers
    /// from `metricStats`, `analyze`, `unusualDays` and `correlationScan` — this one tool's silence
    /// never made the session number-free, only this view number-blind.
    func renderedText() -> String {
        var lines = entries.map { entry in
            // One decimal throughout: a 0.4% move must not render as "+0%", and the extra character
            // on a large move is cheaper than the reader wondering which figures were rounded.
            let pct = String(format: "%+.1f%%", entry.pctChange)
            let sd = String(format: "%.1f", abs(entry.z))
            return "- \(entry.metric.displayName): \(pct) (\(sd) SD, n=\(entry.sampleCount)) "
                + "\(entry.comparison.displayName)"
        }
        if !recentInsightKinds.isEmpty {
            lines.append("Recently surfaced: \(recentInsightKinds.joined(separator: ", ")).")
        }
        return lines.isEmpty ? "No notable changes across any horizon." : lines.joined(separator: "\n")
    }
}
