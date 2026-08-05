import Foundation
import FoundationModels

// MARK: - The tool surface each session carries

/// Every session's tool set, named rather than written inline at the point of use.
///
/// The reason is that a prompt names its tools BY HAND — `Instructions.explorer` says "use
/// eventWindow", `Instructions.answerer` lists all seven of its own. Nothing connects those
/// sentences to the array a session is actually constructed with, and the two drifted:
/// `Instructions.explorer` is shared by the investigator's explore pass and by Ask's gather pass,
/// which had different tool sets, so the Ask pass was told to reach for a tool it did not carry —
/// one wasted call out of a permitted four, on the user-facing path, in exactly the "a day looks
/// strange" case the sentence describes.
///
/// `SessionToolsTests` pins that every tool a role's prompt names is one that role holds. That check
/// needs the sets to be nameable, which is what this file is for; the duplication it removes between
/// `investigate` and `answer` is a bonus.
nonisolated extension Subagents {
    /// The investigator's commit pass: the six that measure the user's own data.
    func investigatorTools(_ substrate: AnalysisSubstrate) -> [any Tool] {
        [
            MetricStatsTool(substrate: substrate),
            CorrelationScanTool(substrate: substrate),
            PatternScanTool(substrate: substrate),
            MetricsOverviewTool(
                digestBuilder: HealthDigestBuilder(provider: provider, writer: writer),
                substrate: substrate
            ),
            AnalyzeTool(substrate: substrate),
            UnusualDaysTool(substrate: substrate)
        ]
    }

    /// The investigator's EXPLORE pass. It alone among the discovery sessions gets `eventWindow`:
    /// "what else moved around this strange day" is the most valuable single measurement in the
    /// surface and belongs to the pass whose whole job is measuring. Keeping it off the commit
    /// session is also what makes it affordable — that session's prefix already sits near the bound
    /// `TokenHarnessTests` pins, while these shorter instructions leave room for the extra schema.
    /// It does NOT carry `provenance`, though the doubt it raises belongs to exactly this pass.
    /// Adding the schema measured the explore prefix at 2,210 tokens against the 2,048 the harness
    /// allows — so the evidence reaches this pass the way `suspectedDeviceSwap` already does, woven
    /// into the `patternScan` regime basis it reads anyway (`RegimeShift.sourceChangeNote`). That
    /// costs nothing in the prefix and nothing on rows with no change to report, and it puts the
    /// caveat in the same sentence as the claim rather than behind a call the agent must think to
    /// make. The tool itself goes where there IS headroom: the replication analyst.
    func explorerTools(_ substrate: AnalysisSubstrate) -> [any Tool] {
        investigatorTools(substrate) + [EventWindowTool(substrate: substrate)]
    }

    /// The scout SURVEYS rather than tests, so it reads the map — where data exists, what is strange,
    /// what links and patterns are already visible — and deliberately carries neither `analyze` nor
    /// `metricStats`: computing a specific view is the investigator's job, not a surveyor's.
    func scoutTools(_ substrate: AnalysisSubstrate) -> [any Tool] {
        [
            MetricsOverviewTool(
                digestBuilder: HealthDigestBuilder(provider: provider, writer: writer),
                substrate: substrate
            ),
            CoverageTool(substrate: substrate),
            UnusualDaysTool(substrate: substrate),
            CorrelationScanTool(substrate: substrate),
            PatternScanTool(substrate: substrate)
        ]
    }

    /// The armed replication analyst re-computes ONE claim a different way: the custom view, the
    /// outlier check, provenance, and the anchored metric vocabulary.
    ///
    /// This surface was deliberately kept to two tools once, on the theory that headroom was what a
    /// re-test needed. It wasn't — five runs of headroom bought five runs of nothing, for the reason
    /// spelled out on `replicatorTools` below. Room to work is worth nothing to an agent that cannot
    /// name the thing it is working on.
    ///
    /// It carries `provenance` too. Re-computing a claim a different way cannot detect a device swap
    /// — every recomputation of the same rollups reproduces it faithfully, because the shift is
    /// really in the data — and a replication analyst that agrees with itself on an artifact is the
    /// exact failure this tool answers.
    ///
    /// Not the only hint available to it, which an earlier version of this note claimed: an
    /// `unusualDays` row's basis already carries the co-jump SUSPICION for a day the sweep flagged.
    /// The difference is what provenance adds — a record rather than an inference, for any metric on
    /// any day, including the single-metric swaps (a new scale, a new phone) that co-jumping vitals
    /// structurally cannot reveal.
    /// And it carries `metricStats` for one reason that outranks the numbers it returns: it is the
    /// app's ONLY tool whose metric argument is `.anyOf(MetricKey.allRawValues)`.
    ///
    /// Measured across five runs against the real model, this panel completed **zero** re-tests. The
    /// analysts' own words: `res`, `restingHear`, `resting_heart_rate`, `Heart rate`. Not one is a
    /// guess at a different metric — they are truncations, a snake_case spelling, and a display name
    /// of the metric they were asked about. Every tool it held then — analyze, unusualDays,
    /// provenance — took a free-generated `metric: String`, so the panel had no path to a key it
    /// could not mangle, and every failure arrived as "could not run this check."
    ///
    /// Three prompt-level fixes were tried first — naming the exact keys in the lens, listing the
    /// available metrics, naming the near miss in the tool's reply — and none moved it, because
    /// prompt text does not constrain generation. A closed vocabulary in the SCHEMA does. Adding it
    /// here also puts the correct spelling of every key in the session prefix, which is the anchor
    /// the free-generated `analyze` calls never had.
    ///
    /// It reduces the mangling rather than ending it, which is worth being exact about: the panel
    /// went from 0 of 5 analysts completing a re-test to 5 of 5 on the first run after, but a later
    /// run still produced one "No data for Heart rate." out of five. An anchored list in the prefix
    /// is a strong hint; only `.anyOf` on the argument itself is a constraint, and `analyze.metric`
    /// still has none.
    ///
    /// Closing that gap needs a replicator-only `analyze` type, because the current one is shared
    /// with the investigator at 2,037 of 2,048 tokens. The budget, re-measured after this session's
    /// prompt changes: this role sits at 1,848 with 200 spare, and the `MetricKey` vocabulary is
    /// roughly 400 tokens, so a constrained `analyze` does not fit ALONGSIDE `metricStats` — it fits
    /// only by replacing it (1,848 - 576 + ~400 = ~1,672), which trades the preset-window numbers for
    /// a key the model cannot misspell. A real trade with a real cost on both sides, so it is the
    /// owner's call, not a cleanup.
    ///
    /// Those figures read 1,765 and 283 spare for most of a day, and the paragraph was wrong by 83
    /// tokens within hours of being written: widening `couldTest` and adding the judge-the-claim
    /// clause grew this role's INSTRUCTIONS from 328 tokens to 411, and nothing connects a prompt
    /// edit to a budget recorded in a comment beside the tool array. `TokenHarnessTests` prints the
    /// live table on every run — trust that over any number written here, including these.
    func replicatorTools(_ substrate: AnalysisSubstrate) -> [any Tool] {
        [
            AnalyzeTool(substrate: substrate),
            UnusualDaysTool(substrate: substrate),
            ProvenanceTool(substrate: substrate),
            MetricStatsTool(substrate: substrate)
        ]
    }

    /// The research director reads history, not data: its one tool is the cross-run journal.
    func directorTools(now: Date) -> [any Tool] {
        [ResearchJournalTool(writer: writer, now: now)]
    }

    /// The Q&A answering pass — the investigator's six plus search over past findings.
    func answererTools(_ substrate: AnalysisSubstrate, now: Date) -> [any Tool] {
        investigatorTools(substrate)
            + [InsightSearchTool(writer: writer, embeddings: embeddings, now: now)]
    }

    /// Ask's GATHER pass carries exactly `explorerTools` — the same prompt AND the same tools as the
    /// investigator's explore pass, which is what makes the shared instructions true rather than
    /// merely plausible.
    ///
    /// It used to carry `insightSearch` instead of `eventWindow`, and that was wrong in both
    /// directions: the prompt told it to use `eventWindow` (which it lacked), while `insightSearch`
    /// searches PAST FINDINGS — context for composing an answer, not a measurement of the user's
    /// data, and the pass's whole instruction is "MEASURE, not conclude". Carrying both does not fit:
    /// measured at 2,118 tokens against the 2,048 the harness allows. Splitting them by job fits,
    /// costs nothing, and the answering pass keeps `insightSearch` where it belongs.
    func askGatherTools(_ substrate: AnalysisSubstrate) -> [any Tool] {
        explorerTools(substrate)
    }
}
