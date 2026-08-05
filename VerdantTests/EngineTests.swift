import Foundation
import Testing
@testable import Verdant

/// The `verifiedBasis` strings are what the adversarial skeptic reasons WITH (grounding its
/// "could this be noise?" judgment in real numbers). Lock their key figures against format drift.
struct VerifiedBasisTests {
    @Test func `single-metric basis states the effect size`() {
        let fact = VerifiedFact(
            metric: .stepCount, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 3, n: 30,
            kind: .trend, direction: .up, magnitude: .moderate, salience: 60
        )
        let basis = fact.verifiedBasis
        #expect(basis.contains("50%"))
        #expect(basis.contains("30 days"))
        #expect(basis.contains("3.0 standard deviations"))
    }

    @Test func `correlation basis claims the activity control only when it happened`() {
        let controlled = MetricCorrelation(
            metricA: .sleepDurationHours, metricB: .restingHeartRate, lag: 0,
            r: 0.6, partialR: 0.55, spearman: 0.58, n: 60, nEff: 42, pValue: 0.001,
            significant: true, activityControlled: true
        )
        #expect(controlled.verifiedBasis.contains("0.55"))
        #expect(controlled.verifiedBasis.contains("42 effective days"))
        #expect(controlled.verifiedBasis.contains("removing the activity confound"))

        // A pair that includes activity (or a user without activity data): the basis must NOT claim
        // an activity control that never happened.
        let uncontrolled = MetricCorrelation(
            metricA: .activeEnergyBurned, metricB: .restingHeartRate, lag: 0,
            r: 0.5, partialR: 0.5, spearman: 0.5, n: 60, nEff: 40, pValue: 0.001,
            significant: true, activityControlled: false
        )
        #expect(!uncontrolled.verifiedBasis.contains("removing the activity confound"))
        #expect(uncontrolled.verifiedBasis.contains("day-to-day changes"))
    }

    @Test func `correlation basis is honest about sub-threshold candidates`() {
        // Sub-threshold pairs now surface for the agents to judge; the basis must state what the
        // numbers actually earned — reciting the strongest-case claims would feed the skeptic a
        // falsehood exactly where its scrutiny matters most.
        let weak = MetricCorrelation(
            metricA: .sleepDurationHours, metricB: .restingHeartRate, lag: 0,
            r: 0.2, partialR: 0.15, spearman: 0.14, n: 40, nEff: 30, pValue: 0.4,
            significant: false, activityControlled: true, consistentAcrossThirds: false
        )
        #expect(weak.verifiedBasis.contains("NOT survive"))
        #expect(weak.verifiedBasis.contains("0.40")) // the real p-value the skeptic weighs
        #expect(weak.verifiedBasis.contains("did NOT hold its direction"))

        // A mechanically coupled pair must carry the anti-tautology caution.
        let redundant = MetricCorrelation(
            metricA: .stepCount, metricB: .distanceWalkingRunning, lag: 0,
            r: 0.99, partialR: 0.99, spearman: 0.99, n: 40, nEff: 30, pValue: 0.001,
            significant: false, mechanicallyRedundant: true
        )
        #expect(redundant.verifiedBasis.contains("mechanically coupled"))

        // And a fully-earned finding still reads as one — no caution, no hedges.
        let earned = MetricCorrelation(
            metricA: .sleepDurationHours, metricB: .restingHeartRate, lag: 0,
            r: 0.6, partialR: 0.55, spearman: 0.58, n: 60, nEff: 42, pValue: 0.001,
            significant: true, activityControlled: true
        )
        #expect(earned.verifiedBasis.contains("Survived multiple-comparison correction"))
        #expect(earned.verifiedBasis.contains("held its direction"))
        #expect(!earned.verifiedBasis.contains("mechanically coupled"))
    }

    @Test func `regime basis marks the held duration as durable when the evidence is clean`() {
        let shift = RegimeShift(
            metric: .restingHeartRate, changeDay: Date(timeIntervalSince1970: 1_700_000_000),
            preMean: 60, postMean: 54, score: 1.4, postDays: 45,
            medianStepSD: 0.9, maxSegmentTrendR: 0.1, maxPostGapDays: 1
        )
        let basis = shift.verifiedBasis
        #expect(basis.contains("45 days"))
        #expect(basis.lowercased().contains("not a transient blip"))
    }

