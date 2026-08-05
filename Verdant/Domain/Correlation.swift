import Foundation

/// One metric's daily values over a window, keyed by fixed-UTC civil-day start (`Calendar.civil`, so
/// the day grid is timezone-stable). The substrate the `CorrelationEngine` aligns and correlates;
/// produced by `MetricStatsProvider.dailySeries`.
nonisolated struct DailySeries: Equatable {
    let metric: MetricKey
    /// `Calendar.civil.startOfDay` → that day's canonical value (sum or mean per the metric's aggregation).
    let values: [Date: Double]
}

/// One charted point — a day and its canonical value. Sorted arrays of these back the sparklines
/// and dual-line correlation charts.
nonisolated struct DailyPoint: Identifiable, Equatable {
    let day: Date
    let value: Double

    var id: Date {
        day
    }
}

/// A regime shift: a metric stepped to a new sustained level on a particular day and has held there
/// since — "your resting heart rate settled into a new, higher baseline around mid-May." The
/// windowed mean comparisons literally can't express *when* a baseline moved; this can.
nonisolated struct RegimeShift: Equatable, Identifiable {
    let metric: MetricKey
    /// The day the level appears to have stepped.
    let changeDay: Date
    let preMean: Double
    let postMean: Double
    /// Standardized step size (Cohen's d) between the before/after segments.
    let score: Double
    /// Calendar days the new level has held — from the change day to the latest reading (NOT an
    /// observation count), so "held for N days" is literally true even for a sparsely-logged metric.
    let postDays: Int
    /// |median(after) − median(before)| in pooled-SD units — the anti-spike statistic. A step the
    /// medians barely echo (≲ 0.4) may be driven by a few outlier days rather than a moved level.
    /// Carried, not gated on: the number informs, the agent decides.
    let medianStepSD: Double
    /// The larger |Pearson r| of day-index vs. value within either segment — the anti-ramp statistic.
    /// A true step has near-flat segments (small |r|); a high value (≳ 0.6) suggests a steady drift
    /// the split merely bisected. Carried, not gated on.
    let maxSegmentTrendR: Double
    /// The longest unobserved calendar stretch (in days) inside the post-change segment. A long gap
    /// weakens the "held for `postDays` days" claim — we never saw whether the level held across it.
    /// Carried, not gated on.
    let maxPostGapDays: Int
    /// Whether this shift's change-day clusters with steps in other Watch-measured vitals — the
    /// signature of a device swap/recalibration rather than physiology. A flag, not a filter: the
    /// candidate still surfaces and the skeptic/replication panels judge it.
    var suspectedDeviceSwap = false
    /// How many Watch-measured vitals — this one included — stepped within a few days of each other.
    /// The number behind `suspectedDeviceSwap`, which is simply this being at least 2.
    ///
    /// Carried because two vitals moving together is thin evidence for a device change and five on
    /// the same day is near-certain, and the boolean says the same thing about both. It also sits
    /// beside `sourceChangeNote`, which states its own distances and run lengths — an inferred
    /// caveat should not be the vaguer of the two when its evidence is just as countable.
    var coJumpingVitals = 0
    /// What HealthKit RECORDED about a change of recording source near this step, if there was one —
    /// already phrased, because the only consumer is the basis line.
    ///
    /// The companion to `suspectedDeviceSwap` and the stronger of the two. That flag INFERS a device
    /// change from several Watch vitals stepping together, which is a good guess that says nothing
    /// for a metric no other vital moves with — a body weight from a new scale, steps from a new
    /// phone. This is not an inference: it is the source list HealthKit stored against the days
    /// themselves. Still a note rather than a filter, for the reason every caveat here is: a device
    /// change and a real change can land in the same week, and only the agent can weigh that.
    var sourceChangeNote: String?

    var id: String {
        metric.rawValue
    }

    var roseUp: Bool {
        postMean >= preMean
    }

    /// Confirmed statistics phrased for the adversarial skeptic (grounds the "transient blip?" lens).
    /// `preMean`/`postMean` are raw STORED values (meters for distance, a 0–1 fraction for percent
    /// metrics), so they go through the same display transform the prose uses — otherwise the skeptic
    /// reasons over a basis in the wrong unit/scale that contradicts the story it is judging (e.g. a
    /// blood-oxygen step of 0.97→0.94 would print as "~1 to ~1", a non-step).
    ///
    /// Numbers inform, agents decide: the detector no longer drops weak or suspect candidates, so the
    /// basis must carry the caveats the old guards enforced silently. The caveat thresholds below
    /// mirror the scan's former hard cutoffs (0.4·SD median echo, |r| 0.6 segment trend, 21-day gap)
    /// but shape *phrasing only* — the raw fields are always on the struct for the agent to weigh.
    var verifiedBasis: String {
        let from = MetricFormatting.canonical(preMean, metric)
        let to = MetricFormatting.canonical(postMean, metric)
        var caveats: [String] = []
        // First, because it is the one caveat that can invalidate the finding outright rather than
        // weaken it — and the one the numbers can never reveal on their own.
        if let sourceChangeNote {
            caveats.append(sourceChangeNote)
        }
        if suspectedDeviceSwap {
            caveats.append(
                "\(coJumpingVitals) watch-measured vitals stepped within days of each other, this "
                    + "one included — possible device change, not physiology"
            )
        }
        if medianStepSD < 0.4 {
            caveats.append(String(
                format: "the medians echo the step only weakly (~%.1f SD) — possibly a few outlier days",
                medianStepSD
            ))
        }
        if maxSegmentTrendR >= 0.6 {
            caveats.append(String(
                format: "a segment trends internally (|r| \u{2248} %.2f) — possibly a steady drift, not a step",
                maxSegmentTrendR
            ))
        }
        if maxPostGapDays > 21 {
            caveats.append("the new level spans a \(maxPostGapDays)-day unobserved stretch")
        }
        // "effect size 8.2" is read as EIGHT POINT TWO BPM by a small model. Observed: a skeptic
        // rejected a real 62→58 bpm step because "resting heart rate typically changes only by a few
        // beats per minute, and this change is far larger than any physiological factor could account
        // for" — it had taken the standardized figure for the change itself, in a sentence that states
        // the actual change four words earlier. Naming the unit costs three words and removes the
        // reading that killed the finding.
        let core = "A sustained step from ~\(from) to ~\(to) that has held for \(postDays) days "
            + "(effect size \(String(format: "%.1f", score)) standard deviations)"
        // Which days each average covers. Stated because the replication panel cannot re-compute a
        // comparison whose boundary it does not know: the first run in which analysts reached the
        // data at all, two of five picked their own baseline window, both picked one OVERLAPPING the
        // recent period, and both then argued against the claim from the blended number they got
        // (a 63 -> 54 step read as "54 vs 56.1" and as "60, consistent with 54").
        //
        // Deliberately says "readings", not "days": `postDays` is the CALENDAR tenure of the new
        // level, while these means average OBSERVATIONS, and for an intermittently-logged metric
        // those differ — the same conflation the scan's own tenure comment warns about. Naming a day
        // count here would be a figure no engine computed, which is what `NumericFidelity` exists to
        // catch in the prose and should not be introduced by the basis itself.
        let windows = "The ~\(to) averages every reading since the change; "
            + "the ~\(from) averages every reading on record before it."
        return caveats.isEmpty
            ? "\(core) — a durable level change, not a transient blip. \(windows)"
            : "\(core); caveats: \(caveats.joined(separator: "; ")). \(windows)"
    }
}

