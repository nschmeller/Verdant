import Foundation

/// What a user-requested drill-down is anchored on: the metric (or pair) and title of the finding
/// they tapped. The focused lenses are built from this, so the whole investigator fleet digs around
/// ONE thing instead of sweeping everything.
nonisolated struct InvestigationFocus {
    /// The title rides into the focused fleet's lens prompts, so it is clamped here rather than at
    /// the point of use. Every other model-written string reaching a prompt is bounded before it
    /// gets there — `provenanceLine` (90/160), `leadLenses` (200/40), `directorLenses` (200),
    /// `composedChallenges` (220), the feed digest (50) — because the on-device window is 4,096
    /// tokens and an overlong string does not produce a wrong answer, it kills the session
    /// mid-exploration. This path was the exception: `title` is the model-written `oneTapTitle`,
    /// guided toward a "3-6 word headline" but not structurally bounded, and a guide constrains
    /// GENERATION rather than promising anything about the string that was stored. Clamping in the
    /// initializer covers all four construction sites at once, and any future one for free.
    static let maxTitleLength = 80

    let metric: MetricKey
    let secondaryMetric: MetricKey?
    let title: String

    init(metric: MetricKey, secondaryMetric: MetricKey?, title: String) {
        self.metric = metric
        self.secondaryMetric = secondaryMetric
        self.title = String(title.prefix(Self.maxTitleLength))
    }
}

// MARK: - Focused drill-down ("tap a finding → investigate further")

nonisolated extension Orchestrator {
    /// A user-requested drill-down seeded by ONE finding on the feed: the same agentic machinery —
    /// investigator fleet, skeptic panel, safety panel, novelty gates — but every lens is pointed at
    /// the tapped finding's metric (or pair) instead of sweeping everything. Returns the count of
    /// new findings it surfaced.
    @discardableResult
    func runFocusedDiscovery(
        focus: InvestigationFocus,
        now: Date = .now,
        progress: ProgressReporter? = nil
    ) async -> Int {
        await progress?.apply { $0.phase = .scanning }
        guard capability().isAvailable else {
            await progress?.apply {
                $0.phase = .finished
                $0.note = "Couldn't run: on-device intelligence isn't available right now."
            }
            return 0
        }
        subagents.prewarm()
        let loaded = await Orchestrator.loadSeries(provider, now: now)
        let substrate = AnalysisSubstrate(provider: provider, series: loaded.series, now: now)
        await substrate.precompute() // scans run while the model warms — see AnalysisSubstrate
        // The load note comes FIRST when there is nothing to work from: a drill-down that opens
        // "Digging into …" and then finds nothing reads as "your finding did not survive", which is
        // a different and more alarming statement than "the history could not be read".
        if loaded.series.isEmpty {
            await progress?.log(loaded.note)
        }
        await progress?.log(
            "Digging into “\(focus.title)” — \(focus.metric.displayName) from every angle"
        )
        let ctx = DiscoveryContext(
            jobID: UUID(),
            now: now,
            deadline: nil,
            progress: progress,
            substrate: substrate,
            adversarial: true
        )
        let produced = await runInvestigation(ctx, lenses: Self.focusedLenses(focus))
        await progress?.apply { $0.phase = .synthesizing }
        await curate(now: now)
        let closing = produced > 0
            ? "\(produced) new finding\(produced == 1 ? "" : "s") from the drill-down."
            : "The drill-down held up what you already know — nothing new cleared the bar."
        await progress?.apply { $0.phase = .finished; $0.note = closing }
        return produced
    }

    /// The drill-down's lens fleet: the general investigation angles, each re-anchored on the tapped
    /// finding's metric(s) — plus one lens whose whole job is to try to knock the finding down.
    static func focusedLenses(_ focus: InvestigationFocus) -> [String] {
        let name = focus.metric.displayName
        let pair = focus.secondaryMetric.map { " and \($0.displayName)" } ?? ""
        return [
            "what LEADS or FOLLOWS \(name)\(pair) — sweep lags with correlationScan and analyze to find "
                + "the strongest lead-lag partners around it",
            "the LONG view of \(name)\(pair) — analyze slope/mean over 365-day and longer windows "
                + "across its full history for multi-year drifts this finding may sit inside",
            "the day-structure of \(name) — weekdays vs weekends vs single days (analyze dayFilter): "
                + "does the pattern live on particular days?",
            "the character of \(name) — volatility and regime shifts (patternScan, analyze "
                + "stdDev/coefficientOfVariation): did it change nature, not just level?",
            "challenge the finding “\(focus.title)” — hunt for disconfirming evidence or a stronger "
                + "alternative explanation; propose only what genuinely survives or supersedes it"
        ]
    }
}
