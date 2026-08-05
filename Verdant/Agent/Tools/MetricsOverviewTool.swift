import Foundation
import FoundationModels

/// A **logical tool** the investigator agent calls first to get the lay of the land: a compact,
/// multi-horizon summary of how every metric has moved (this week, vs. a year ago, all-time), as the
/// signed percent move with its size in standard deviations and the days behind it. This is the same
/// `HealthDigest` the old logical workflow pushed into Discovery; now the agent pulls it on demand.
/// 100% local.
///
/// It used to return magnitude BUCKETS and no figures. See `HealthDigest.renderedText`.
nonisolated struct MetricsOverviewTool: Tool {
    let name = "metricsOverview"
    /// Every word here is paid three times — the investigator, explorer and answerer all carry this
    /// tool, and all three sit within eighty tokens of the bound. Naming the figures cost more than
    /// "direction/magnitude buckets" did, so the closing sentence gave the tokens back.
    let description = "Multi-horizon overview of how the user's metrics have moved "
        + "(recent, vs. a year ago, all-time): percent change, size in SD, days behind it — biggest "
        + "movers first. Use it to pick which metrics and pairs to investigate."

    @Generable nonisolated struct Arguments {
        @Guide(description: "Leave empty; the overview spans all metrics and horizons") let unused: Bool
    }

    let digestBuilder: HealthDigestBuilder
    /// The per-run cache — `scanAll` (every metric × comparison) is computed once and reused.
    let substrate: AnalysisSubstrate

    func call(arguments _: Arguments) async throws -> String {
        let stats = await substrate.allStats()
        return await digestBuilder.build(now: substrate.now, stats: stats).renderedText()
    }
}
