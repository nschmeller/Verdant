import Foundation
import Testing
@testable import Verdant

/// How much `NumericFidelity` actually accepts, measured and pinned.
///
/// This is a CHARACTERIZATION test. It does not assert the band is right — it is not — only that it
/// is known. Every number here was measured, and the checker's own doc had claimed something
/// different for long enough that the claim outlived the code: it said the band around 0.9 and 1.0
/// was removed, "the most damaging fabrication available, a near-perfect link between two of a
/// person's metrics", and 1.00 was accepted.
///
/// The band moves whenever the finding's basis gains a true figure — the per-third coefficients and
/// the rank-vs-linear agreement each widened it, for the honest reason that each is real evidence a
/// finding's prose may legitimately restate. That is exactly why a comment cannot hold this: it goes
/// stale on a change nobody would think to connect to it. A failure here is not necessarily a bug;
/// it means the band moved and the new numbers need reading and re-recording.
struct FidelityBandTests {
    /// A realistic, healthy correlation: significant, activity-controlled, consistent across thirds.
    private var correlation: MetricCorrelation {
        MetricCorrelation(
            metricA: .sleepDurationHours, metricB: .restingHeartRate, lag: 0,
            r: 0.40, partialR: 0.40, spearman: 0.38, n: 90, nEff: 60, pValue: 0.01,
            significant: true, activityControlled: true, consistentAcrossThirds: true,
            thirdsR: [0.42, 0.39, 0.38]
        )
    }

    /// Every two-decimal coefficient a fabricating agent could state, and whether it passes.
    private func acceptedCoefficients() -> [Double] {
        let corr = correlation
        let basis = corr.verifiedBasis
        let verified = [corr.r, corr.partialR, corr.spearman, corr.pValue]
        let counts = [Double(corr.n), Double(corr.nEff)]
        return (0...100).map { Double($0) / 100 }.filter { value in
            NumericFidelity.unsupportedFigures(
                inProse: String(format: "these two are correlated at %.2f", value),
                basis: basis, verified: verified, counts: counts
            ).isEmpty
        }
    }

    @Test func `the accepted band is where it was last measured`() {
        let accepted = acceptedCoefficients()
        print("FIDELITY BAND  \(accepted.count)/101 accepted: "
            + accepted.map { String(format: "%.2f", $0) }.joined(separator: " "))
        #expect(
            accepted.count == 45,
            Comment(rawValue: """
            the band moved to \\(accepted.count)/101 (was 45). Not necessarily a regression — a new \\
            true figure in the basis widens it honestly — but read the new numbers and update the \\
            doc on `NumericFidelity.unsupportedFigures`, which has been wrong about this before.
            """)
        )
    }

    /// The band that matters most, called out separately because a change here is not the same event
    /// as a change anywhere else on the range. A near-perfect coefficient is the most damaging thing
    /// a finding can claim about two of a person's metrics.
    @Test func `the near-perfect band is open, and this is what opens it`() {
        let danger = acceptedCoefficients().filter { $0 >= 0.85 }
        #expect(danger.contains(1.00), "1.00 is no longer accepted — the doc claiming so is now true")
        // p = 0.01 keeps its unit factors so "p is about 1%" reads as supported, and 0.01 x 100 is
        // 1.00. Pinned as the CAUSE: drop the pValue from the verified values and the band closes,
        // which is what makes this the explanation rather than a coincidence.
        let corr = correlation
        let withoutP = NumericFidelity.unsupportedFigures(
            inProse: "these two are correlated at 1.00",
            basis: "partial correlation \u{2248} 0.40 over ~60 effective days",
            verified: [corr.r, corr.partialR, corr.spearman],
            counts: [Double(corr.n), Double(corr.nEff)]
        )
        #expect(!withoutP.isEmpty, "1.00 is rejected once the p-value is not in the pool")
    }

    /// And the legend fix holds: a scale marker in the basis must not vouch for anything. The basis
    /// used to read "rank-vs-linear agreement 0.98 (1.00 = same shape; …)", where the parenthetical
    /// was an explanation and the checker could not tell it from a measurement.
    @Test func `the basis states no scale legend the checker can mistake for a figure`() {
        let basis = correlation.verifiedBasis
        #expect(basis.contains("rank-vs-linear agreement"), "the clause being checked is gone")
        #expect(!basis.contains("1.00 ="), Comment(rawValue: basis))
        #expect(basis.contains("near one"), Comment(rawValue: basis))
    }
}