    @Test func `regime basis carries the caveats the old guards enforced silently`() {
        // Candidates the scan used to DROP now surface; the skeptic must see WHY each was suspect —
        // the "numbers inform, agents decide" contract. Each caveat clause maps to one old guard.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var swap = RegimeShift(
            metric: .restingHeartRate, changeDay: base,
            preMean: 60, postMean: 54, score: 1.4, postDays: 45,
            medianStepSD: 0.9, maxSegmentTrendR: 0.1, maxPostGapDays: 1
        )
        swap.suspectedDeviceSwap = true
        #expect(swap.verifiedBasis.contains("possible device change"))

        let spiky = RegimeShift(
            metric: .restingHeartRate, changeDay: base,
            preMean: 55, postMean: 60, score: 1.3, postDays: 20,
            medianStepSD: 0.1, maxSegmentTrendR: 0.1, maxPostGapDays: 1
        )
        #expect(spiky.verifiedBasis.contains("outlier days")) // weak median echo (old anti-spike)

        let ramp = RegimeShift(
            metric: .bodyMass, changeDay: base,
            preMean: 80, postMean: 84, score: 2.0, postDays: 50,
            medianStepSD: 1.0, maxSegmentTrendR: 0.95, maxPostGapDays: 1
        )
        #expect(ramp.verifiedBasis.contains("trends internally")) // drift, not step (old anti-ramp)

        let gappy = RegimeShift(
            metric: .restingHeartRate, changeDay: base,
            preMean: 50, postMean: 60, score: 5.0, postDays: 64,
            medianStepSD: 2.0, maxSegmentTrendR: 0.1, maxPostGapDays: 31
        )
        #expect(gappy.verifiedBasis.contains("31-day unobserved stretch")) // old calendar-density guard
        // A caveated shift must not simultaneously claim durability.
        #expect(!gappy.verifiedBasis.lowercased().contains("not a transient blip"))
    }

    @Test func `regime basis applies the display transform so the skeptic sees the same scale as the story`() {
        // preMean/postMean are raw stored values. For a percent metric they're a 0–1 fraction; printing
        // them raw rounded a real step (0.97→0.94) to "~1 to ~1" — a non-step that contradicts the prose
        // the skeptic is judging. The basis must show the displayed value (×100, with the unit).
        let oxygen = RegimeShift(
            metric: .oxygenSaturation, changeDay: Date(timeIntervalSince1970: 1_700_000_000),
            preMean: 0.97, postMean: 0.94, score: 1.5, postDays: 30,
            medianStepSD: 0.9, maxSegmentTrendR: 0.1, maxPostGapDays: 1
        )
        #expect(oxygen.verifiedBasis.contains("97%"))
        #expect(oxygen.verifiedBasis.contains("94%"))
        #expect(!oxygen.verifiedBasis.contains("~1 to ~1")) // the pathological raw rendering is gone
        // Distance is stored in meters but read in km, like the prose.
        let distance = RegimeShift(
            metric: .distanceWalkingRunning, changeDay: Date(timeIntervalSince1970: 1_700_000_000),
            preMean: 5000, postMean: 6000, score: 1.3, postDays: 30,
            medianStepSD: 0.9, maxSegmentTrendR: 0.1, maxPostGapDays: 1
        )
        #expect(distance.verifiedBasis.contains("5.0 km"))
        #expect(distance.verifiedBasis.contains("6.0 km"))
        #expect(!distance.verifiedBasis.contains("5000")) // not the raw meters
    }

    @Test func `volatility basis reports the mean clause accurately`() {
        // Mean held (recent 8.0 vs baseline 8.1): the basis must say so.
        let held = VolatilityShift(
            metric: .sleepDurationHours, recentSD: 2.0, baselineSD: 1.0,
            recentMean: 8.0, baselineMean: 8.1, cvRatio: 2.0, seZ: 3.4, n: 30
        )
        #expect(held.verifiedBasis.contains("while the average barely moved"))
        // Mean ALSO shifted (6.0 vs 8.0): the basis must NOT claim the average held.
        let shifted = VolatilityShift(
            metric: .sleepDurationHours, recentSD: 2.0, baselineSD: 1.0,
            recentMean: 6.0, baselineMean: 8.0, cvRatio: 2.0, seZ: 3.4, n: 30
        )
        #expect(shifted.verifiedBasis.contains("the average also shifted"))
        #expect(!shifted.verifiedBasis.contains("barely moved"))
    }

    @Test func `volatility basis states the seZ uncertainty for strong and flimsy shifts alike`() {
        // The scan no longer drops sub-threshold candidates, so the basis must hand the skeptic the
        // uncertainty statistic the old 2-SE gate used — rounded, for strong AND flimsy shifts.
        let strong = VolatilityShift(
            metric: .sleepDurationHours, recentSD: 2.0, baselineSD: 1.0,
            recentMean: 8.0, baselineMean: 8.1, cvRatio: 2.0, seZ: 3.42, n: 30
        )
        #expect(strong.verifiedBasis.contains("3.4 standard errors from no-change"))
        let flimsy = VolatilityShift(
            metric: .sleepDurationHours, recentSD: 1.1, baselineSD: 1.0,
            recentMean: 8.0, baselineMean: 8.1, cvRatio: 1.1, seZ: 0.77, n: 5
        )
        #expect(flimsy.verifiedBasis.contains("0.8 standard errors from no-change"))
    }

    @Test func `volatility basis describes the raw-SD swing, not the CV ratio`() {
        // Mean doubled (8 → 16) with raw SD up 35%: by CV the metric looks STEADIER (~0.68×), by raw
        // day-to-day swing it's MORE erratic (~1.35×). The basis must speak the SAME SD language as
        // the card and the phraser — never the CV ratio — so the skeptic isn't handed a basis that
        // contradicts the story it's judging (the regression this guards against).
        let shift = VolatilityShift(
            metric: .sleepDurationHours, recentSD: 1.35, baselineSD: 1.0,
            recentMean: 16, baselineMean: 8, cvRatio: 0.675, seZ: 1.5, n: 30
        )
        #expect(shift.sdRatio > 1) // more erratic by raw swing, even though cvRatio < 1
        #expect(shift.verifiedBasis.contains("swing")) // SD framing
        #expect(!shift.verifiedBasis.contains("consistency ratio")) // old CV framing is gone
        #expect(shift.verifiedBasis.contains("the average also shifted"))
    }
}