/// A shift in how *erratic* a single metric is — its recent day-to-day spread (coefficient of
/// variation) versus its longer baseline — independent of whether the average moved. The mean-only
/// comparisons can't see this; "your sleep got markedly more variable this month, even though the
/// average held" is exactly the kind of non-obvious finding it surfaces.
nonisolated struct VolatilityShift: Equatable, Identifiable {
    let metric: MetricKey
    let recentSD: Double
    let baselineSD: Double
    let recentMean: Double
    let baselineMean: Double
    /// Recent coefficient of variation ÷ baseline coefficient of variation. >1 = more erratic.
    let cvRatio: Double
    /// |log(cvRatio)| in delta-method standard errors of a log SD ratio — the exact statistic the
    /// scan's former 2-SE significance gate computed. Now carried on every candidate instead of
    /// gating: ~2 is the conventional "clears the sampling noise of an SD" line, but the number
    /// informs and the agent (plus the skeptic/replication panels) decides.
    let seZ: Double
    /// Recent observations the shift is based on.
    let n: Int
    /// A change of recording source inside the recent window — see `RegimeShift.sourceChangeNote`.
    /// A device that samples differently produces a genuinely different spread, so "your readings
    /// grew more erratic" can be a statement about the sensor.
    var sourceChangeNote: String?

    var id: String {
        metric.rawValue
    }

    /// Recent ÷ baseline standard deviation — the raw day-to-day swing. The single source for the
    /// SD framing the card, the phraser, and `verifiedBasis` all share; detection still ranks on the
    /// level-robust `cvRatio`, but everything a person (or the skeptic) reads is this SD measure, so
    /// the three never contradict each other.
    var sdRatio: Double {
        baselineSD > 0 ? recentSD / baselineSD : 1
    }

    /// How far the average actually moved, as a percentage — `nil` when the baseline is zero and
    /// there is no percentage to state.
    ///
    /// One expression, because both the basis line and the persist route's fidelity list need it and
    /// computing it twice is how the two drift. (They already had: the basis stated the figure while
    /// the route passed only `n`, under a comment claiming it passed the percentage too.)
    var meanShiftPercent: Double? {
        guard baselineMean != 0 else { return nil }
        return abs((recentMean - baselineMean) / baselineMean) * 100
    }

    /// Whether the average stayed roughly put while the spread changed — the most striking case.
    var meanHeld: Bool {
        baselineMean != 0 && abs((recentMean - baselineMean) / baselineMean) < 0.10
    }

    /// Confirmed statistics phrased for the adversarial skeptic (grounds the "just noise?" and "mean
    /// artifact?" lenses). Describes the raw-SD swing — the SAME quantity the card and the phraser
    /// use — so the skeptic never reasons against a basis that contradicts the story it's judging. The
    /// mean clause is reported accurately: the scan fires whether or not the average held, and claiming
    /// it held when it didn't would feed the skeptic a falsehood and blunt its artifact check.
    ///
    /// Numbers inform, agents decide: the scan no longer drops sub-threshold candidates, so the basis
    /// states `seZ` — how many standard errors the CV-ratio shift sits from no-change — and lets the
    /// agent judge whether that clears the (wide) sampling noise of a standard deviation.
    var verifiedBasis: String {
        // The mean change, not just the verdict on it. `meanHeld` thresholds a 10% move, so "the
        // average barely moved" covers everything from 0% to 9.9% — and the whole appeal of a
        // volatility finding is that the spread changed while the LEVEL did not, which is a claim
        // about exactly this number. An earlier sweep of engine booleans passed over this one on the
        // grounds that both means are carried on the struct. They are, and no agent reads the struct:
        // the basis is what the panels see, and it stated only the verdict.
        let meanNote = meanHeld
            ? "while the average barely moved"
            : "and the average also shifted"
        let quantified = meanShiftPercent.map { String(format: " (%.1f%%)", $0) } ?? ""
        let core = String(
            format: "Day-to-day swing is now ~%.1f\u{00D7} its prior level (\u{00B1}%.2f vs \u{00B1}%.2f), "
                + "measured over %d recent days",
            sdRatio, recentSD, baselineSD, n
        )
        let uncertainty = String(format: "the shift is %.1f standard errors from no-change", seZ)
        let caveat = sourceChangeNote.map { " Caveat: \($0)." } ?? ""
        return "\(core), \(meanNote)\(quantified); \(uncertainty).\(caveat)"
    }
}

