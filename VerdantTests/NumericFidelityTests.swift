import Foundation
import Testing
@testable import Verdant

/// The last hole in the app's anti-hallucination story. The metric is registry-resolved and the
/// card's figures are re-read from source — but the summary PROSE is free text the model writes and
/// the app shows verbatim, and until now the only thing stopping an invented statistic was a
/// `@Guide` sentence asking it not to. This computes which stated figures nothing verified backs;
/// the skeptic panel rules on them.
struct NumericFidelityTests {
    private let basis = "Steps averaged 11,847 over the last 7 days versus 8,020 for the prior "
        + "30 days (+47.7%), z = 6.1"

    @Test func `an invented statistic is reported`() {
        let prose = "Your steps climbed 91% over the past week — a striking jump."
        #expect(NumericFidelity.unsupportedFigures(inProse: prose, basis: basis) == ["91%"])
    }

    /// Prose rounds, and rounding is honest. A check that flagged "about 12,000" for 11,847 would
    /// train the panel to ignore it.
    @Test func `honest rounding of a verified figure is not flagged`() {
        let prose = "Your steps averaged about 12,000 recently, up from roughly 8,000 before — "
            + "a rise of nearly 48%."
        #expect(NumericFidelity.unsupportedFigures(inProse: prose, basis: basis).isEmpty)
    }

    /// The `%` travels with the figure: "47" and "47%" are very different claims and the panel has
    /// to see which one it is judging.
    @Test func `a figure is reported as written, percent sign included`() {
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "It rose 12% while resting heart rate sat at 12.", basis: "…averaged 900 over 5 days"
        )
        #expect(unsupported == ["12%"]) // one value, reported in the form that states a rate
    }

    @Test func `prose with no figures, and a claim with no basis, are both silent`() {
        #expect(NumericFidelity.unsupportedFigures(
            inProse: "Your sleep steadied noticeably this month.", basis: basis
        ).isEmpty)
        // No verified numbers to compare against: saying "unsupported" would be a false accusation.
        #expect(NumericFidelity.unsupportedFigures(
            inProse: "Your steps climbed 91%.", basis: "no numbers here"
        ).isEmpty)
    }

    /// The app converts metres to kilometres and fractions to percent for display, so a tool hands
    /// the model `5200` while the verified basis prints `5.2 km`. Same quantity, different unit —
    /// flagging that would cry wolf on every distance and percentage metric, and a check that cries
    /// wolf is a check the panel learns to ignore.
    @Test func `a figure stated in the other unit the app uses is not called invented`() {
        let distance = "You covered about 5,200 metres on your longest day."
        #expect(NumericFidelity.unsupportedFigures(
            inProse: distance, basis: "Longest daily distance 5.2 km over the last 30 days"
        ).isEmpty)

        let oxygen = "Blood oxygen sat at 0.97 through the week."
        #expect(NumericFidelity.unsupportedFigures(
            inProse: oxygen, basis: "Averaged 97% across 7 days"
        ).isEmpty)

        // The allowance is unit conversion, not a blank cheque: an unrelated figure still flags.
        #expect(NumericFidelity.unsupportedFigures(
            inProse: "You covered 8,400 metres.", basis: "Longest daily distance 5.2 km"
        ) == ["8,400"])
    }

    /// Built from a REAL `VerifiedFact.verifiedBasis`, not a fixture string — which is how the
    /// previous bug hid. That basis prints only "a ~48% shift over 7 days, about 6.1 standard
    /// deviations"; it never renders the means. A trend finding's prose quotes the means, so
    /// checking against the summary alone flagged correct figures as invented on the app's most
    /// common finding kind. The computed values are now passed alongside it.
    @Test func `a trend finding's means are supported even though the basis never prints them`() {
        let fact = VerifiedFact(
            metric: .stepCount, comparison: .recentVsBaseline,
            recent: 11847, baseline: 8020, pctChange: 47.7, z: 6.1, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: 80
        )
        let prose = "Your steps averaged 11,847 over the last 7 days against 8,020 before — "
            + "a 47.7% rise, about 6.1 standard deviations above your usual movement."

        // The summary alone does not contain the means, so it alone would condemn them.
        let basisOnly = NumericFidelity.unsupportedFigures(inProse: prose, basis: fact.verifiedBasis)
        #expect(basisOnly.contains("11,847"))

        // With the finding's actual computed values, nothing is flagged.
        #expect(NumericFidelity.unsupportedFigures(
            inProse: prose,
            basis: fact.verifiedBasis,
            verified: [fact.recent, fact.baseline, fact.pctChange, fact.z, Double(fact.n)]
        ).isEmpty)

        // And a figure that is in neither still is.
        #expect(NumericFidelity.unsupportedFigures(
            inProse: prose + " Resting heart rate sat at 312.",
            basis: fact.verifiedBasis,
            verified: [fact.recent, fact.baseline, fact.pctChange, fact.z, Double(fact.n)]
        ) == ["312"])
    }

    @Test func `numbers parse through separators and sentence punctuation`() {
        let parsed = NumericFidelity.numbers(in: "Totals were 11,847 and 8.5, then 6.")
        #expect(parsed.map(\.text) == ["11,847", "8.5", "6"])
        #expect(parsed.map(\.value) == [11847, 8.5, 6])
    }

    /// A day label in the basis must not lend its digits to the model. `UnusualDaysScan` names the
    /// day a spike happened, so before this the basis "… on 2026-07-17 …" put 2026, 07 and 17 into
    /// the VERIFIED pool — and a story claiming "steps rose 17%" was then judged supported by a
    /// day-of-month. That is a false negative in the only check that catches invented figures.
    @Test func `a date in the basis does not verify a number in the prose`() {
        let basis = "Step Count 8400 steps on 2026-07-17 — 3.2σ above its usual 6100 steps"
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "Your steps rose 17% this week.", basis: basis
        )
        #expect(unsupported == ["17%"], "the day-of-month verified an invented figure")

        // The year is just as available to be misused.
        #expect(!NumericFidelity.unsupportedFigures(
            inProse: "A rise of 2026 steps.", basis: basis
        ).isEmpty)

        // And the real numbers in that same basis still verify correctly.
        #expect(NumericFidelity.unsupportedFigures(
            inProse: "Steps hit 8400, well above the usual 6100.", basis: basis
        ).isEmpty)
    }

    /// The other direction: a date the model quotes is not a statistic, so it must not be reported
    /// as an unsupported figure. Flagging it would send the skeptic panel after a correct sentence.
    @Test func `a date in the prose is not reported as an unsupported figure`() {
        let basis = "Step Count 8400 steps on 2026-07-17 — 3.2σ above its usual 6100 steps"
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "On 2026-07-17 your steps reached 8400.", basis: basis
        )
        #expect(unsupported.isEmpty, "flagged: \(unsupported)")
    }
}
