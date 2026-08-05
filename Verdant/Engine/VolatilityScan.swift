import Foundation

/// Detects **volatility shifts** — metrics that have become markedly more (or less) erratic than
/// their longer-run baseline, judged by the coefficient of variation so the test is level- and
/// scale-robust. This is a finding *class* the mean-difference comparisons structurally cannot
/// produce: a metric whose average is unchanged but whose day-to-day spread has widened.
///
/// Pure and `nonisolated` — fully unit-testable. Numbers inform, agents decide: the scan emits a
/// candidate for EVERY metric whose recent and baseline CVs are computable — no ratio band, no
/// significance gate — ranked by |log CV ratio| (biggest change first) and carrying `seZ`, the
/// exact standard-error statistic the old 2-SE gate computed, so the model (and the downstream
/// skeptic/replication panels) judge significance instead of a silent drop.
nonisolated struct VolatilityScan {
    nonisolated struct Config {
        var recentDays = 30
        var baselineDays = 120
        /// Computability floors, not worth-judgments: a *sample* SD divides by (count − 1), and so
        /// does the delta-method SE behind `seZ` — both need at least 2 observations to be defined.
        /// A 2-day window is statistically flimsy, and that is exactly what its tiny `seZ` tells the
        /// agent; the old ~20/30 floors were worth-guards and are gone.
        var minRecent = 2
        var minBaseline = 2

        static let `default` = Config()
    }

    let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// `sourceChanges` annotate the shifts they could explain — see
    /// `VolatilityShift.sourceChangeNote`.
    func scan(
        _ series: [DailySeries],
        now: Date = .now,
        sourceChanges: [SourceChange] = []
    ) -> [VolatilityShift] {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        // Anchor on the last complete day, matching the mean-comparison windows.
        let anchor = calendar.date(byAdding: .day, value: -1, to: today)!
        let recentCut = calendar.date(byAdding: .day, value: -(config.recentDays - 1), to: anchor)!
        let baseEnd = calendar.date(byAdding: .day, value: -config.recentDays, to: anchor)!
        let baseStart = calendar.date(
            byAdding: .day,
            value: -(config.recentDays + config.baselineDays),
            to: anchor
        )!

        var shifts: [VolatilityShift] = []
        for entry in series {
            // Chronological, never dictionary order: the means/SDs below sum in the order given, and
            // Swift's dictionary iteration order is not stable across separately-built dictionaries
            // holding the same pairs. Reading unordered made identical data produce last-ULP-different
            // CV ratios, which can flip the near-tie ranking at the end of this function — and with it
            // which shifts survive `patternScan`'s per-kind cap.
            let recent = entry.values
                .filter { $0.key >= recentCut && $0.key <= anchor }
                .sorted { $0.key < $1.key }.map(\.value)
            let baseline = entry.values
                .filter { $0.key > baseStart && $0.key <= baseEnd }
                .sorted { $0.key < $1.key }.map(\.value)
            guard recent.count >= config.minRecent, baseline.count >= config.minBaseline else { continue }

            let recentSD = MetricStatsProvider.sampleStandardDeviation(recent)
            let baselineSD = MetricStatsProvider.sampleStandardDeviation(baseline)
            let recentMean = MetricStatsProvider.mean(recent)
            let baselineMean = MetricStatsProvider.mean(baseline)
            // Computability guards only: a zero baseline SD or a zero mean makes the CV ratio
            // undefined (division by zero) — there is no statistic to hand the agent.
            //
            // `recentSD > 0` belongs here for the same reason, and its absence was a live bug. A
            // perfectly FLAT recent window (a weight logged identically each day, a device reporting
            // a constant) gives a CV ratio of exactly 0, and this scan's statistic and its ranking
            // are both `log(cvRatio)`: log(0) is −infinity, so `seZ` came out INFINITE and
            // `abs(log(ratio))` sorted that metric FIRST. The steadiest possible signal was
            // presented to the agents as the most significant volatility shift in the data, with a
            // non-finite uncertainty statistic attached, crowding real shifts out of
            // `patternScan`'s per-kind cap. A metric going flat is a real event, but it is a regime
            // or level story — `analyze` reports stdDev directly — not a log-ratio one.
            guard baselineSD > 0, recentSD > 0, recentMean != 0, baselineMean != 0 else { continue }

            let recentCV = recentSD / abs(recentMean)
            let baselineCV = baselineSD / abs(baselineMean)
            guard baselineCV > 0 else { continue }
            let ratio = recentCV / baselineCV
            // Uncertainty statistic, carried instead of gated on: `seZ` is |log(ratio)| in standard
            // errors — the scan used to require ≥ 2 (and a ratio outside 0.62…1.6) and silently drop
            // the rest; now every computable candidate surfaces and the agent reads seZ. The SE is
            // the delta-method SE of a log *SD* ratio; the numerator is the log *CV* ratio. The two
            // coincide when the mean holds — the case volatility is about — so this is a close
            // approximation, and a mean-driven CV change is caught and labeled downstream
            // (`meanHeld`, and the skeptic's "mean artifact?" lens). An approximation, not an exact
            // CV test.
            let standardError =
                (1.0 / (2 * Double(recent.count - 1)) + 1.0 / (2 * Double(baseline.count - 1))).squareRoot()
            let seZ = abs(Foundation.log(ratio)) / standardError

            shifts.append(VolatilityShift(
                metric: entry.metric,
                recentSD: recentSD, baselineSD: baselineSD,
                recentMean: recentMean, baselineMean: baselineMean,
                cvRatio: ratio, seZ: seZ, n: recent.count
            ))
        }
        // Biggest change in either direction first — the strongest-first ranking is what bounds what
        // downstream token-budgeted consumers (e.g. `patternScan`'s per-kind cap) actually see.
        let ranked = shifts.sorted { abs(log($0.cvRatio)) > abs(log($1.cvRatio)) }
        guard !sourceChanges.isEmpty else { return ranked }
        // `recentCut` is the window the recent SD was measured over — the claim's own comparison
        // boundary, so a source change after it changed the very spread being reported.
        return ranked.map { shift in
            var annotated = shift
            annotated.sourceChangeNote = ProvenanceScan.noteForClaim(
                metric: shift.metric,
                window: "the \(config.recentDays)-day window this compares",
                since: recentCut, now: now, changes: sourceChanges
            )
            return annotated
        }
    }
}
