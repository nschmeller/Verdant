import Foundation
import Testing
@testable import Verdant

/// A ceiling on any single investigation lens.
///
/// A lens is not part of the prefix `TokenHarnessTests` bounds — each investigator session gets ONE
/// of them, as its focus line — so a long lens costs only its own session. That is why one grew to
/// 509 characters unnoticed, more than twice the next longest and five times the median, while every
/// bounded budget in the app stayed green.
///
/// It still costs. The investigator's window is the tightest in the app: a ~2,048-token prefix of
/// tool schemas and instructions, then the lens, the steering rings, the first pass's readings, and
/// whatever the tools return — inside 4,096. The prompt's own comments call every clause "budget
/// taken from the exploration itself", and the sessions that overflowed on device are recorded here.
///
/// The bound is generous on purpose. Some angles genuinely need explaining — the multi-year one and
/// the sleep-attribution caveat both earn their length — so this is a guard against an essay, not a
/// push toward terseness.
struct LensBudgetTests {
    /// Above the two long-but-justified lenses (~244) with room to spare, and below the 509 that
    /// prompted it.
    static let maxLensCharacters = 400

    /// Prints the roster's shape, for the same reason the prefix budget prints: a bound that only
    /// speaks when it breaks tells nobody how much room is left.
    @Test func `report the lens budget`() {
        let lengths = Instructions.investigationLenses.map(\.count).sorted(by: >)
        let median = lengths[lengths.count / 2]
        print(
            "LENS BUDGET (bound \(Self.maxLensCharacters)) count \(lengths.count)  "
                + "longest \(lengths[0])  median \(median)  spare \(Self.maxLensCharacters - lengths[0])"
        )
    }

    @Test func `no single investigation lens becomes an essay`() {
        for lens in Instructions.investigationLenses where lens.count > Self.maxLensCharacters {
            Issue.record(Comment(rawValue: "a lens is \(lens.count) characters: \(lens.prefix(60))…"))
        }
    }

    /// The focused drill-down's lenses ride the same window, and are built per finding.
    @Test func `no focused lens becomes an essay`() {
        let focus = InvestigationFocus(
            metric: .stepCount, secondaryMetric: .restingHeartRate, title: String(repeating: "x", count: 200)
        )
        for lens in Orchestrator.focusedLenses(focus) where lens.count > Self.maxLensCharacters {
            Issue.record(Comment(rawValue: "a focused lens is \(lens.count) characters"))
        }
    }

    /// Non-vacuity: a roster that had shrunk to nothing would satisfy every bound above.
    @Test func `the roster being measured is the real one`() {
        #expect(Instructions.investigationLenses.count >= 10)
        #expect(Instructions.investigationLenses.allSatisfy { !$0.isEmpty })
    }
}
