import Foundation
import Testing
@testable import Verdant

/// The per-third correlations, and the blind spot they exist to close.
///
/// `consistentAcrossThirds` asks whether the sign reproduced in at least two of three chronological
/// thirds. That is the right question for "is this one lucky stretch?" and it cannot answer "is this
/// still true?" — the two most interesting things a relationship can do are END and BEGIN, and the
/// flag reports the first as consistent and the second as unreliable. Exactly backwards, on exactly
/// the findings a person has no way to see for themselves.
///
/// The fix is not a better rule. It is reporting the numbers and letting the agents read them.
struct CorrelationThirdsTests {
    /// A relationship that ran strong and then stopped. Two thirds agree, so the flag says
    /// consistent — this pins that the flag really does say so, because if it did not, the numbers
    /// alongside it would be solving a problem that does not exist.
    private func fadedPair() -> (x: [Double], y: [Double]) {
        var xs: [Double] = []
        var ys: [Double] = []
        for index in 0..<90 {
            let x = Double((index * 7) % 11) - 5
            xs.append(x)
            // Tracks x closely for the first two thirds, then decouples into its own cycle.
            ys.append(index < 60 ? x + Double(index % 2) * 0.2 : Double((index * 3) % 5) - 2)
        }
        return (xs, ys)
    }

    @Test func `a relationship that ended is reported as consistent by the flag`() {
        let pair = fadedPair()
        let overall = try? #require(CorrelationEngine.pearson(pair.x, pair.y))
        let consistent = CorrelationEngine.signHoldsAcrossThirds(
            pair.x, pair.y, overall: overall ?? 0
        )
        #expect(consistent, "the fixture no longer reproduces the blind spot being closed")
    }

    /// And the numbers show what the flag cannot.
    @Test func `the thirds show the link fading even though the flag says consistent`() throws {
        let pair = fadedPair()
        let thirds = CorrelationEngine.thirdsCorrelations(pair.x, pair.y)
        #expect(thirds.count == 3, "got \(thirds.count) thirds")
        let first = try #require(thirds.first)
        let last = try #require(thirds.last)
        #expect(abs(first) > 0.8, "the fixture's early link is weak (\(first)) — nothing to fade from")
        #expect(abs(last) < abs(first) / 2, "the link did not visibly fade: \(thirds)")
    }

