import Foundation

/// Checks whether the figures a finding STATES in its prose are backed by the figures the engines
/// actually computed.
///
/// The app's anti-hallucination story is structural everywhere it can be: the metric and kind are
/// registry-resolved, and every number the card renders is re-read from source at persist time. The
/// one place it never reached is the summary prose, which the model writes freely and the app shows
/// verbatim — guarded only by a `@Guide` sentence asking it to use tool numbers.
///
/// Asking a skeptic to eyeball the digits is the wrong instrument: this whole architecture exists on
/// the premise that a small on-device model is good at judgment and bad at arithmetic. So the
/// comparison is done HERE, deterministically, and the result is handed to the skeptic panel as a
/// FACT — the same division of labour as everywhere else. It does not drop anything: an unsupported
/// figure might be a window reference or a legitimate rounding, and deciding that is the agent's job.
///
/// Pure and `nonisolated`.
nonisolated enum NumericFidelity {
    /// How far a stated figure may sit from a verified one and still count as the same number.
    /// Generous on purpose — prose rounds ("about 12,000" for 11,847) and rounding is honest.
    static let tolerance = 0.05

    /// Unit conversions the app itself performs between what a TOOL returns and what a basis string
    /// PRINTS (`UnitKind.display`): metres → kilometres, and 0–1 fraction → percent. The model reads
    /// raw tool values (`5200`, `0.97`) but the verified basis renders display values (`5.2 km`,
    /// `97%`), so the identical quantity legitimately appears in two forms. Without accepting both,
    /// every distance and percentage metric would flag its own correct figures as invented — and a
    /// check that cries wolf on a dozen metrics teaches the panel to ignore it, which is worse than
    /// not checking. Deliberately only these factors, not "any power of ten": a fabricated number
    /// that happens to be 1000× a real one is possible but rare, and the alternative is a check so
    /// loose it stops meaning anything.
    static let unitFactors: [Double] = [1, 1000, 0.001, 100, 0.01]

    /// Figures in `prose` that nothing verified supports, in the form they were written.
    ///
    /// `verified` is the finding's actual computed values and is the primary source; `basis` is the
    /// prose summary the panel is shown, parsed for whatever figures it happens to render. BOTH are
    /// needed, and assuming the basis alone was enough was a real bug: `VerifiedFact.verifiedBasis`
    /// says "a ~48% shift over 7 days, about 6.1 standard deviations" and never prints the recent or
    /// baseline means — the very numbers a trend finding's prose is most likely to quote. Checking
    /// against the summary alone would have flagged correct figures as invented on the app's most
    /// common finding kind.
    ///
    /// Empty when the prose states no numbers, or when there is nothing verified to check against
    /// (saying "unsupported" with nothing to compare to is a false accusation, not a finding).
    /// `counts` are dimensionless — sample sizes, lags, years compared. They are matched at face
    /// value ONLY, never through `unitFactors`, because a count is never restated in another unit and
    /// expanding it does real harm.
    ///
    /// Measured with a typical correlation (r 0.40, n 90, nEff 60, p 0.01): 49 of the 101 possible
    /// two-decimal coefficients were accepted as supported — 48% of the range, where honest rounding
    /// justifies about ten of them. `n = 90` times the 0.01 factor put a candidate at 0.9, so a
    /// fabricated "these two are correlated at 0.9" passed unremarked on a finding whose real
    /// coefficient was 0.40. A day count was vouching for a correlation.
    ///
    /// This does not close the hole entirely and is not meant to look as though it does. Figures
    /// parsed from the basis keep their unit factors (see below), and the basis renders `nEff`, so a
    /// band around 0.6 survives.
    ///
    /// **It also no longer removes the band around 0.9 and 1.0, and this doc claimed it did.**
    /// Re-measured 2026-08-03 on a realistic correlation (r 0.40, n 90, nEff 60, p 0.01): 45 of 101
    /// two-decimal coefficients accepted, and 0.93 through 1.00 among them — including 1.00 exactly,
    /// the most damaging thing anything could claim about two of a person's metrics.
    ///
    /// Two sources, found by measuring rather than reasoning. The basis stated the rank-vs-linear
    /// agreement with a scale LEGEND, "(1.00 = same shape; …)", and a legend is indistinguishable
    /// from a measurement to this function — so an explanatory marker was vouching for 1.00. That is
    /// fixed at the source (`MetricCorrelation.verifiedBasis` now says "near one").
    ///
    /// The second is inherent and is left alone: `pValue` keeps its unit factors deliberately, so
    /// that "p is about 1%" for 0.01 reads as supported — and 0.01 x 100 is 1.00, which then vouches
    /// for a bare "correlated at 1.00" on ANY strongly significant finding. The same shape as the day
    /// count that used to vouch for a coefficient, and it cannot be fixed by dropping the factor
    /// without rejecting the legitimate restatement it exists for. Telling "1%" from "1.00" needs the
    /// checker to read context, which is a real change to the app's most safety-relevant arithmetic
    /// and belongs to whoever decides that trade — not to a comment correcting itself.
    ///
    /// The figure this doc used to quote (78 of 101 falling to 66) was measured before the basis
    /// gained the per-third coefficients and the agreement clause. Re-measure before trusting any
    /// number here; the acceptance band moves whenever the basis gains a true figure.
    ///
    /// The residue is less alarming than it sounds: most of what remains is honest coverage of
    /// figures that really are in the evidence, each within 5%. Adding the per-third coefficients to
    /// the basis widened acceptance by about thirty values for exactly that reason — three more true
    /// numbers, not three more holes.
    static func unsupportedFigures(
        inProse prose: String,
        basis: String,
        verified verifiedValues: [Double] = [],
        counts: [Double] = []
    ) -> [String] {
        // `scalable` gets the unit-factor treatment: a stored measurement really may be restated in
        // another unit (8.4 km for 8,400 m, 97 for 0.97), and that applies to figures parsed from the
        // basis as much as to the caller's own — a basis prints "5.2 km" for a stored 5,200.
        //
        // `exact` is matched at face value only. Counts go here.
        //
        // Confining basis figures to `exact` too was tried and reverted. It bought real precision
        // (accepted fabrications on a typical correlation fell from 66 of 101 to 52), and it rested
        // on "every route passes its unit-bearing values explicitly", which is true of all six today.
        // But it turned a general function into one that silently under-reports for any caller that
        // passes only a basis — a documented, sensible use with its own test — and traded a standing
        // safeguard for a bounded gain. The count fix below needs no such bargain.
        let scalable = numbers(in: basis).map(\.value) + verifiedValues
        guard !scalable.isEmpty || !counts.isEmpty else { return [] }
        var unsupported: [String] = []
        for stated in numbers(in: prose) {
            let matches = { (candidate: Double) in
                abs(stated.value - candidate) <= tolerance * Swift.max(abs(candidate), 1)
            }
            let supported = scalable.contains { value in
                unitFactors.contains { matches(value * $0) }
            } || counts.contains(where: matches)
            guard !supported else { continue }
            // Report it as written, including a trailing % — "47%" and "47" are very different
            // claims, and the panel needs to see which one it is looking at.
            let asWritten = prose.contains("\(stated.text)%") ? "\(stated.text)%" : stated.text
            if !unsupported.contains(asWritten) { unsupported.append(asWritten) }
        }
        return unsupported
    }

    /// Every numeric token in `text`, with the literal form and its value. Handles thousands
    /// separators and decimals, and discards trailing punctuation so "12,000." at the end of a
    /// sentence reads as 12000 rather than failing to parse.
    ///
    /// **Calendar dates are removed first, and that is load-bearing in both directions.** A basis
    /// line naming the day a spike happened ("… on 2026-07-17 …") otherwise contributes 2026, 07 and
    /// 17 to the pool of VERIFIED values, so a model writing "steps rose 17%" would be judged
    /// supported by a day-of-month — a false negative in the one check that exists to catch invented
    /// figures. Read the other way, a date the model quotes in its prose is not a statistic and must
    /// not be reported as an unsupported figure either. Dates are not numbers here.
    static func numbers(in text: String) -> [(text: String, value: Double)] {
        let text = text.replacing(/\d{4}-\d{2}-\d{2}/, with: " ")
        var found: [(text: String, value: Double)] = []
        var current = ""

        func flush() {
            while let last = current.last, last == "." || last == "," {
                current.removeLast()
            }
            defer { current = "" }
            guard !current.isEmpty,
                  let value = Double(current.replacingOccurrences(of: ",", with: "")) else { return }
            found.append((text: current, value: value))
        }

        for character in text {
            if character.isNumber || ((character == "." || character == ",") && !current.isEmpty) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }
}
