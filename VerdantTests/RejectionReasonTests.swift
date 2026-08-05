import Foundation
import Testing
@testable import Verdant

/// A rejection has to say what the panel objected to, because three things read it and none of them
/// can use "the verification panels rejected it".
///
/// That constant was recorded at all six per-kind persist sites, while `PanelOutcome.headline` — the
/// strongest objection the panel actually made — was computed in `survives` and discarded. The app
/// kept that sentence when a finding SURVIVED, in its provenance line, and threw it away when one
/// died: the case that needs explaining, and very nearly all of them.
///
/// The readers: `RunLedger` steers later investigators in the same pass with recent rejections, the
/// journal steers the NEXT run, and the research director's prompt says it learns "what the panels
/// rejected and why". A constant string is not a why, and all three were being fed one.
struct RejectionReasonTests {
    /// The objection goes on a REJECTING verdict, because `PanelOutcome` quotes the side that
    /// decided the outcome — putting it on a holder leaves the headline empty, which is correct
    /// behaviour and caught the first version of this fixture.
    private func outcome(_ why: String, held: Int, of total: Int) -> PanelOutcome {
        PanelOutcome(
            (0..<total).map { index in
                let holds = index < held
                return Verdict(why: holds ? "" : why, couldTest: true, holdsUp: holds)
            }
        )
    }

    @Test func `a rejection quotes the panel and names the tally`() {
        let reason = Orchestrator.rejection(
            by: "skeptics",
            outcome: outcome("The effect is inside the day-to-day noise for this metric.", held: 2, of: 9)
        )
        #expect(reason.contains("2/9"), Comment(rawValue: reason))
        #expect(reason.contains("inside the day-to-day noise"), Comment(rawValue: reason))
        // The objection LEADS: `JournalWriter.record` keeps only the first 90 characters, and that
        // journal is what steers the next run. Bookkeeping first would spend the budget on itself.
        #expect(reason.hasPrefix("“The effect"), Comment(rawValue: reason))
        #expect(
            String(reason.prefix(90)).contains("day-to-day noise"),
            Comment(rawValue: "the objection does not survive the journal's clamp: \(reason.prefix(90))")
        )
    }

    /// A panel that rejected without a usable sentence still reports the tally — silence must not
    /// produce an empty reason, which is the constant string in a different costume.
    @Test func `a silent panel still reports its tally`() {
        let reason = Orchestrator.rejection(by: "replication analysts", outcome: outcome("", held: 1, of: 4))
        #expect(reason.contains("1/4"), Comment(rawValue: reason))
        #expect(!reason.contains("“”"), Comment(rawValue: reason))
    }

    /// It rides into a 4k prompt through two hops, so it arrives already the size it means to be.
    @Test func `a runaway objection is clamped`() {
        let reason = Orchestrator.rejection(
            by: "skeptics",
            outcome: outcome(String(repeating: "long winded objection ", count: 50), held: 0, of: 9)
        )
        #expect(reason.count < 220, Comment(rawValue: "reason ran to \(reason.count) characters"))
    }

    /// The two panels are distinguishable — knowing WHICH gate stopped a finding is most of the
    /// value, and was exactly what the shared constant destroyed.
    @Test func `the two panels are named separately`() {
        let skeptic = Orchestrator.rejection(by: "skeptics", outcome: outcome("a", held: 0, of: 9))
        let replication = Orchestrator.rejection(
            by: "replication analysts", outcome: outcome("a", held: 0, of: 3)
        )
        #expect(skeptic != replication)
        #expect(replication.contains("replication analysts"))
    }
}

/// What the journal keeps, since that is what the NEXT run's research director reads.
///
/// `journalSteering` composes `"text (reason)"` into the director's state, so these two fields are
/// prompt input rather than log lines. A plain `prefix(90)` cut a real rejection mid-phrase and lost
/// the closing quote — `“This is a trivial observation that could be made by anyone looking at their
/// Apple Health ` — which reads as corruption to the thing meant to learn from it.
struct JournalClampTests {
    @Test func `a long reason is cut on a word and marked`() {
        let objection = "“This is a trivial observation that could be made by anyone looking at "
            + "their Apple Health app.” — 2/9 skeptics held it up"
        let clamped = PromptText.clamped(objection, to: 90)
        #expect(clamped.count <= 90, Comment(rawValue: "\(clamped.count) chars: \(clamped)"))
        #expect(clamped.hasSuffix("…"), Comment(rawValue: clamped))
        // Cut on a word: the character before the ellipsis is not a space, and no partial word is
        // left dangling before it.
        #expect(clamped.dropLast().last?.isWhitespace == false, Comment(rawValue: clamped))
        #expect(objection.hasPrefix(String(clamped.dropLast())), "the kept text was altered")
    }

    /// Short text is untouched — a clamp that decorated every line would be worse than the cut.
    @Test func `a short reason passes through unchanged`() {
        let short = "the skeptics rejected it — 0/9 held it up"
        #expect(PromptText.clamped(short, to: 90) == short)
    }

    /// And a single unbroken run still gets cut, to the limit and not one character past it. The
    /// first version of the helper returned `prefix(limit) + "…"` here — off by one, and allowed by
    /// this test until it asserted the real bound rather than the bound plus the ellipsis.
    @Test func `an unbroken run is still bounded`() {
        let clamped = PromptText.clamped(String(repeating: "x", count: 200), to: 90)
        #expect(clamped.count <= 90, Comment(rawValue: "\(clamped.count) chars"))
    }
}