/// The digest interleaves the per-horizon entry lists so a downstream cap can't starve the
/// long-horizon lens (the recency bias the multi-horizon digest exists to prevent).
struct DigestRoundRobinTests {
    @Test func `interleaves columns by rank`() {
        let result = HealthDigestBuilder.roundRobin([[1, 2, 3], [10, 20], [100]])
        #expect(result == [1, 10, 100, 2, 20, 3])
    }

    @Test func `a downstream cap keeps each horizon roughly evenly`() {
        // Three horizons of 6 each; a 14-cap must not take 6+6+2 (starving the third).
        let recent = Array(0..<6)
        let yearOverYear = Array(10..<16)
        let allTime = Array(100..<106)
        let capped = Array(HealthDigestBuilder.roundRobin([recent, yearOverYear, allTime]).prefix(14))
        let fromAllTime = capped.count(where: { $0 >= 100 })
        // Round-robin gives 5/5/4, so the long-horizon lens keeps at least 4 — never just 2.
        #expect(fromAllTime >= 4)
    }
}

/// The model-facing digest text, which is the first thing a scout or investigator reads and the only
/// whole-picture view any agent gets.
///
/// It used to be prose — "Steps: moderately higher (vs. a year ago)" — and these tests pinned its
/// grammar. The grammar was fine; the content was the problem. Bucketing the standardized move at
/// 1.5 and 3 made 1.6 and 2.9 identical, and 3.0 and 12.0 identical, on a list that is SORTED by
/// exactly the number it was hiding. Deciding what counts as a big move is the agent's job, and it
/// was being handed the answer instead of the evidence.
///
/// So these now pin the figures: that they appear, that a fall keeps its sign, that a small move
/// does not round away, and that two moves which shared a bucket no longer read the same.
struct HealthDigestRenderTests {
    @Test func `a move renders its figures, not an adverb`() {
        let digest = HealthDigest(entries: [
            HealthDigest.Entry(
                metric: .stepCount, comparison: .yearOverYear,
                pctChange: 18.42, z: 2.13, sampleCount: 90
            )
        ], recentInsightKinds: [])
        let text = digest.renderedText()
        #expect(text.contains("+18.4%"), Comment(rawValue: text))
        #expect(text.contains("2.1 SD"), Comment(rawValue: text))
        #expect(text.contains("n=90"), Comment(rawValue: text))
        #expect(text.contains("vs. a year ago"), Comment(rawValue: text))
    }

