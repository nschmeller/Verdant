import Foundation
import FoundationModels

/// One flagged day, in the slim form the investigator reads. `daysAgo` plugs straight into
/// `analyze` windows, so a hypothesis about the day is one tool call away. `zScore` rides as a
/// number (not just prose) so the agent can weigh a borderline 2σ day against a wild 6σ one itself
/// — the numbers inform, the agents decide.
@Generable nonisolated struct UnusualDayLead {
    @Guide(description: "Metric key") let metric: String
    @Guide(description: "How many days ago it happened (use in analyze windows)") let daysAgo: Int
    @Guide(description: "Robust z-score (sign = direction, magnitude = strength; 2 is borderline)")
    let zScore: Double
    @Guide(description: "What happened that day, with the verified numbers") let basis: String
}

@Generable nonisolated struct UnusualDaysResult {
    @Guide(description: "The strangest single days on record, most extreme first")
    let days: [UnusualDayLead]
    /// What an EMPTY list means — empty itself when days were found.
    ///
    /// An empty array arrived with no statement of its meaning, and the meaning was invented.
    /// Measured 2026-08-03: replication analysts returned `holdsUp: true` on a claim the data flatly
    /// contradicts, with the entire reason "No unusual days detected". That reading is backwards. A
    /// clean step to a new level produces NO unusual days, because every day after it is normal FOR
    /// that level — so silence here is weak evidence FOR a sustained shift, and no evidence at all
    /// about whether one is real.
    ///
    /// Same shape as the zeroed `MetricStatDigest`, and the same fix: a result field costs nothing
    /// in prefix tokens (a tool's schema is its arguments), and agents demonstrably read a plain
    /// sentence beside the data where they ignore a flag.
    @Guide(description: "Empty when days were found; otherwise what finding none does and does not mean")
    let note: String
}

/// A **logical tool** exposing the every-data-point sweep: every day of every metric is tested
/// against that metric's own robust baseline, and the days that stand outside it come back as
/// hypothesis seeds, strongest first. The scan caches the FULL ranked pool (down to 2σ); this tool
/// bounds each call and pages deeper via `offset`, and the agent judges strength from the numeric
/// `zScore`. The agent's job is the hypothesis ("what else moved around that day?") — the numbers
/// are already computed. 100% local.
nonisolated struct UnusualDaysTool: Tool {
    let name = "unusualDays"
    let description = "The strangest single days on record, most extreme first (down to 2σ — judge "
        + "strength from zScore). Hypothesis seeds: chase what else moved near a flagged day via "
        + "analyze and daysAgo; offset pages deeper."

    /// The row cap, stated once: it was written three times — in the guide's prose, in the
    /// `.range`, and in the clamp — and transcriptions like that are what silently disagree.
    static let maxDays = 6

    @Generable nonisolated struct Arguments {
        @Guide(description: "Metric key to focus on, or \"all\" for every metric")
        let metric: String
        @Guide(
            description: "Max days to return (1-\(UnusualDaysTool.maxDays))",
            .range(1...UnusualDaysTool.maxDays)
        )
        let limit: Int
        @Guide(description: "Ranked days to skip (0 = first page)")
        let offset: Int?
    }

    /// The per-run cache — the sweep runs once and is reused across every call and pass.
    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> UnusualDaysResult {
        let all = await substrate.unusualDays()
        let filtered = arguments.metric == "all"
            ? all
            : all.filter { $0.metric.rawValue == arguments.metric }
        let offset = max(0, arguments.offset ?? 0)
        let page = filtered.dropFirst(offset).prefix(max(1, min(Self.maxDays, arguments.limit))).map {
            UnusualDayLead(
                metric: $0.metric.rawValue,
                daysAgo: $0.daysAgo,
                zScore: $0.zScore.toolRounded,
                basis: $0.basis
            )
        }
        // Three different silences, and only the first is about the data. Worded to be SAYABLE:
        // agents quote these fields verbatim, so an internal instruction would reach a user.
        let note = if !page.isEmpty {
            ""
        } else if filtered.isEmpty {
            "No single day stood out from its own baseline here. That is not evidence of "
                + "steadiness: a lasting shift to a new level produces no unusual days, because "
                + "every day after it is ordinary for that level."
        } else {
            "No further unusual days beyond the ones already listed."
        }
        return UnusualDaysResult(days: Array(page), note: note)
    }
}
