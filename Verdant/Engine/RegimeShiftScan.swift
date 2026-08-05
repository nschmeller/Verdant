import Foundation

/// Detects **regime shifts** — the day a metric stepped to a new sustained level that still holds.
/// Single-split binary segmentation: find the split maximizing the standardized step (Cohen's d)
/// between the before/after segments, requiring both segments long enough that the new level is
/// *settled*, not a transient spike. This is the "when did my baseline change?" finding that the
/// fixed-window mean comparisons structurally cannot produce.
///
/// Pure and `nonisolated`. Proposes candidates only — numbers inform, agents decide: every metric
/// with a computable step surfaces as a ranked candidate (strongest score first) carrying the
/// evidence the old hard guards used to filter on (`medianStepSD`, `maxSegmentTrendR`,
/// `maxPostGapDays`, `suspectedDeviceSwap`). The model and the downstream skeptic/replication
/// panels judge worth; nothing is silently dropped.
nonisolated struct RegimeShiftScan {
    nonisolated struct Config {
        /// Computability floor: enough history that the split search below has any room at all.
        var minHistoryDays = 90
        /// Each segment must be at least this long (so a one-week blip can't be a "new baseline").
        /// Part of the statistic's *definition* — it fixes the split-search space Cohen's d is
        /// maximized over — not a worth-judgment on a computed candidate.
        var minSegmentDays = 21
        /// Watch-vital regime shifts whose change-days fall within this many days of each other look
        /// like a device recalibration (a new Apple Watch), not physiology. They are FLAGGED
        /// (`suspectedDeviceSwap`), never suppressed — the agent sees the evidence and decides.
        var deviceSwapClusterDays = 3

        static let `default` = Config()
    }

    let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// `sourceChanges` are the days each metric changed recording source (`ProvenanceScan`). They
    /// annotate the returned shifts and never remove any — see `RegimeShift.sourceChangeNote`.
    func scan(
        _ series: [DailySeries],
        now _: Date = .now,
        sourceChanges: [SourceChange] = []
    ) -> [RegimeShift] {
        let shifts = series.compactMap(detect)
        return Self.annotated(
            Self.flagDeviceSwaps(shifts, clusterDays: config.deviceSwapClusterDays),
            sourceChanges: sourceChanges
        )
        .sorted { $0.score > $1.score }
    }

    /// Attach each shift's nearest change of recording source, if its metric had one.
    ///
    /// NEAREST, with no proximity threshold: how many days count as "the same time" is a judgment,
    /// and the whole point of surfacing this is that the agent makes it. The note states the
    /// distance, so a change eleven months from the step is visibly irrelevant and one on the same
    /// day is visibly damning, without this code deciding which.
    ///
    /// It also states how long the new setup held. A watch left on the charger for one night is a
    /// real transition in the record and a meaningless one here, and the run length is what tells
    /// the two apart — again, in the agent's hands rather than behind a cutoff.
    static func annotated(_ shifts: [RegimeShift], sourceChanges: [SourceChange]) -> [RegimeShift] {
        guard !sourceChanges.isEmpty else { return shifts }
        let byMetric = Dictionary(grouping: sourceChanges, by: \.metric)
        return shifts.map { shift in
            guard let candidates = byMetric[shift.metric] else { return shift }
            let calendar = Calendar.civil
            let nearest = candidates.min {
                abs($0.day.timeIntervalSince(shift.changeDay))
                    < abs($1.day.timeIntervalSince(shift.changeDay))
            }
            guard let nearest else { return shift }
            let gap = abs(
                calendar.dateComponents([.day], from: nearest.day, to: shift.changeDay).day ?? 0
            )
            var annotated = shift
            annotated.sourceChangeNote = "what RECORDS this metric changed "
                + "(\(SourceSignature.describe(nearest.before)) → "
                + "\(SourceSignature.describe(nearest.after))) \(gap) day\(gap == 1 ? "" : "s") from "
                + "this step, and has held \(nearest.daysAfter) days since — a new device reading "
                + "differently would look exactly like this"
            return annotated
        }
    }

    /// The single best regime shift for one metric, or `nil` only when no step is *computable* —
    /// too little history, no room for two full segments, or zero variance/step at every split.
    /// All former worth-guards (minimum effect size, median echo, segment flatness, post-segment
    /// gaps) are now fields on the returned shift for the agent to weigh.
    private func detect(_ entry: DailySeries) -> RegimeShift? {
        let sorted = entry.values.sorted { $0.key < $1.key }
        let n = sorted.count
        guard n >= config.minHistoryDays else { return nil }
        let values = sorted.map(\.value)

        // Prefix sums of value and value² for O(1) segment mean/variance at each split.
        var prefix = [Double](repeating: 0, count: n + 1)
        var prefixSq = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            prefix[i + 1] = prefix[i] + values[i]
            prefixSq[i + 1] = prefixSq[i] + values[i] * values[i]
        }

        let lo = config.minSegmentDays
        let hi = n - config.minSegmentDays
        guard lo <= hi else { return nil }

        var bestSplit = -1
        var bestScore = 0.0
        for k in lo...hi {
            let countBefore = Double(k), countAfter = Double(n - k)
            let sumBefore = prefix[k], sumAfter = prefix[n] - prefix[k]
            let ssBefore = prefixSq[k] - sumBefore * sumBefore / countBefore
            let ssAfter = (prefixSq[n] - prefixSq[k]) - sumAfter * sumAfter / countAfter
            let pooledVariance = (ssBefore + ssAfter) / Double(n - 2)
            guard pooledVariance > 0 else { continue }
            let score = abs(sumAfter / countAfter - sumBefore / countBefore) / pooledVariance.squareRoot()
            if score > bestScore {
                bestScore = score
                bestSplit = k
            }
        }
        // Computability epsilon, NOT a worth-floor (the old minScore=1.2 is gone): a zero best score
        // means no split had both positive pooled variance and a nonzero step — there is no candidate
        // to rank. Anything above zero surfaces; its `score` tells the agent how weak it is.
        guard bestSplit >= 0, bestScore > 0 else { return nil }

        let countBefore = Double(bestSplit), countAfter = Double(n - bestSplit)
        let sumBefore = prefix[bestSplit], sumAfter = prefix[n] - prefix[bestSplit]
        let beforeValues = Array(values[0..<bestSplit])
        let afterValues = Array(values[bestSplit..<n])

        // Pooled SD at the split — the unit `score` (Cohen's d) is measured in. The `> 0` guard is
        // pure computability (it is the divisor below), and is already guaranteed by the loop having
        // accepted this split with positive pooled variance.
        let ssBefore = prefixSq[bestSplit] - sumBefore * sumBefore / countBefore
        let ssAfter = (prefixSq[n] - prefixSq[bestSplit]) - sumAfter * sumAfter / countAfter
        let pooledSD = ((ssBefore + ssAfter) / Double(n - 2)).squareRoot()
        guard pooledSD > 0 else { return nil }

        // Anti-spike statistic, now a field: how strongly the medians echo the step (in SD units, so
        // it isn't skew-dependent). Weak echo (< 0.4) used to drop the candidate; now the basis says so.
        let medianStepSD = abs(Self.median(afterValues) - Self.median(beforeValues)) / pooledSD
        // Anti-ramp statistic, now a field: a true step has near-flat segments; a large within-segment
        // trend (|r| ≥ 0.6) suggests a drift the split merely bisected. Used to drop; now surfaced.
        let maxSegmentTrendR = max(
            abs(CorrelationEngine.pearson((0..<bestSplit).map(Double.init), beforeValues) ?? 0),
            abs(CorrelationEngine.pearson((0..<(n - bestSplit)).map(Double.init), afterValues) ?? 0)
        )

        // Calendar-density statistic, now a field, + truthful "held for N days": the level's tenure is
        // the calendar span from the change day to the last reading — NOT the observation count, which
        // overstates the duration for an intermittently-logged metric. The longest unobserved stretch
        // inside the post segment used to reject the shift outright (we never saw whether the level
        // "held" across it); now it rides along so the agent can weigh the tenure claim itself.
        let calendar = Calendar.civil
        let changeDay = sorted[bestSplit].key
        let postDays = calendar.dateComponents([.day], from: changeDay, to: sorted[n - 1].key).day ?? 0
        var maxPostGapDays = 0
        for i in (bestSplit + 1)..<n {
            let gap = calendar.dateComponents([.day], from: sorted[i - 1].key, to: sorted[i].key).day ?? 0
            maxPostGapDays = max(maxPostGapDays, gap)
        }

        return RegimeShift(
            metric: entry.metric,
            changeDay: changeDay,
            preMean: sumBefore / countBefore,
            postMean: sumAfter / countAfter,
            score: bestScore,
            postDays: postDays,
            medianStepSD: medianStepSD,
            maxSegmentTrendR: maxSegmentTrendR,
            maxPostGapDays: maxPostGapDays
        )
    }

    /// Flag Watch-vital shifts that cluster in time — a simultaneous step across several
    /// auto-measured vitals is the signature of a device swap/recalibration, not a real change.
    /// The clustering computation is unchanged from when it *dropped* these; it now sets
    /// `suspectedDeviceSwap` instead, so the candidates surface with the evidence in their basis
    /// and the skeptic/replication panels judge them (numbers inform, agents decide).
    static func flagDeviceSwaps(_ shifts: [RegimeShift], clusterDays: Int) -> [RegimeShift] {
        let calendar = Calendar.civil
        let vitals = shifts.filter(\.metric.isWatchVital)
        // The SIZE of the cluster each vital belongs to, not merely whether it belongs to one. Two
        // vitals stepping together is thin evidence for a device change; five on the same day is
        // near-certain, and the old boolean told the agent the same thing in both cases. The largest
        // cluster a metric participates in is the strongest evidence about it.
        var clusterSize: [MetricKey: Int] = [:]
        for shift in vitals {
            let cluster = vitals.filter {
                let gap = abs(calendar.dateComponents([.day], from: $0.changeDay, to: shift.changeDay)
                    .day ?? 99)
                return gap <= clusterDays
            }
            guard cluster.count >= 2 else { continue }
            for member in cluster {
                clusterSize[member.metric] = max(clusterSize[member.metric] ?? 0, cluster.count)
            }
        }
        return shifts.map { shift in
            var flagged = shift
            let size = clusterSize[shift.metric] ?? 0
            flagged.coJumpingVitals = size
            flagged.suspectedDeviceSwap = size >= 2
            return flagged
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
