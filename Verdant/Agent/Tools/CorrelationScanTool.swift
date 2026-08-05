import Foundation
import FoundationModels

/// One discovered cross-metric association, in the slim form the investigator agent reads. Numbers
/// are already computed by `CorrelationEngine` — the model never derives them. Rows include
/// sub-threshold candidates on purpose: the engine produces the evidence (`pValue`, `significant`,
/// `consistentAcrossThirds`, `redundant`) and the agent judges what it's worth — the skeptic and
/// replication panels re-test whatever it proposes.
@Generable nonisolated struct DiscoveredCorrelation {
    @Guide(description: "First metric key") let metricA: String
    @Guide(description: "Second metric key") let metricB: String
    @Guide(description: "Days metricA precedes metricB (0 = same day)") let lagDays: Int
    @Guide(description: "Temporal direction: '<metric> leads by Nd', or 'same-day'") let leads: String
    @Guide(description: "Correlation of their day-to-day changes after removing activity, from -1 to 1")
    let coefficient: Double
    @Guide(description: "Two-sided p-value of the coefficient") let pValue: Double
    @Guide(description: "Whether it survived the false-discovery-rate correction") let significant: Bool
    @Guide(description: "Whether the direction held across thirds of the record")
    let consistentAcrossThirds: Bool
    /// One number, deliberately, rather than all three thirds: the transcript budget is the binding
    /// constraint on this tool and `coefficient` already gives the whole-record figure, so the newest
    /// third is the only addition that says something neither of them can. Compare the two and a
    /// faded link (0.40 overall, 0.04 lately) or a new one (0.20 overall, 0.61 lately) is visible at
    /// a glance; `consistentAcrossThirds` reports the first as consistent and the second as
    /// unreliable. All three thirds are stated in `verifiedBasis`, which costs no schema.
    @Guide(description: "Correlation over the most recent third only — compare with coefficient")
    let recentThirdCoefficient: Double
    @Guide(description: "Whether the pair is mechanically coupled (physics, not insight)")
    let redundant: Bool
    @Guide(description: "Effective independent days the coefficient rests on") let effectiveDays: Int
    @Guide(description: "Whether same-day activity was partialled out") let activityControlled: Bool

    /// Flatten an engine finding into a transcript row. The `leads` text makes the lag direction
    /// readable (`metricA` always leads by construction, but the model can't be expected to know
    /// that); numbers are rounded at the tool boundary (`toolRounded`) to spare transcript tokens.
    init(_ correlation: MetricCorrelation) {
        metricA = correlation.metricA.rawValue
        metricB = correlation.metricB.rawValue
        lagDays = correlation.lag
        leads = correlation.lag == 0
            ? "same-day"
            : "\(correlation.metricA.rawValue) leads by \(correlation.lag)d"
        coefficient = correlation.partialR.toolRounded
        pValue = correlation.pValue.toolRounded
        significant = correlation.significant
        consistentAcrossThirds = correlation.consistentAcrossThirds
        // Falls back to the overall figure when the record is too short to split, so the comparison
        // reads "unchanged" rather than "collapsed to zero" — a missing measurement must not look
        // like a measured absence.
        recentThirdCoefficient = (correlation.thirdsR.last ?? correlation.partialR).toolRounded
        redundant = correlation.mechanicallyRedundant
        effectiveDays = Int(correlation.nEff.rounded())
        activityControlled = correlation.activityControlled
    }
}

@Generable nonisolated struct CorrelationScanResult {
    @Guide(description: "Cross-metric associations, significant first then strongest first")
    let correlations: [DiscoveredCorrelation]
}

/// A **logical tool** the investigator agent calls to discover statistically-controlled associations
/// between the user's metrics. The engine (day-to-day changes, activity partialled out,
/// autocorrelation-corrected significance, one-test-per-pair FDR) does the arithmetic; the agent
/// reads the resulting numbers and decides what — if anything — is worth telling. Sub-threshold rows
/// are included deliberately: the flags carry the trust evidence, and the verification panels re-test
/// whatever the agent proposes. 100% local.
nonisolated struct CorrelationScanTool: Tool {
    let name = "correlationScan"
    let description = "Cross-metric associations, computed on day-to-day changes with activity "
        + "removed. Rows may be weak, lagged, or mechanically coupled — judge each by its pValue "
        + "and flags. Never calculate your own numbers."

    /// The row cap, stated once: it was written three times — in the guide's prose, in the
    /// `.range`, and in the clamp — and transcriptions like that are what silently disagree.
    static let maxRows = 6

    @Generable nonisolated struct Arguments {
        /// Ceiling of 6, not 20: every row costs ~85 transcript tokens, and a model told to be
        /// thorough picks the max — 20 rows would eat most of the 4,096-token window, a top
        /// contributor to real on-device overflows. The scan is sorted significant-first then
        /// strongest-first, so the head is where the findings live anyway.
        @Guide(
            description: "How many of the strongest associations to return "
                + "(1-\(CorrelationScanTool.maxRows))",
            .range(1...CorrelationScanTool.maxRows)
        )
        let limit: Int
    }

    /// The per-run cache — the scan is computed once and reused across every call and pass, so this
    /// tool returns instantly instead of re-crunching years of rollups while the model waits.
    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> CorrelationScanResult {
        let scan = await substrate.correlationScan()
        let top = scan.correlations.prefix(max(1, min(Self.maxRows, arguments.limit)))
            .map { DiscoveredCorrelation($0) }
        return CorrelationScanResult(correlations: Array(top))
    }
}
