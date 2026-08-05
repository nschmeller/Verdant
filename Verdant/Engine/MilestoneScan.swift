import Foundation

/// Detects **milestones** — when a metric's latest rolling 7-day stretch is its highest or lowest
/// in a long span. This produces the kind of finding a person can't compute by glancing at the
/// Health app ("your steadiest month of resting heart rate in over a year") and that nothing else
/// in the engine surfaces.
///
/// Pure and `nonisolated`. Only proposes candidates; the model still judges worth and narrates them.
/// Every TRUE record — the latest stretch strictly beyond the prior extreme — is emitted, however
/// marginal or short-lived: `relativeMargin` and `spanDays` carry the numbers, and the agent (backed
/// by the skeptic and replication panels) judges clear-vs-marginal and month-vs-week itself. The
/// numbers inform, the agents decide. The only remaining floors protect computability: a "record"
/// can't be computed without a prior history to beat.
nonisolated struct MilestoneScan {
    nonisolated struct Config {
        var window = 7
        /// Computability floor: a "record" means nothing without a real history to beat.
        var minHistoryDays = 120
        /// Computability floor: minimum rolling windows to compare against.
        var minWindows = 60
        /// The "comparably extreme" band used to measure how long a record has stood (`spanDays`).
        /// NOT a drop gate — marginal records still emit, carrying their `relativeMargin` for the
        /// agent to judge.
        var margin = 0.02
        /// A 7-entry window must span at most this many calendar days to count as a real "7-day
        /// stretch" — excludes sparsely-logged metrics whose windows span weeks.
        var maxWindowSpanDays = 10

        static let `default` = Config()
    }

    let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// `sourceChanges` annotate the records they could explain — see `Milestone.sourceChangeNote`.
    func scan(
        _ series: [DailySeries],
        now: Date = .now,
        sourceChanges: [SourceChange] = []
    ) -> [Milestone] {
        // Most decisive record first (margin over the prior best) — the same "strongest first"
        // convention as the volatility and regime scans. The orchestrator truncates to a per-run
        // budget with `.prefix`, so without this the bounded run would phrase whichever milestones
        // happen to come first in metric-iteration order and could skip the strongest records.
        let found = series.compactMap(detect).sorted { $0.relativeMargin > $1.relativeMargin }
        guard !sourceChanges.isEmpty else { return found }
        let calendar = Calendar.civil
        return found.map { milestone in
            // Two spans matter and the wider one is the window. `spanDays` is how long the record
            // has STOOD — a change inside it means the record and the field it beat were measured
            // differently. But `config.window` is the record itself: the rolling stretch whose mean
            // set it. A new scale used for exactly those days sets a record with no help from the
            // body, and because the windows overlap such a record typically stands only a day or
            // two — so keying on `spanDays` alone misses precisely the case this exists for. (That
            // is not hypothetical: it is what the wiring test caught.)
            let reach = max(milestone.spanDays, config.window)
            let since = calendar.date(byAdding: .day, value: -reach, to: now) ?? now
            var annotated = milestone
            annotated.sourceChangeNote = ProvenanceScan.noteForClaim(
                metric: milestone.metric,
                window: "the \(reach) days this record was set and measured against",
                since: since, now: now, changes: sourceChanges
            )
            return annotated
        }
    }

    /// The current record milestone for one metric, or `nil` when there is no true record or the
    /// history is too thin to compute one. Marginal and short-span records ARE emitted, with their
    /// `relativeMargin` and `spanDays` — the numbers inform, the agents decide.
    private func detect(_ entry: DailySeries) -> Milestone? {
        guard entry.values.count >= config.minHistoryDays else { return nil }
        let calendar = Calendar.civil
        let sorted = entry.values.sorted { $0.key < $1.key }
        guard sorted.count >= config.window else { return nil }

        // Rolling means over `window` consecutive observations, but only where those observations
        // are calendar-DENSE — for intermittently-logged metrics (weight, VO₂max) 7 entries can span
        // weeks, and a "7-day stretch" record over them is meaningless.
        var means: [(day: Date, mean: Double)] = []
        for i in (config.window - 1)..<sorted.count {
            let span = calendar.dateComponents(
                [.day], from: sorted[i - config.window + 1].key, to: sorted[i].key
            ).day ?? .max
            guard span <= config.maxWindowSpanDays else { continue }
            let slice = sorted[(i - config.window + 1)...i].map(\.value)
            means.append((sorted[i].key, MetricStatsProvider.mean(slice)))
        }
        guard means.count >= config.minWindows, let latest = means.last else { return nil }

        let priors = means.dropLast().map(\.mean)
        guard let maxPrior = priors.max(), let minPrior = priors.min() else { return nil }

        // Any TRUE record — strictly beyond the prior extreme — is emitted; the margin is reported,
        // not gated on, so the agent can weigh a decisive record against one squeaking past.
        let isHigh: Bool
        let margin: Double
        if latest.mean > maxPrior {
            isHigh = true
            margin = maxPrior == 0 ? 0 : (latest.mean - maxPrior) / abs(maxPrior)
        } else if latest.mean < minPrior {
            isHigh = false
            margin = minPrior == 0 ? 0 : (minPrior - latest.mean) / abs(minPrior)
        } else {
            return nil // squarely inside the historical range — not a record at all
        }

        // How long the record actually stands: time since the value was last *comparably* extreme
        // (within the margin), not the full tracked history — so a record edging a recent near-peak
        // isn't overstated as "highest in a year."
        let comparable = isHigh ? latest.mean * (1 - config.margin) : latest.mean * (1 + config.margin)
        var standsSince = means[0].day
        for prior in means.dropLast().reversed()
            where isHigh ? prior.mean >= comparable : prior.mean <= comparable
        {
            standsSince = prior.day
            break
        }
        // Reported, not gated on: a record that stood a week and one that stood a year both emit,
        // and the agent reads `spanDays` to judge which is worth telling the user about.
        let spanDays = calendar.dateComponents([.day], from: standsSince, to: latest.day).day ?? 0

        return Milestone(
            metric: entry.metric,
            recentMean: latest.mean,
            isHigh: isHigh,
            spanDays: spanDays,
            relativeMargin: margin
        )
    }
}