/// A discovered association between two metrics. `metricA` *leads* `metricB` by `lag` days
/// (`lag == 0` is same-day, where the ordering is arbitrary).
///
/// Critically, the coefficients are computed on the metrics' **day-to-day changes** (winsorized
/// first differences), NOT raw levels — so a shared multi-year trend or weekly rhythm can't
/// manufacture a correlation. `r` is that change-correlation; `partialR` additionally removes
/// same-day activity, so a surviving link holds *even after accounting for how active you were*.
/// `nEff` is the autocorrelation-corrected effective sample size the `pValue` is computed from.
///
/// This is the app's primary *subtle, cross-source* finding: it links disparate data streams
/// (e.g. sleep ↔ recovery) that a per-metric trend can never reveal.
nonisolated struct MetricCorrelation: Equatable, Identifiable {
    let metricA: MetricKey
    let metricB: MetricKey
    /// Days `metricA` precedes `metricB`. `0` = same day.
    let lag: Int
    /// Pearson correlation of the two metrics' day-to-day changes (−1…1).
    let r: Double
    /// `r` after partialling out same-day activity (active energy). Equals `r` when no activity
    /// covariate applies. This is what ranking and the quality score use.
    let partialR: Double
    /// Spearman (rank) correlation of the **activity-residualized** change series (the same series
    /// `partialR` is computed on); large divergence from `partialR` flags a nonlinear/outlier shape.
    let spearman: Double
    /// Number of paired days.
    let n: Int
    /// Autocorrelation-corrected effective sample size (≤ `n`); the `pValue` is derived from this.
    let nEff: Double
    /// Two-sided p-value of `partialR` at `nEff` (Fisher z-transform → normal approximation).
    /// `var` so `bestLag` can Bonferroni-correct a lagged winner for lag-selection multiplicity.
    var pValue: Double
    /// Whether this survived the family-wide (one test per pair) Benjamini–Hochberg guard.
    var significant: Bool
    /// Whether `partialR` actually had same-day activity residualized out. False when the pair itself
    /// includes activity, or there was no activity data to control with — in which case `partialR ==
    /// r` and no "controlled for activity" claim may be made about it.
    var activityControlled = false
    /// Whether the (activity-residualized) correlation's sign reproduced in at least two of three
    /// chronological thirds. Once a hard gate, now a robustness SIGNAL: `false` means the link may
    /// live in a single stretch (a vacation, an injury month) — the numbers inform, and the judging
    /// agents decide whether that matters.
    var consistentAcrossThirds = true
    /// The correlation within each chronological third, oldest first — the numbers behind the flag
    /// above, empty when the record is too short to split.
    ///
    /// Carried because the flag answers "is this one lucky stretch?" and cannot answer "is this
    /// still true?". A link running 0.55, 0.51, 0.04 scores two of three and reports as consistent,
    /// while what happened is that it ended; one running 0.02, 0.08, 0.61 scores one of three and
    /// reports as unreliable, while what happened is that it began. Both are findings a person
    /// cannot see for themselves, and the boolean actively points away from them.
    ///
    /// Numbers inform, agents decide: nothing here rules on what a fading link means.
    var thirdsR: [Double] = []
    /// Whether the pair is mechanically/tautologically coupled (steps↔distance). An anti-tautology
    /// marker, not a worth judgment: the engine still computes and surfaces the pair so the agent
    /// sees the evidence, but `true` says the co-movement is physics/derivation, not discovery. Such
    /// pairs are never FDR-judged, so their `significant` stays `false` and `pValue` is the raw
    /// (lag-corrected) per-pair value.
    var mechanicallyRedundant = false

    var id: String {
        "\(metricA.rawValue)|\(metricB.rawValue)|\(lag)"
    }

    /// The confound-controlled strength used for ranking and the feed-quality score.
    var strength: Double {
        abs(partialR)
    }

    var isPositive: Bool {
        partialR >= 0
    }

    /// How well the rank correlation agrees with the linear one (1 = identical sign & magnitude,
    /// →0 as they diverge). Low agreement means the relationship is nonlinear/outlier-driven.
    /// Compares like with like: BOTH `spearman` and `partialR` live in activity-residualized space, so
    /// comparing to the raw `r` would falsely flag a clean, monotone, activity-confounded link as
    /// nonlinear (and gut its `trustStrength`). When uncontrolled, `partialR == r`, so this is a no-op.
    var monotoneAgreement: Double {
        1 - min(1, abs(spearman - partialR))
    }

    /// A 0–1 trust score blending the confound-controlled strength with statistical confidence
    /// (effective sample size) and shape robustness — so a clean moderate link outranks a strong but
    /// flimsy one. Used (with the model's surprise judgment) to score the finding for curation.
    var trustStrength: Double {
        abs(partialR) * min(1, nEff / 40) * monotoneAgreement
    }

    /// Order-independent key for the unordered pair `{A, B}`, used for de-duplication and the
    /// persistence-time novelty guard so `{A,B}` and `{B,A}` collapse to one finding.
    var pairKey: String {
        [metricA.rawValue, metricB.rawValue].sorted().joined(separator: "|")
    }

    /// Already-confirmed statistics, phrased for the adversarial skeptic so its "could this be
    /// coincidence?" judgment is grounded in real numbers rather than the prose alone.
    ///
    /// Numbers inform, agents decide: sub-threshold candidates now surface too, so every claim here
    /// is conditional on the flags actually earned — a basis that always recited "survived
    /// correction" would feed the skeptic a falsehood exactly where its scrutiny matters most. The
    /// activity clause is stated only when activity was genuinely partialled out — claiming a control
    /// that didn't happen would mislead the very skeptic meant to catch the activity-halo confound.
    /// The thirds phrased for a reader. States the numbers, not just the verdict, because the
    /// verdict cannot express "it ended" or "it began" — see `thirdsR`. Costs a handful of tokens on
    /// a line that is already sent.
    static func thirdsClause(consistent: Bool, thirds: [Double]) -> String {
        let verdict = consistent
            ? "held its direction across most of the record (not driven by one stretch)"
            : "did NOT hold its direction consistently across the record"
        guard !thirds.isEmpty else { return verdict }
        let byThird = thirds.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        return "\(verdict) — oldest to newest thirds: \(byThird)"
    }

    var verifiedBasis: String {
        let fdrClause = significant
            ? "Survived multiple-comparison correction"
            : String(format: "Did NOT survive multiple-comparison correction (p \u{2248} %.2f)", pValue)
        let thirdsClause = Self.thirdsClause(consistent: consistentAcrossThirds, thirds: thirdsR)
        let coefficientClause = activityControlled
            ? String(
                format: "partial correlation after removing the activity confound \u{2248} %.2f",
                partialR
            )
            : String(format: "correlation of the day-to-day changes \u{2248} %.2f", partialR)
        // Shape, stated. `monotoneAgreement` compares the rank correlation with the linear one, so a
        // low value means the link is carried by a curve or a few extreme days rather than a line —
        // and it already sets 45% of the finding's quality through `trustStrength`. Yet no agent had
        // ever seen it: the skeptic panel is asked, in as many words, "does it rest on a handful of
        // outliers?" and was handed nothing that speaks to the question the engine had already
        // answered. A few tokens on a line that is sent regardless.
        // The legend is worded WITHOUT a numeral, and that is not style. `NumericFidelity` parses
        // every figure in this basis as a verified number that a finding's prose — and now a quoted
        // panelist — may legitimately restate. The old wording was "(1.00 = same shape; …)", an
        // explanatory scale marker, and the checker could not tell it from a measurement: it
        // therefore vouched for 1.00, the single most damaging coefficient anything could claim
        // about two of a person's metrics. Exactly the shape of the bug the checker's own doc
        // records fixing once already, where "a day count was vouching for a correlation".
        let shapeClause = String(
            format: "rank-vs-linear agreement %.2f (near one means the same shape; lower means a "
                + "curve or a few extreme days, not a line)",
            monotoneAgreement
        )
        let core = "\(fdrClause) and \(thirdsClause); \(coefficientClause) over "
            + "~\(Int(nEff.rounded())) effective days; \(shapeClause)."
        guard mechanicallyRedundant else { return core }
        return core + " Caution: these two metrics are mechanically coupled — the link is "
            + "near-tautological, not a discovery."
    }

    func with(significant: Bool) -> MetricCorrelation {
        var copy = self
        copy.significant = significant
        return copy
    }

    func with(pValue newValue: Double) -> MetricCorrelation {
        var copy = self
        copy.pValue = newValue
        return copy
    }

    func with(mechanicallyRedundant: Bool) -> MetricCorrelation {
        var copy = self
        copy.mechanicallyRedundant = mechanicallyRedundant
        return copy
    }
}