    /// The flag and the numbers are derived from one split, so they cannot describe different
    /// thirds — the drift that would make the basis line contradict itself.
    @Test func `the flag agrees with the numbers stated beside it`() {
        let pair = fadedPair()
        let thirds = CorrelationEngine.thirdsCorrelations(pair.x, pair.y)
        let overall = CorrelationEngine.pearson(pair.x, pair.y) ?? 0
        let agreeing = thirds.count { abs($0) >= 0.1 && ($0 >= 0) == (overall >= 0) }
        #expect(
            CorrelationEngine.signHoldsAcrossThirds(pair.x, pair.y, overall: overall)
                == (agreeing >= 2)
        )
    }

    /// Too short to split yields no thirds at all, rather than three noisy ones that would read as
    /// measurements. A missing measurement must not look like a measured absence.
    @Test func `a record too short to split reports no thirds`() {
        let short = Array(0..<8).map(Double.init)
        #expect(CorrelationEngine.thirdsCorrelations(short, short).isEmpty)
        // And the flag stays permissive there, unchanged by the refactor.
        #expect(CorrelationEngine.signHoldsAcrossThirds(short, short, overall: 1))
    }

    /// The basis line the skeptic and replication panels read must carry the figures, not just the
    /// verdict — the whole point is that the verdict cannot express "it ended".
    @Test func `the basis states the thirds it is judging`() {
        let clause = MetricCorrelation.thirdsClause(consistent: true, thirds: [0.55, 0.51, 0.04])
        #expect(clause.contains("0.55"))
        #expect(clause.contains("0.04"))
    }

    private func correlation(thirds: [Double], partialR: Double) -> MetricCorrelation {
        MetricCorrelation(
            metricA: .stepCount, metricB: .restingHeartRate, lag: 0, r: partialR,
            partialR: partialR, spearman: partialR, n: 90, nEff: 60, pValue: 0.01,
            significant: true, activityControlled: false, consistentAcrossThirds: true,
            thirdsR: thirds
        )
    }

    /// The one number the investigator actually reads. Everything above is invisible to it unless
    /// this row carries the newest third.
    @Test func `the tool row reports the newest third alongside the overall figure`() {
        let row = DiscoveredCorrelation(correlation(thirds: [0.55, 0.51, 0.04], partialR: 0.40))
        #expect(row.coefficient == 0.4)
        #expect(row.recentThirdCoefficient == 0.04, "got \(row.recentThirdCoefficient)")
    }

    /// With no thirds it must read as UNCHANGED, not as a collapse. Defaulting to zero would tell
    /// the agent a short record's link had vanished — inventing the very finding this enables.
    @Test func `an unsplittable record reports the overall figure, not zero`() {
        let row = DiscoveredCorrelation(correlation(thirds: [], partialR: 0.42))
        #expect(row.recentThirdCoefficient == 0.42, "a missing measurement read as a measured absence")
    }

    /// The lens added alongside this evidence invites an agent to write "it ran 0.55 early and 0.04
    /// lately". `NumericFidelity` drops a finding whose prose states figures nothing verified
    /// supports, so if the thirds were not reachable by that check, the lens would be inviting work
    /// that is then thrown away — a silent waste of sessions, which is the cost this app counts.
    ///
    /// They are reachable, but only because the basis line states them: `unsupportedFigures` parses
    /// the basis as well as the explicit `verified` list, and `persistCorrelationProposal` passes
    /// `corr.verifiedBasis`. That is a real dependency between two files, because dropping the thirds
    /// from the basis to save tokens would silently start REJECTING these findings rather than merely
    /// making the basis terser.
    ///
    /// The values are chosen to sit in the gaps between what the other verified figures already
    /// cover. `unitFactors` multiplies every verified value by 1, 1000, 0.001, 100 and 0.01, so with
    /// `n = 90` and `nEff = 60` in the list, candidates land on 0.9, 0.6, 0.09 and 0.06 — and at a 5%
    /// tolerance floored at 1, that covers roughly [0, 0.14], [0.35, 0.45], [0.55, 0.65] and
    /// [0.85, 1]. The first version of this test used 0.55 and 0.04, both inside those bands, so it
    /// passed whether or not the basis stated the thirds at all. Injection caught it; reading it did
    /// not.
    @Test func `a story citing the thirds is not rejected as unsupported`() {
        let corr = correlation(thirds: [0.78, 0.51, 0.22], partialR: 0.40)
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "The link ran about 0.78 early on and only 0.22 lately.",
            basis: corr.verifiedBasis,
            verified: [corr.r, corr.partialR, corr.spearman, Double(corr.n), corr.nEff, corr.pValue]
        )
        #expect(unsupported.isEmpty, "the thirds read as invented figures: \(unsupported)")
    }

    /// The control: a figure that genuinely is invented still gets caught. Without it the test above
    /// would pass equally against a check that accepts everything.
    ///
    /// The first control tried here was 0.87 and it was NOT caught — correctly. `n` is 90, and the
    /// `0.01` unit factor makes 0.9 a candidate, which 0.87 sits inside the 5% tolerance of. That is
    /// the documented leniency ("a figure that happens to be 1000x a real one is possible but rare"),
    /// working as designed, and it makes 0.87 a bad control rather than the check a bad check. 0.73
    /// collides with nothing; 0.32 sits in the same kind of gap and is the control used here.
    @Test func `an invented figure is still caught alongside real thirds`() {
        let corr = correlation(thirds: [0.78, 0.51, 0.22], partialR: 0.40)
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "The link ran about 0.78 early on and 0.32 lately.",
            basis: corr.verifiedBasis,
            verified: [corr.r, corr.partialR, corr.spearman, Double(corr.n), corr.nEff, corr.pValue]
        )
        #expect(unsupported.contains { $0.contains("0.32") }, "caught \(unsupported)")
    }

    /// A day count must not vouch for a correlation.
    ///
    /// `unitFactors` multiplies every scalable value by 1, 1000, 0.001, 100 and 0.01 so a stored
    /// measurement can be restated in another unit (8.4 km for 8,400 m). Applied to `n = 90` that
    /// produced a candidate at 0.9 — so a fabricated "these two move together at 0.9", on a finding
    /// whose real coefficient is 0.40, passed the honesty check unremarked and the skeptic panel was
    /// never told. Counts are dimensionless; they are matched at face value now.
    @Test func `a fabricated near-perfect coefficient is no longer vouched for by the sample size`() {
        let corr = correlation(thirds: [], partialR: 0.40)
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "These two move together at about 0.90.",
            basis: corr.verifiedBasis,
            verified: [corr.r, corr.partialR, corr.spearman, corr.pValue],
            counts: [Double(corr.n), Double(corr.lag), corr.nEff]
        )
        #expect(unsupported.contains { $0.contains("0.90") }, "caught \(unsupported)")
    }

    /// And the count itself is still supported when the prose states it honestly — the check was
    /// tightened, not broken.
    @Test func `prose quoting the real sample size is still supported`() {
        let corr = correlation(thirds: [], partialR: 0.40)
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "Measured over 90 days.",
            basis: corr.verifiedBasis,
            verified: [corr.r, corr.partialR, corr.spearman, corr.pValue],
            counts: [Double(corr.n), Double(corr.lag), corr.nEff]
        )
        #expect(unsupported.isEmpty, "an honest count read as invented: \(unsupported)")
    }

    /// The shape signal reaches the panel that is asked about it.
    ///
    /// `monotoneAgreement` compares the rank correlation with the linear one — low means a curve or
    /// a few extreme days rather than a line — and it already sets 45% of a correlation's quality
    /// through `trustStrength`. It reached no agent. One of the six standing scrutiny lenses asks
    /// "does it rest on a handful of outliers?", so the panel was being asked a question the engine
    /// had already answered and not shown the answer.
    @Test func `the basis states how well the rank and linear correlations agree`() {
        let clean = MetricCorrelation(
            metricA: .stepCount, metricB: .restingHeartRate, lag: 0, r: 0.40, partialR: 0.40,
            spearman: 0.40, n: 90, nEff: 60, pValue: 0.01, significant: true,
            activityControlled: false, consistentAcrossThirds: true, thirdsR: []
        )
        #expect(clean.monotoneAgreement == 1)
        #expect(clean.verifiedBasis.contains("rank-vs-linear agreement 1.00"))

        // A link the ranks disagree with: outlier-driven, and the number now says so.
        let lumpy = MetricCorrelation(
            metricA: .stepCount, metricB: .restingHeartRate, lag: 0, r: 0.60, partialR: 0.60,
            spearman: 0.20, n: 90, nEff: 60, pValue: 0.01, significant: true,
            activityControlled: false, consistentAcrossThirds: true, thirdsR: []
        )
        #expect(lumpy.verifiedBasis.contains("rank-vs-linear agreement 0.60"))
        #expect(lumpy.trustStrength < clean.trustStrength, "the shape did not cost it any trust")
    }

    /// And prose quoting it is not called invented — the figure is in the basis AND passed
    /// explicitly, so the panels can reason with it either way.
    @Test func `prose quoting the shape agreement is supported`() {
        let lumpy = correlation(thirds: [], partialR: 0.60)
        let unsupported = NumericFidelity.unsupportedFigures(
            inProse: "Rank and linear agreement is only 1.00 here.",
            basis: lumpy.verifiedBasis,
            verified: [lumpy.r, lumpy.partialR, lumpy.spearman, lumpy.pValue],
            counts: [Double(lumpy.n), Double(lumpy.lag), lumpy.nEff, lumpy.monotoneAgreement]
        )
        #expect(unsupported.isEmpty, "\(unsupported)")
    }

    /// And degrades cleanly when there are none.
    @Test func `the basis omits thirds it does not have`() {
        let clause = MetricCorrelation.thirdsClause(consistent: false, thirds: [])
        #expect(!clause.contains("thirds:"), "stated an empty list of thirds: \(clause)")
        #expect(clause.contains("did NOT hold"))
    }
}
