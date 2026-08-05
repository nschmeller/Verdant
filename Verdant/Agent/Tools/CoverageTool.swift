import Foundation
import FoundationModels

/// One metric's footprint, numeric-only: five small ints cost ~25–30 transcript tokens where a
/// prose sentence costs 35+ — and the scout only needs the shape, not the phrasing.
@Generable nonisolated struct CoverageRow {
    @Guide(description: "Metric key") let metric: String
    @Guide(description: "Days with an observation") let observedDays: Int
    @Guide(description: "Calendar span from first to last observation") let spanDays: Int
    @Guide(description: "Days ago the history starts") let firstDaysAgo: Int
    @Guide(description: "Days ago the latest observation is") let lastDaysAgo: Int
    @Guide(description: "Longest run of unobserved days inside the span") let largestGapDays: Int
}

@Generable nonisolated struct CoverageResult {
    @Guide(description: "Sparsest coverage first — the least-explored data")
    let metrics: [CoverageRow]
}

/// A **logical tool** exposing the map of the territory itself: what data EXISTS per metric, where
/// it starts and stops, and where the holes are. Every other tool reports patterns in the data that
/// is there and says nothing about the data that isn't — this is how a scout aims at unexplored
/// corners (thin metrics, old stretches, suspicious gaps) instead of re-walking the well-lit ones.
/// 100% local.
nonisolated struct CoverageTool: Tool {
    let name = "coverage"
    let description = "Reports each metric's data footprint — how many days exist, how far back "
        + "they reach, and the largest gap. Use it to find under-explored metrics, old stretches of "
        + "history, and holes worth explaining. Returns real, already-computed numbers."

    /// The row cap, stated once: it was written three times — in the guide's prose, in the
    /// `.range`, and in the clamp — and transcriptions like that are what silently disagree.
    static let maxMetrics = 6

    @Generable nonisolated struct Arguments {
        @Guide(
            description: "Max metrics to return (1-\(CoverageTool.maxMetrics)), sparsest first",
            .range(1...CoverageTool.maxMetrics)
        )
        let limit: Int
    }

    /// The per-run cache — the sweep runs once and is reused across every call and pass.
    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> CoverageResult {
        let all = await substrate.coverage()
        let rows = all
            .sorted { $0.density < $1.density }
            .prefix(max(1, min(Self.maxMetrics, arguments.limit)))
            .map {
                CoverageRow(
                    metric: $0.metric.rawValue,
                    observedDays: $0.observedDays,
                    spanDays: $0.spanDays,
                    firstDaysAgo: $0.firstDaysAgo,
                    lastDaysAgo: $0.lastDaysAgo,
                    largestGapDays: $0.largestGapDays
                )
            }
        return CoverageResult(metrics: Array(rows))
    }
}