    /// The sign carries the direction, so a fall must render as one — a dropped minus would invert
    /// every downward finding the agent reads, silently and for every metric at once.
    @Test func `a fall renders with a minus sign`() {
        let digest = HealthDigest(entries: [
            HealthDigest.Entry(
                metric: .restingHeartRate, comparison: .recentVsBaseline,
                pctChange: -14.3, z: -2.6, sampleCount: 30
            )
        ], recentInsightKinds: [])
        let text = digest.renderedText()
        #expect(text.contains("-14.3%"), Comment(rawValue: text))
        // The SD figure is unsigned: it would be a second, redundant sign on the same fact, and a
        // "-2.6 SD" beside a "-14.3%" reads as two separate falls.
        #expect(text.contains("2.6 SD"), Comment(rawValue: text))
        #expect(!text.contains("-2.6 SD"), Comment(rawValue: text))
    }

    /// A small move must not round to nothing. `%+.0f` would print "+0%" for a real 0.4% change, and
    /// an agent reading zero has been told the metric did not move.
    @Test func `a small move keeps its figure`() {
        let digest = HealthDigest(entries: [
            HealthDigest.Entry(
                metric: .restingHeartRate, comparison: .recentVsBaseline,
                pctChange: 0.4, z: 0.18, sampleCount: 30
            )
        ], recentInsightKinds: [])
        let text = digest.renderedText()
        #expect(text.contains("+0.4%"), Comment(rawValue: text))
        #expect(!text.contains("+0%"), Comment(rawValue: text))
    }

    /// The digest is a tool RESULT, not a session prefix, so it costs nothing until it is called —
    /// but it is called first by every scout and investigator, out of the ~2,000 tokens their 4k
    /// window has left after the prefix. Bounded, and printed, for the same reason the basis lines
    /// are: five cheap clauses is how a budget goes.
    ///
    /// Measured 2026-08-03: 964 characters for a full 14-entry digest, roughly 240 tokens. That is
    /// about three characters per line MORE than the adverb form it replaced —
    /// "- Resting heart rate: -14.3% (2.6 SD, n=30) vs. your recent norm" against
    /// "- Resting heart rate: moderately lower (vs. your recent norm)" — because dropping the
    /// magnitude adverb and the direction word very nearly paid for the three figures. Three
    /// numbers for three characters a line was not obviously on offer in advance; had it cost
    /// meaningfully more, it would still have been worth it, but this bound is what says it didn't.
    @Test func `the full digest stays within its budget`() {
        let entries = (0..<14).map { index in
            HealthDigest.Entry(
                metric: MetricKey.allCases[index % MetricKey.allCases.count],
                comparison: .recentVsBaseline,
                pctChange: -14.3, z: -2.6, sampleCount: 30
            )
        }
        let text = HealthDigest(
            entries: entries, recentInsightKinds: ["trend", "correlation", "regimeShift"]
        ).renderedText()
        print("DIGEST BUDGET  \(text.count) characters over \(entries.count) entries")
        #expect(text.count < 1400, Comment(rawValue: "the digest is \(text.count) characters"))
        // Non-vacuity: every entry rendered, so the bound is measuring a full digest.
        #expect(text.components(separatedBy: "\n").count == entries.count + 1)
    }

    /// The whole point of the change: two moves inside one old bucket must now be distinguishable.
    /// Both 1.6 and 2.9 rendered as "moderately", which is what left the agent unable to rank the
    /// list it was being handed in ranked order.
    @Test func `two moves that shared a bucket now read differently`() {
        func line(z: Double, pct: Double) -> String {
            HealthDigest(entries: [
                HealthDigest.Entry(
                    metric: .stepCount, comparison: .recentVsBaseline,
                    pctChange: pct, z: z, sampleCount: 30
                )
            ], recentInsightKinds: []).renderedText()
        }
        #expect(line(z: 1.6, pct: 8) != line(z: 2.9, pct: 15))
    }
}

struct FindingPhrasingTests {
    @Test func `standard phrasing describes direction and metric`() {
        let fact = VerifiedFact(
            metric: .stepCount, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 5, n: 7,
            kind: .trend, direction: .up, magnitude: .moderate, salience: 60
        )
        let phrasing = FindingPhrasing.phrasing(for: fact)
        #expect(phrasing.summary.contains("higher"))
        #expect(phrasing.summary.lowercased().contains("steps"))
        #expect(phrasing.oneTapTitle.contains("Steps"))
    }
}
