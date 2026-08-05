import Foundation
import Testing
@testable import Verdant

/// A claim that states two averages must say which days each one covers.
///
/// The replication panel exists to re-compute a finding a different way. It cannot re-compute a
/// comparison whose boundary it does not know — and until this clause, nothing told it. A regime
/// shift's basis named the two levels and how long the new one had held, but never where the old
/// one was measured, so an analyst had to guess a baseline window.
///
/// Measured on the first run in which the analysts could reach the data at all (see
/// `MetricVocabularyTests` for why they could not before): of five, two guessed a baseline window
/// that OVERLAPPED the recent period, and both then argued against the claim from the blended
/// number it produced. On a seeded 63 -> 54 bpm step, one reported "the median of the 30-day window
/// (54) is lower than the 60-day baseline (56.1) by 2.1 bpm, which is not [material]" and another
/// "the recent mean of 60 bpm is consistent with the recent mean of 54". Both arithmetics are
/// correct. Both windows were wrong, and neither analyst had any way to know.
///
/// This is plumbing, not a guard: the panel is still free to judge however it likes, but it now
/// judges the comparison the finding actually made.
///
/// UNVERIFIED against the model, and the honest version of why. An A/B was run afterwards with the
/// fixture held constant and the clause as the only difference — and the CONTROL arm did not
/// reproduce the blend, so there was nothing for the treatment arm to fix. (Its five analysts split
/// 3 held / 1 abstained against the clause arm's 1 / 1, which at n=5 per arm, with the planner
/// composing different extra lenses for each, is noise and is not evidence the clause hurts.)
///
/// The observed failure came from a hand-written claim that said "the last 30 days ... the 60 days
/// before that", which invited the 60-day query that blended. The real basis says less than that,
/// not more, so the mechanism is if anything likelier here — but "likelier" is an argument, not a
/// measurement, and the clause costs 129 of the regime basis's remaining budget
/// (`BasisLengthTests`). Kept on the reasoning, not on a result. If it ever needs to give that
/// budget back, this is the note saying no one proved it earned it.
struct ClaimWindowTests {
    private func shift(postDays: Int = 30, caveats: Bool) -> RegimeShift {
        RegimeShift(
            metric: .restingHeartRate, changeDay: Date(), preMean: 63, postMean: 54, score: 2.6,
            postDays: postDays,
            // Under every threshold, so no caveat fires and the clean branch is exercised.
            medianStepSD: caveats ? 0.3 : 0.9,
            maxSegmentTrendR: caveats ? 0.7 : 0.1,
            maxPostGapDays: caveats ? 30 : 2
        )
    }

    @Test func `the basis says which days each average covers`() {
        let basis = shift(caveats: false).verifiedBasis
        #expect(basis.contains("averages every reading since the change"))
        #expect(basis.contains("averages every reading on record before it"))
    }

    /// Both branches, because the caveat list is joined into the same sentence and an earlier version
    /// of this line lived inside `core` — where a firing caveat would have buried it mid-clause.
    @Test func `the windows survive a basis with caveats`() {
        let basis = shift(caveats: true).verifiedBasis
        #expect(basis.contains("caveats:"), "the worst-case branch was not taken")
        #expect(basis.contains("averages every reading since the change"))
        #expect(basis.hasSuffix("before it."), "the windows clause is not the final sentence")
    }

    /// The claim's two figures are the anchor the clause refers to — "the ~54 averages…" is useless
    /// if the basis renders the level as something else. Pins them to the same formatter.
    @Test func `the windows clause names the same two levels the claim states`() {
        let subject = shift(caveats: false)
        let basis = subject.verifiedBasis
        let old = MetricFormatting.canonical(subject.preMean, subject.metric)
        let recent = MetricFormatting.canonical(subject.postMean, subject.metric)
        #expect(basis.contains("The ~\(recent) averages"))
        #expect(basis.contains("the ~\(old) averages"))
    }

    /// It must NOT state a day count for either window. `postDays` is the calendar tenure of the new
    /// level while the means average observations, so for an intermittently-logged metric they
    /// differ — and a day count no engine computed is exactly what `NumericFidelity` flags in prose.
    /// The basis must not be the thing that introduces one.
    @Test func `the windows clause invents no day count`() throws {
        let basis = shift(postDays: 30, caveats: false).verifiedBasis
        let start = try #require(basis.range(of: "The ~"))
        let windows = String(basis[start.lowerBound...])
        #expect(!windows.contains("30"), "the windows clause states a day count: \(windows)")
        #expect(!windows.contains("days"), "the windows clause states a day count: \(windows)")
        // And the tenure is still stated where it was measured, so nothing was lost by leaving it out
        // of the clause.
        #expect(basis.contains("held for 30 days"))
    }
}