/// The single source of truth for turning a correlation coefficient into a plain strength word,
/// shared by the UI strength badge and the model's correlation prompt so the two can never drift
/// apart. Three clearly distinct words — not near-synonyms like "modest"/"moderate" — at the
/// conventional |r| breakpoints.
nonisolated enum CorrelationStrength {
    static func word(absoluteCoefficient absR: Double) -> String {
        switch absR {
        case ..<0.5: "slight"
        case ..<0.7: "moderate"
        default: "strong"
        }
    }
}

/// An **annual rhythm** in a single metric: months that reliably run above or below that year's own
/// level, measured across at least two years (see `SeasonalityScan`). Effects are in standard
/// deviations of the metric's own day-to-day spread, so they compare across metrics and units.
nonisolated struct SeasonalSwing: Equatable, Identifiable {
    let metric: MetricKey
    /// Peak-to-trough distance in the METRIC'S OWN units. Carried alongside the SD figures because
    /// an effect stated only in standard deviations of a nearly-flat residual can read as enormous
    /// while being physically nothing, and the agent cannot tell the difference without this.
    let swingInUnits: Double
    /// 1–12. The month furthest from its year's mean in either direction.
    let peakMonth: Int
    /// Signed, in SDs of daily spread. Positive = that month runs high.
    let peakEffect: Double
    /// The month furthest the OTHER way — the far end of the swing.
    let oppositeMonth: Int
    let oppositeEffect: Double
    /// Months with enough repeat coverage to be compared at all — context for how much of the year
    /// this rhythm is actually built from.
    let monthsCompared: Int
    /// Distinct years contributing to the peak month.
    let yearsObserved: Int
    /// How many of those years moved the SAME way. This is the number that separates a rhythm from
    /// one memorable year, and it is carried rather than gated on: 2-of-3 is a real but qualified
    /// pattern, and that judgment is the agent's.
    let yearsAgreeing: Int

    var id: String {
        metric.rawValue
    }

    /// The full peak-to-trough swing, in SDs.
    var amplitude: Double {
        abs(peakEffect - oppositeEffect)
    }

    /// Names both ends, the size in SDs, and — always — how consistent the years actually were, so
    /// the agent cannot read a swing without also reading how much to trust it.
    var verifiedBasis: String {
        let high = Self.monthName(peakMonth)
        let low = Self.monthName(oppositeMonth)
        let direction = peakEffect >= 0 ? "high" : "low"
        let raw = MetricFormatting.canonical(swingInUnits, metric)
        return String(
            format: "Repeats yearly: %@ runs %@ (%+.2f SD from that year's own de-trended level) "
                + "and %@ sits at %+.2f SD — a %.2f SD swing, which is %@ in real terms, across %d "
                + "months of the year. %d of %d years with %@ data agreed on the direction.",
            high, direction, peakEffect, low, oppositeEffect, amplitude, raw, monthsCompared,
            yearsAgreeing, yearsObserved, high
        )
    }

    /// Month names are fixed English, matching the rest of the agent-facing basis prose — these
    /// strings are read by the model, not shown to the user, and a locale-varying name would make
    /// the same data produce different prompts on different devices.
    static func monthName(_ month: Int) -> String {
        let names = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
        guard month >= 1, month <= names.count else { return "month \(month)" }
        return names[month - 1]
    }
}
