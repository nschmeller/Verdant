import Foundation

/// How a finding says where it came from.
///
/// The line under a finding on the detail screen: which investigator lens proposed it, what each
/// panel tallied, and one sentence from a panelist in its own words. Split out of
/// `Orchestrator+Persist.swift` at the file-length limit, and a clean seam — it is pure, it is the
/// only user-facing prose the orchestrator composes itself, and it is what a person reads when they
/// want to know whether to believe a finding.
nonisolated extension Orchestrator {
    /// The one-line record shown on a finding's detail screen: who proposed it, what the panels
    /// tallied, and the most useful thing a panelist actually said. Pure, so the rendering is
    /// test-pinned and the persist path stays a straight line.
    static func provenanceLine(
        lens: String,
        skeptics: PanelOutcome,
        replication: PanelOutcome,
        // The figures the engine computed for this finding, so a quoted panelist can be held to the
        // same standard as the finding it judged. Defaulted for the many tests that build a line
        // without a statistic to hand; production always passes them (`survives`).
        verified: [Double] = [],
        counts: [Double] = [],
        basis: String = ""
    ) -> String {
        var parts: [String] = []
        let trimmed = lens.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed
            .isEmpty
        { parts.append("Proposed by the investigator on \(PromptText.clamped(trimmed, to: 90))")
        }
        parts.append(contentsOf: [
            skeptics.clause("skeptics"), replication.clause("replication analysts")
        ].compactMap(\.self))
        // One quoted sentence, preferring the analysts who re-tested against the DATA over the
        // ones who reasoned about the prose — and only if its numbers are real.
        //
        // `NumericFidelity` has always checked the FINDING's prose for figures nothing supports. It
        // never checked the REVIEWER's, and the reviewer is quoted here, on the detail screen, as
        // the app's own account of why a finding is worth showing. Measured 2026-08-03: a skeptic
        // holds no tools, and one wrote "the confidence interval includes zero" — a statistic no
        // basis in the app states and nothing could compute from prose. Nothing stopped the same
        // invention appearing in a HOLDING verdict and being quoted to the user as justification.
        //
        // Two other figures first cited here as inventions were not: "a shift of 0.1 standard
        // errors" is printed verbatim by `VolatilityShift.verifiedBasis`, and "a correlation of
        // r = 1.0" was a skeptic rebutting a finding that claimed two metrics were perfectly synced.
        // A reviewer quoting the evidence is the reviewer working.
        //
        // Dropping the quote is the right failure: the tallies above already say the panels ran and
        // what they concluded, so the line stays informative, and a missing sentence is a smaller
        // loss than a fabricated statistic presented as the app's reasoning.
        //
        // It inherits `NumericFidelity`'s acceptance band rather than closing it, and that band is
        // wide by its own account — 49 of 101 two-decimal coefficients counted as supported on a
        // typical correlation. Measured: "the shift is 0.1 standard errors" passes against a fixture
        // of 12,000 / 8,000 / 50 / 3.0 / 30. What it does catch is the band the checker was tightened
        // for, "the most damaging fabrication available, a near-perfect link between two of a
        // person's metrics" — which is also what the real skeptics produced ("a correlation of
        // r = 1.0"). A partial guard on the app's own justification, stated as partial.
        let candidates = [replication.headline, skeptics.headline].filter { !$0.isEmpty }
        let quote = candidates.first { candidate in
            NumericFidelity.unsupportedFigures(
                inProse: candidate, basis: basis, verified: verified, counts: counts
            ).isEmpty
        } ?? ""
        var line = parts.joined(separator: " · ")
        if !quote.isEmpty { line += " — “\(PromptText.clamped(quote, to: 160))”" }
        return line
    }
}
