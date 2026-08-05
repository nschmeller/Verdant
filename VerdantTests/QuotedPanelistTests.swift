import Foundation
import Testing
@testable import Verdant

/// A panelist quoted to the user is held to the same numeric standard as the finding it judged.
///
/// `NumericFidelity` has always checked the FINDING's prose for figures nothing supports. It never
/// checked the REVIEWER's — and the reviewer's own sentence is quoted on the detail screen as the
/// app's account of why a finding is worth showing.
///
/// That gap is not theoretical. Measured against the real model on 2026-08-03, a skeptic — holding
/// no tools — wrote "the confidence interval includes zero", a statistic no basis in the app states
/// and nothing could compute from prose. Nothing stopped the same invention appearing in a HOLDING
/// verdict on a finding that survived, and being printed underneath it as justification.
///
/// The first version of this doc listed two further examples that turned out to be the panel working
/// correctly: "a shift of 0.1 standard errors from no-change" is printed verbatim by
/// `VolatilityShift.verifiedBasis`, and "a correlation of r = 1.0" was a skeptic rebutting a finding
/// claiming two metrics were perfectly synced. The guard below is worth having for the one real
/// case; it is not worth overstating for three.
///
/// Dropping the quote is the right failure. The tallies stay, so the line still says the panels ran
/// and what they concluded; a missing sentence is a far smaller loss than a fabricated statistic
/// presented as the app's own reasoning.
struct QuotedPanelistTests {
    private func outcome(_ why: String, holds: Bool = true) -> PanelOutcome {
        PanelOutcome([Verdict(why: why, couldTest: true, holdsUp: holds)])
    }

    /// The verified figures behind a typical trend finding: recent 12000, baseline 8000, +50%, z 3.
    private let verified: [Double] = [12000, 8000, 50, 3]
    private let counts: [Double] = [30]
    private let basis = "Recent 12,000 steps vs 8,000 baseline (+50%), 3.0 standard deviations over 30 days."

    private func line(skeptic: String, replication: String = "") -> String {
        Orchestrator.provenanceLine(
            lens: "activity and energy",
            skeptics: outcome(skeptic),
            replication: replication.isEmpty ? .notConvened : outcome(replication),
            verified: verified, counts: counts, basis: basis
        )
    }

    /// The fabrication class this actually catches, and the one the real model produced: a
    /// near-perfect coefficient. `NumericFidelity`'s own doc is explicit that its acceptance band is
    /// wide — 49 of 101 two-decimal coefficients counted as supported on a typical correlation — and
    /// what it was tightened to remove is exactly the band around 0.9 and 1.0, "the most damaging
    /// fabrication available, a near-perfect link between two of a person's metrics".
    ///
    /// So this guard inherits that band rather than closing it. Measured while writing this suite:
    /// "the shift is 0.1 standard errors" — a real skeptic's words — is ACCEPTED against a fixture
    /// whose figures are 12,000 / 8,000 / 50 / 3.0 / 30. The first version of this test asserted it
    /// would be dropped, which was a claim about the checker nobody had measured.
    @Test func `a quote inventing a coefficient is dropped`() {
        let text = line(skeptic: "The two are correlated at 0.97 across the whole record.")
        #expect(!text.contains("0.97"), Comment(rawValue: text))
        #expect(!text.contains("“"), Comment(rawValue: text))
        // The tally survives, so the line still reports that the panel ran.
        #expect(text.contains("skeptics held it up"), Comment(rawValue: text))
    }

    /// The common case — most verdicts are prose. Nothing to check means nothing to drop.
    @Test func `a quote with no figures is kept`() {
        let reason = "The effect is large and holds across the whole record, not one stretch."
        #expect(line(skeptic: reason).contains(reason), Comment(rawValue: line(skeptic: reason)))
    }

    /// A reviewer citing the finding's REAL numbers is exactly what the provenance line is for, and
    /// must survive — a check that dropped every quote containing a digit would be no better than
    /// the fabrication it replaces.
    @Test func `a quote citing the verified numbers is kept`() {
        let reason = "A 50% rise over 30 days at 3.0 standard deviations is not noise."
        let text = line(skeptic: reason)
        #expect(text.contains(reason), Comment(rawValue: text))
    }

    /// The replication analyst is preferred — it re-tested against DATA — but only while its own
    /// numbers hold up. When they do not, the skeptic's sentence is used rather than none.
    @Test func `a fabricating analyst yields to a sound skeptic`() {
        let text = line(
            skeptic: "A 50% rise over 30 days is not noise.",
            replication: "Re-computed at r = 0.97 across every window."
        )
        #expect(!text.contains("0.97"), Comment(rawValue: text))
        #expect(text.contains("A 50% rise over 30 days is not noise."), Comment(rawValue: text))
    }

    /// Non-vacuity: with no verified numbers supplied — every existing caller, and the many tests
    /// that build a line without a statistic — nothing is dropped. The check must not quietly
    /// silence every quote in the app the moment it was added.
    @Test func `without verified numbers the quote is untouched`() {
        let reason = "Re-computed at r = 0.97 across every window."
        let text = Orchestrator.provenanceLine(
            lens: "a lens", skeptics: outcome(reason), replication: .notConvened
        )
        #expect(text.contains(reason), Comment(rawValue: text))
    }
}
