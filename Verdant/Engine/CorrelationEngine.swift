import Foundation

/// The cross-source correlation engine — the heart of the app's "subtle and complex" ethos, and the
/// place where statistical honesty makes or breaks finding quality.
///
/// Daily health series are dominated by slow trends, seasonality, and weekly rhythms, and are highly
/// autocorrelated. Correlating their **raw levels** would surface mostly confounded junk — two
/// metrics that merely drift together over years, or both dip on weekends. So the engine instead:
///
///  1. **Correlates day-to-day changes** (winsorized first differences), which removes shared trend,
///     season, and level — a surviving link reflects genuine co-movement, not a shared calendar.
///  2. **Partials out same-day activity** (active energy): `partialR` is the relationship that holds
///     *even after accounting for how active you were*, killing the "activity halo" family.
///  3. Uses an **autocorrelation-corrected effective sample size** so significance means something
///     (raw `n` in the hundreds makes everything "significant").
///  4. Runs the **Benjamini–Hochberg** FDR guard over **one test per pair** (best lag chosen by a
///     pre-registered rule), so the family-wise correction isn't fooled by near-duplicate lag tests.
///  5. Flags **mechanically redundant** pairs (steps↔distance) so an agent never mistakes physics
///     for discovery.
///
/// The engine PRODUCES numbers and flags; it does not decide worth. Every judged pair is returned —
/// significant first — carrying its evidence (`pValue`, `significant`, `consistentAcrossThirds`,
/// `mechanicallyRedundant`), and the downstream agents (investigator, skeptic, replication panels)
/// judge it. The only pairs missing are those whose statistic isn't computable at all.
///
/// Pure and `nonisolated` — no actor state, fully unit-testable without a store or the model.
nonisolated struct CorrelationEngine {
    nonisolated struct Config {
        /// Minimum overlapping change-days for a pair to be eligible — a computability floor (below
        /// it there is no trustworthy correlation to compute), not a worth judgment.
        var minPairs = 21
        /// A lagged lag is chosen over lag 0 only if stronger by at least this margin (pre-registered
        /// rule that avoids "selection on the maximum" inflating the displayed lag).
        var lagPreferenceMargin = 0.10
        /// Largest lead/lag (in days) to test in each direction. Up to 3 captures multi-day
        /// physiological chains (e.g. a hard training day → suppressed HRV two days later). Only the
        /// single best lag per pair enters the FDR family, so this doesn't inflate false discoveries.
        var maxLag = 3
        /// Target false-discovery rate for the multiple-comparison guard.
        var fdrAlpha = 0.10
        /// Paired days must cover at least this fraction of the *sparser* metric's data, so a link
        /// can't rest on a self-selected slice (the handful of days the user logged both). A
        /// computability bound: without it the statistic isn't about the metrics, only a slice.
        var minOverlapFraction = 0.5
        /// Size cap on the returned ranked list — a MEMORY bound on the memoized scan (far above the
        /// tool layer's 6-row ceiling), not a worth gate: the ranking is significant-first then
        /// strength-descending, so nothing an agent would judge lives past the cap.
        var maxReturned = 40

        static let `default` = Config()
    }

    let config: Config
    /// Whether a pair is mechanically/tautologically coupled (steps↔distance). An anti-tautology
    /// boundary, not a worth judgment: such pairs are still computed and returned — flagged
    /// `mechanicallyRedundant` so the judging agent sees WHY the number is large — they just never
    /// spend the FDR family's discovery budget.
    let isRedundantPair: @Sendable (MetricKey, MetricKey) -> Bool

    init(
        config: Config = .default,
        isRedundantPair: @escaping @Sendable (MetricKey, MetricKey) -> Bool = MetricCatalog
            .isMechanicallyRedundant
    ) {
        self.config = config
        self.isRedundantPair = isRedundantPair
    }

    /// The outcome of one correlation scan: EVERY judged pair — significant first, then by
    /// confound-controlled strength — plus how many pairs entered the FDR family. The count conveys
    /// the *breadth* of the search — the Deep Analysis UI shows it, so "relationships tested" means
    /// pairs statistically judged as discovery candidates (mechanically-coupled pairs are computed
    /// and flagged, but a tautology was never a candidate, so it doesn't count).
    nonisolated struct Scan {
        let correlations: [MetricCorrelation]
        let pairsTested: Int
    }

    /// Judge every computable pair and return them ALL, ranked significant-first then by
    /// confound-controlled strength — at most one per unordered metric pair (the chosen lag),
    /// alongside the FDR family size.
    ///
    /// The numbers inform, the agents decide: sub-threshold pairs are not dropped — each entry
    /// carries its evidence (`pValue`, `significant`, `r`, `partialR`, `nEff`,
    /// `consistentAcrossThirds`, `mechanicallyRedundant`) and the downstream agents judge it; the
    /// skeptic and replication panels re-test whatever they propose. The only pairs absent are those
    /// whose statistic isn't computable (too few paired days, or overlap resting on a self-selected
    /// slice). The list is capped at `config.maxReturned` purely to keep the memoized scan small.
    func scan(in series: [DailySeries]) -> Scan {
        // Winsorized first differences per metric (the change series we actually correlate), plus
        // each metric's raw logged-day count for the coverage gate.
        var changes: [MetricKey: [Date: Double]] = [:]
        var ordered: [MetricKey: [(day: Date, value: Double)]] = [:]
        var loggedDays: [MetricKey: Int] = [:]
        for entry in series {
            let diff = Self.winsorize(Self.firstDifferences(entry.values))
            changes[entry.metric] = diff
            // Sorted here, once per METRIC, rather than once per lag candidate per pair inside
            // `evaluate` — the same rows, ~100× fewer sorts. This scan is the app's premium finding
            // path and it sits on the substrate's critical path, so a tool call waits on it.
            ordered[entry.metric] = diff.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
            loggedDays[entry.metric] = entry.values.count
        }
        let activity = changes[.activeEnergyBurned]

        let metrics = series.map(\.metric)
        var family: [MetricCorrelation] = []
        var redundant: [MetricCorrelation] = []
        for i in metrics.indices {
            for j in metrics.indices where j > i {
                let mA = metrics[i], mB = metrics[j]
                guard let dA = changes[mA], let dB = changes[mB] else { continue }
                // Don't partial activity out of a pair that already includes it.
                let covariate = (mA == .activeEnergyBurned || mB == .activeEnergyBurned) ? nil : activity
                let best = bestLag(
                    Channel(
                        metric: mA, diff: dA, ordered: ordered[mA] ?? [],
                        loggedDays: loggedDays[mA] ?? dA.count
                    ),
                    Channel(
                        metric: mB, diff: dB, ordered: ordered[mB] ?? [],
                        loggedDays: loggedDays[mB] ?? dB.count
                    ),
                    covariate: covariate
                )
                guard let best else { continue }
                // Tautological pairs (steps↔distance) are computed and surfaced — flagged so the
                // agent sees the coupling for what it is — but stay OUT of the FDR family: spending
                // the false-discovery budget on physics would dilute the honest pairs' correction.
                if isRedundantPair(mA, mB) {
                    redundant.append(best.with(mechanicallyRedundant: true))
                } else {
                    family.append(best)
                }
            }
        }

        // FDR over one test per pair — the family-wise correction isn't diluted by lag duplicates.
        let flags = Self.benjaminiHochberg(family.map(\.pValue), alpha: config.fdrAlpha)
        let judged = zip(family, flags).map { correlation, sig in correlation.with(significant: sig) }
        // Significant-first, then confound-controlled strength: ranking is the size-bounding
        // mechanism, not a filter — sub-threshold pairs stay in the list, below the proven ones.
        // (Redundant pairs are never FDR-judged, so they sort within the non-significant block.)
        let ranked = (judged + redundant).sorted {
            if $0.significant != $1.significant { return $0.significant }
            return $0.strength > $1.strength
        }
        return Scan(
            correlations: Array(ranked.prefix(config.maxReturned)),
            pairsTested: family.count
        )
    }

    /// One metric's change series, paired with its key and raw logged-day count — the unit
    /// `evaluate`/`bestLag` operate on.
    private struct Channel {
        let metric: MetricKey
        let diff: [Date: Double]
        /// The same entries in chronological order, built ONCE per metric in `scan`.
        ///
        /// `evaluate` used to iterate `diff` (arbitrary dictionary order) and sort the aligned rows
        /// afterwards — a sort per lag candidate per pair, which at 30 metrics is ~3,000 sorts of
        /// ~1,800 elements rather than 30. Iterating in order instead makes the rows chronological by
        /// construction, so the sort disappears entirely and the result is identical.
        let ordered: [(day: Date, value: Double)]
        let loggedDays: Int
    }

    /// One aligned observation: the lead-day change `x`, trail change `y`, and same-day activity `z`.
    private struct Row {
        let day: Date
        let x: Double
        let y: Double
        let z: Double?
    }

    /// Choose the single best lag for a pair: prefer same-day unless a lagged direction is clearly
    /// stronger. One `MetricCorrelation` (or nil if no lag has enough overlap).
    ///
    /// Multiplicity: when a lagged candidate wins, selecting the max-strength lag is selection over up to
    /// `candidates.count` (≤ `1 + 2·maxLag`) correlated lags, so its plain Fisher-z p-value is optimistic.
    /// We Bonferroni-correct that winner's p-value by the number of lags searched *before* it enters the
    /// Benjamini–Hochberg family, so the FDR guard isn't fed a selection-on-maximum p-value. Same-day
    /// (lag 0) wins are pre-registered and take no penalty. Bonferroni over correlated lags is
    /// conservative; with `nEff` and the thirds-consistency flag the judging agents see, this keeps
    /// the family honest.
    private func bestLag(_ a: Channel, _ b: Channel, covariate: [Date: Double]?) -> MetricCorrelation? {
        var candidates: [MetricCorrelation] = []
        if let c0 = evaluate(a, b, lag: 0, covariate: covariate) { candidates.append(c0) }
        if config.maxLag >= 1 {
            for lag in 1...config.maxLag {
                if let lead = evaluate(a, b, lag: lag, covariate: covariate) { candidates.append(lead) }
                if let trail = evaluate(b, a, lag: lag, covariate: covariate) { candidates.append(trail) }
            }
        }
        guard let strongest = candidates.max(by: { $0.strength < $1.strength }) else { return nil }
        if let lag0 = candidates.first(where: { $0.lag == 0 }),
           strongest.strength - lag0.strength < config.lagPreferenceMargin
        {
            return lag0
        }
        // A lagged candidate beat lag 0 — Bonferroni-correct for having searched `candidates.count`
        // correlated lags, so BH downstream isn't fed an optimistic selection-on-maximum p-value.
        return strongest.with(pValue: min(1, strongest.pValue * Double(candidates.count)))
    }

    /// Align `lead` (at day d) with `trail` (at day d+lag) and the activity covariate (at day d),
    /// then compute the change-correlation, the activity-partialled correlation, Spearman, and `nEff`.
    private func evaluate(
        _ lead: Channel,
        _ trail: Channel,
        lag: Int,
        covariate: [Date: Double]?
    ) -> MetricCorrelation? {
        // Collect aligned (day, x, y, z) rows, then sort CHRONOLOGICALLY — essential so the lag-1
        // autocorrelation (→ nEff) and the episode-robustness thirds operate on time order, not the
        // dictionary's arbitrary iteration order.
        //
        // The lag hop is plain 86,400-second arithmetic, NOT a Calendar operation: `Calendar.civil`
        // is fixed-UTC (every day exactly 86,400 s; keys are exact day starts), and this line runs
        // per diff entry × per lag × per pair — over all-time series that's tens of millions of
        // executions per substrate, where ICU calendar math costs whole minutes of CPU.
        var rows: [Row] = []
        rows.reserveCapacity(lead.ordered.count)
        // Chronological by construction — see `Channel.ordered`. Nothing downstream sorts these
        // again, and the lag-1 autocorrelation and thirds check below both depend on time order.
        for (day, xValue) in lead.ordered {
            let target = lag == 0
                ? day
                : day.addingTimeInterval(86400 * Double(lag))
            guard let yValue = trail.diff[target] else { continue }
            let zValue = covariate?[day]
            // When controlling for activity, a day with no activity value can't be residualized — and
            // silently keeping it would compute a RAW correlation while still labelling it "controlled
            // for activity". Drop such days; if too few remain, the pair simply won't clear coverage
            // (correct: we never surface a cross-metric link claiming an activity control we couldn't do).
            if covariate != nil, zValue == nil { continue }
            rows.append(Row(day: day, x: xValue, y: yValue, z: zValue))
        }
        // Computability: below `minPairs` there is no trustworthy correlation to compute at all —
        // a produce-a-number gate, not a worth judgment (worth is the agents' call).
        guard rows.count >= config.minPairs else { return nil }
        // Overlap-coverage gate: the pair must span most of the sparser metric's *logged days* (raw,
        // not post-difference — so a gappy metric is correctly judged low-coverage, not let through
        // on a dense slice), not a self-selected slice. Also computability: without it the statistic
        // describes a slice, not the metrics.
        let coverageFloor = Int(config.minOverlapFraction * Double(min(lead.loggedDays, trail.loggedDays)))
        guard rows.count >= coverageFloor else { return nil }

        let xs = rows.map(\.x), ys = rows.map(\.y)
        guard let r = Self.pearson(xs, ys) else { return nil }

        // Residualize x and y on same-day activity ONCE, so the partial coefficient, Spearman,
        // effective-n, and the episode-robustness check all operate on the SAME (activity-controlled)
        // series the finding is actually about — not on raw x,y the app never displays.
        let zs = rows.compactMap(\.z)
        let resX: [Double], resY: [Double]
        if zs.count == xs.count {
            resX = Self.residuals(xs, on: zs)
            resY = Self.residuals(ys, on: zs)
        } else {
            resX = xs
            resY = ys
        }
        let partialR = Self.pearson(resX, resY) ?? r
        // Episode-robustness: whether the controlled link holds across time or lives in one lucky
        // stretch. A SIGNAL on the finding (`consistentAcrossThirds`), not a gate — the judging
        // agents weigh it against the rest of the evidence.
        let consistentAcrossThirds = Self.signHoldsAcrossThirds(resX, resY, overall: partialR)
        let thirdsR = Self.thirdsCorrelations(resX, resY)

        let spearman = Self.pearson(Self.ranks(resX), Self.ranks(resY)) ?? partialR
        let nEff = Self.effectiveSampleSize(resX, resY)
        return MetricCorrelation(
            metricA: lead.metric, metricB: trail.metric, lag: lag,
            r: r, partialR: partialR, spearman: spearman,
            n: xs.count, nEff: nEff,
            pValue: Self.pValue(r: partialR, n: nEff, covariates: covariate != nil ? 1 : 0),
            significant: false,
            // Controlled iff an activity covariate was supplied — and, per the row-building guard
            // above, that means every row was residualized on it. `nil` covariate = a pair that
            // already includes activity, or a user with no activity data; either way, not controlled.
            activityControlled: covariate != nil,
            consistentAcrossThirds: consistentAcrossThirds,
            thirdsR: thirdsR
        )
    }

    /// The correlation within each chronological third, oldest first — empty when there are too few
    /// points to split meaningfully.
    ///
    /// These are the numbers `consistentAcrossThirds` was hiding. That flag asks whether the sign
    /// reproduced in two of three thirds, which is the right question for "is this one lucky
    /// stretch?" and the wrong one for "is this still true?" — a link that ran at 0.55, 0.51 and then
    /// 0.04 scores two of three and is reported as consistent, when what actually happened is that it
    /// ENDED. That is not a defect in the flag; it is a different question the flag was never asked,
    /// and the most interesting one a person cannot see for themselves.
    ///
    /// So the thirds travel as numbers and no rule is applied to them. Whether a faded link is a
    /// changed body, a changed routine, a changed device or noise is exactly the judgment that
    /// belongs to the agents.
    static func thirdsCorrelations(_ xs: [Double], _ ys: [Double]) -> [Double] {
        let n = xs.count
        guard n >= 9 else { return [] }
        let cut = n / 3
        return [(0, cut), (cut, 2 * cut), (2 * cut, n)].compactMap { low, high in
            pearson(Array(xs[low..<high]), Array(ys[low..<high]))
        }
    }

    /// Whether the correlation's sign reproduces in at least two of three chronological thirds — a
    /// link that exists only in one stretch (a vacation, an injury month) isn't a constant. Reported
    /// on each finding as `consistentAcrossThirds` for the judging agents; not a keep/drop gate.
    ///
    /// Derived from `thirdsCorrelations` rather than recomputing the splits, so the flag and the
    /// numbers stated beside it can never disagree about what the thirds were.
    static func signHoldsAcrossThirds(_ xs: [Double], _ ys: [Double], overall: Double) -> Bool {
        let thirds = thirdsCorrelations(xs, ys)
        guard !thirds.isEmpty else { return true } // too few to split meaningfully — don't over-reject
        let overallPositive = overall >= 0
        return thirds.count(where: { abs($0) >= 0.1 && ($0 >= 0) == overallPositive }) >= 2
    }

    // MARK: - Pure statistics

    /// First differences keyed by the later day: `value(d) − value(d−1)` when both days exist.
    /// Fixed 86,400-second hop, not Calendar math — `Calendar.civil` days are exact (see `evaluate`).
    static func firstDifferences(_ values: [Date: Double]) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for (day, value) in values {
            if let previous = values[day.addingTimeInterval(-86400)] { out[day] = value - previous }
        }
        return out
    }

    /// Clip values to the 2.5/97.5 percentiles, so one device gap or backfilled day can't swing a
    /// correlation.
    ///
    /// The `>= 8` guard below is not what decides when it takes effect — the percentiles are, and
    /// they switch on ASYMMETRICALLY. Measured, not derived (`WinsorizeOnsetTests`):
    ///
    ///     n <= 20   neither end clipped
    ///     n == 21   low end only        <- exactly `minPairs`
    ///     n >= 22   both ends
    ///
    /// That is arithmetically right and worth stating anyway, because of where it lands. A pair at
    /// the eligibility floor has no UPPER clip, and the upper end is where the outliers this exists
    /// to stop actually arrive: a backfilled day or a device gap produces a large POSITIVE change.
    /// It is also the correlation with the least evidence to absorb one, at 1/21. The guard reading
    /// `>= 8` invites the conclusion that clipping has been happening for thirteen days by then.
    ///
    /// Left as-is: 2.5/97.5 on a series this short is a statistical design choice (a wider clip, or a
    /// median-based rule like MAD, would protect small pairs but change every correlation the app has
    /// ever computed), not something to adjust while documenting it.
    static func winsorize(_ map: [Date: Double]) -> [Date: Double] {
        guard map.count >= 8 else { return map }
        let sorted = map.values.sorted()
        let low = percentile(sorted, 0.025)
        let high = percentile(sorted, 0.975)
        return map.mapValues { min(high, max(low, $0)) }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// Pearson product-moment correlation. `nil` when either series has zero variance.
    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            let dx = x[i] - meanX
            let dy = y[i] - meanY
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        let denom = (sxx * syy).squareRoot()
        guard denom > 0 else { return nil }
        return max(-1, min(1, sxy / denom))
    }

    /// Residuals of `v` after regressing it on a single covariate `z` (simple OLS). Correlating two
    /// such residual series gives the partial correlation controlling for `z`; returns `v` unchanged
    /// when `z` has no variance.
    static func residuals(_ v: [Double], on z: [Double]) -> [Double] {
        guard v.count == z.count, v.count >= 2 else { return v }
        let n = Double(v.count)
        let meanV = v.reduce(0, +) / n
        let meanZ = z.reduce(0, +) / n
        var covariance = 0.0, varianceZ = 0.0
        for i in v.indices {
            let dz = z[i] - meanZ
            covariance += (v[i] - meanV) * dz
            varianceZ += dz * dz
        }
        guard varianceZ > 0 else { return v }
        let slope = covariance / varianceZ
        return v.indices.map { v[$0] - (meanV + slope * (z[$0] - meanZ)) }
    }

    /// Tie-averaged ranks, for Spearman (= Pearson of ranks).
    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, values[order[j + 1]] == values[order[i]] {
                j += 1
            }
            let average = Double(i + j) / 2 + 1
            for k in i...j {
                ranks[order[k]] = average
            }
            i = j + 1
        }
        return ranks
    }

    /// Lag-1 autocorrelation of a series (0 if undefined).
    static func lag1Autocorrelation(_ values: [Double]) -> Double {
        guard values.count >= 3 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var num = 0.0, den = 0.0
        for i in values.indices {
            let d = values[i] - mean
            den += d * d
            if i > 0 { num += d * (values[i - 1] - mean) }
        }
        return den > 0 ? num / den : 0
    }

    /// Effective sample size correcting for autocorrelation: `n · (1−ρxρy)/(1+ρxρy)`, never inflated
    /// above `n`, floored so the p-value stays defined.
    static func effectiveSampleSize(_ x: [Double], _ y: [Double]) -> Double {
        let n = Double(x.count)
        // Floor each autocorrelation at 0: only genuine positive persistence should deflate nEff.
        // (First-differencing biases lag-1 autocorrelation negative; treating that as a correction
        // would perversely deflate — or, via a mixed-sign product, silently cancel — the guard.)
        let rhoX = max(0, lag1Autocorrelation(x))
        let rhoY = max(0, lag1Autocorrelation(y))
        let factor = (1 - rhoX * rhoY) / (1 + rhoX * rhoY) // ρ ≥ 0 ⇒ factor ∈ (0, 1]; never inflates
        return max(4.0, n * factor)
    }

    /// Two-sided p-value via the Fisher z-transform and a normal approximation, evaluated at the
    /// (possibly fractional) effective sample size. `covariates` is the number partialled out (0 for a
    /// plain correlation, 1 for the activity-controlled partial): the Fisher-z standard error loses one
    /// degree of freedom per covariate — `1/√(n − 3 − k)` — so an activity-controlled partial isn't
    /// scored with the slightly-too-confident plain-correlation SE.
    static func pValue(r: Double, n: Double, covariates: Int = 0) -> Double {
        let df = n - 3 - Double(covariates)
        guard df > 0 else { return 1 }
        let clamped = max(-0.999999, min(0.999999, r))
        let z = 0.5 * log((1 + clamped) / (1 - clamped)) // atanh(r)
        let standardError = 1.0 / df.squareRoot()
        let statistic = abs(z / standardError)
        return 2 * (1 - normalCDF(statistic))
    }

    /// Standard normal CDF via the complementary error function.
    static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    /// Benjamini–Hochberg step-up procedure controlling the false-discovery rate at `alpha`.
    static func benjaminiHochberg(_ pValues: [Double], alpha: Double) -> [Bool] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let ascending = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var lastRejectedRank = -1
        for (rank, idx) in ascending.enumerated() {
            let threshold = alpha * Double(rank + 1) / Double(m)
            if pValues[idx] <= threshold { lastRejectedRank = rank }
        }
        var result = [Bool](repeating: false, count: m)
        if lastRejectedRank >= 0 {
            for rank in 0...lastRejectedRank {
                result[ascending[rank]] = true
            }
        }
        return result
    }
}
