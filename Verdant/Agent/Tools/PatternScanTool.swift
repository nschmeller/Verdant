import Foundation
import FoundationModels

/// The single-metric pattern detectors, as one vocabulary. The `.anyOf` guide and the values
/// `patternScan` actually emits are both derived from this: they were separate string literals, so
/// nothing but proofreading kept the schema the model is shown and the data it receives in
/// agreement. Declaration order is the order the model sees.
nonisolated enum PatternKind: String, CaseIterable {
    case volatility, milestone, regime, seasonal

    static let allRawValues = allCases.map(\.rawValue)
}

/// One detected single-metric pattern (volatility shift, record milestone, regime shift or annual
/// rhythm) with a human-readable, already-computed basis line. The investigator agent reads these; it never
/// derives
/// the statistics itself.
@Generable nonisolated struct DetectedPattern {
    @Guide(description: "Metric key") let metric: String
    @Guide(description: "Pattern kind", .anyOf(PatternKind.allRawValues)) let kind: String
    @Guide(description: "The confirmed statistics behind it, in plain language") let basis: String
}

@Generable nonisolated struct PatternScanResult {
    @Guide(description: "Detected single-metric patterns beyond simple mean changes")
    let patterns: [DetectedPattern]
}

/// A **logical tool** the investigator agent calls to surface single-metric patterns the mean
/// comparisons structurally can't see: a metric grown more/less erratic (volatility), a record 7-day
/// stretch (milestone), or a sustained step to a new baseline (regime). Each detector is a pure,
/// unit-tested engine; the tool just runs them and hands the agent the numbers. 100% local.
nonisolated struct PatternScanTool: Tool {
    let name = "patternScan"
    /// Terser than it reads: this tool's schema rides in the investigator's prefix, which measured
    /// exactly at the 2,048-token bound when `seasonal` was added. Every clause here is budget taken
    /// from the exploration itself.
    let description = "Single-metric patterns beyond averages: volatility shifts, record milestones, "
        + "regime shifts, and annual rhythms (months that repeat high or low yearly). Returns real, "
        + "already-computed numbers; never calculate your own."

    /// The row cap, stated once: it was written three times — in the guide's prose, in the
    /// `.range`, and in the clamp — and transcriptions like that are what silently disagree.
    static let maxPerKind = 3
    /// Rows the whole response may carry, across every kind — see `interleaved`.
    static let maxTotal = 9

    @Generable nonisolated struct Arguments {
        /// Ceiling of 3 per kind (9 patterns max), not 12 (36 max): each basis line is a full
        /// sentence (~35 tokens), and a maxed-out call was ~1,400 tokens of the 4,096-token
        /// window — a top contributor to real on-device overflows. Detectors sort strongest-first.
        @Guide(
            description: "Max patterns of each kind to return (1-\(PatternScanTool.maxPerKind))",
            .range(1...PatternScanTool.maxPerKind)
        )
        let perKind: Int
    }

    /// The per-run cache — each scan is computed once and reused across every call and pass.
    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> PatternScanResult {
        let cap = max(1, min(Self.maxPerKind, arguments.perKind))
        // Grouped by kind, then interleaved below. Each detector already sorts strongest-first, so
        // taking a prefix takes the best of that kind.
        var byKind: [[DetectedPattern]] = []
        await byKind.append(substrate.volatility().prefix(cap).map {
            DetectedPattern(
                metric: $0.metric.rawValue,
                kind: PatternKind.volatility.rawValue,
                basis: $0.verifiedBasis
            )
        })
        await byKind.append(substrate.milestones().prefix(cap).map {
            DetectedPattern(
                metric: $0.metric.rawValue,
                kind: PatternKind.milestone.rawValue,
                basis: $0.verifiedBasis
            )
        })
        await byKind.append(substrate.regimes().prefix(cap).map {
            DetectedPattern(
                metric: $0.metric.rawValue,
                kind: PatternKind.regime.rawValue,
                basis: $0.verifiedBasis
            )
        })
        await byKind.append(substrate.seasonality().prefix(cap).map {
            DetectedPattern(
                metric: $0.metric.rawValue,
                kind: PatternKind.seasonal.rawValue,
                basis: $0.verifiedBasis
            )
        })
        return PatternScanResult(patterns: Self.interleaved(byKind))
    }

    /// Round-robin across the kinds, up to `maxTotal`.
    ///
    /// A per-kind cap alone used to bound the whole response, because the number of kinds was fixed.
    /// Adding `seasonal` would have raised the worst case from 9 rows to 12 — a third more of the
    /// single biggest contributor to the on-device overflows this document records. A total cap keeps
    /// the worst case exactly where it was, so a new detector buys DIVERSITY inside the same token
    /// budget rather than spending more of it.
    ///
    /// Round-robin rather than concatenation for the same reason `patternScan` sorts strongest-first:
    /// a flat truncation would drop whole kinds by declaration order, so `seasonal` — last in the
    /// enum and the rarest to be computable — would be the one never seen. Interleaving spends the
    /// budget on breadth across kinds and lets each kind's own ranking decide what within it.
    static func interleaved(_ groups: [[DetectedPattern]]) -> [DetectedPattern] {
        var out: [DetectedPattern] = []
        var index = 0
        while out.count < maxTotal, groups.contains(where: { index < $0.count }) {
            for group in groups where index < group.count && out.count < maxTotal {
                out.append(group[index])
            }
            index += 1
        }
        return out
    }
}
