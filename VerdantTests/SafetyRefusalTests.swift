import Foundation
import Testing
@testable import Verdant

/// The safety panel's refusal has to say WHY, in the reviewer's words.
///
/// It is the gate that rejects most often — 6 of 11 proposals in the last end-to-end run — and it
/// rejects before `survives`, so it was missed when the skeptic and replication panels were taught to
/// carry their objection. For a while every safety rejection read "the safety panel couldn't confirm
/// it", a constant, and it went to three readers that steer the fleet: this run's later investigators
/// (`RunLedger`), the next run's director (the journal), and the research director, which is told in
/// so many words that it learns "what the panels rejected and why".
///
/// Found by printing the assembled prompt after an unrelated change, not by reading the code. A
/// rejection ring full of the same constant looks exactly like a working feature from the source.
struct SafetyRefusalTests {
    private func verdict(_ safe: Bool, _ why: String) -> SafetyVerdict {
        SafetyVerdict(why: why, isSafe: safe)
    }

    @Test func `the refusal quotes the reviewer that flagged, not the panel`() throws {
        let refusal = Orchestrator.refusal(
            rendered: [
                verdict(true, "states a measurement and draws no conclusion"),
                verdict(false, "tells the reader they may have a thyroid condition"),
                verdict(true, "no advice given"),
                verdict(true, "no judgement about the body"),
                verdict(true, "claims association only")
            ],
            total: 5
        )
        let text = try #require(refusal)
        #expect(text.contains("thyroid"), Comment(rawValue: "lost the reviewer's reason: \(text)"))
        // Leading, so the ledger's 95-character clamp cannot cut it away.
        #expect(text.hasPrefix("tells the reader"), Comment(rawValue: text))
        #expect(PromptText.clamped(text, to: 95).contains("thyroid"))
    }

    @Test func `a clear panel refuses nothing`() {
        let all = (0..<5).map { verdict(true, "clear \($0)") }
        #expect(Orchestrator.refusal(rendered: all, total: 5) == nil)
    }

    /// Non-vacuity for the clamp claim above: a reason long enough to be cut must still arrive with
    /// its substance intact, and the panel's own boilerplate is what gets sacrificed.
    @Test func `a long reason survives the ledger clamp with its substance first`() throws {
        let long = String(repeating: "it names a specific medical condition and attributes it. ", count: 4)
        let text = try #require(Orchestrator.refusal(rendered: [verdict(false, long)], total: 1))
        #expect(PromptText.clamped(text, to: 95).contains("medical condition"))
        #expect(!PromptText.clamped(text, to: 95).contains("safety panel"))
    }

    /// Silence is not an opinion. An investigator told the panel disliked its hypothesis steers away
    /// from that ground — exactly wrong when no reviewer rendered a verdict at all.
    @Test func `no quorum is reported as unreachable, not as a judgement`() throws {
        let text = try #require(Orchestrator.refusal(rendered: [verdict(true, "fine")], total: 5))
        #expect(text.contains("could not be reached"), Comment(rawValue: text))
        #expect(text.contains("1/5"), Comment(rawValue: text))
    }

    @Test func `a flag with an empty reason says so rather than trailing an em dash`() throws {
        let text = try #require(Orchestrator.refusal(rendered: [verdict(false, "  \n ")], total: 1))
        #expect(text == "the safety panel refused it without saying why")
    }

    /// The constant this replaced must not come back — in any panel's drop path.
    @Test func `no drop reason is a bare panel name`() throws {
        // CODE lines only. The doc on `safetyRefusal` quotes the old constant deliberately, to record
        // what it replaced and how it was found — a scan that cannot tell history from behaviour
        // would force that history to be deleted to stay green.
        let hits = try SourceScan.swiftSources().filter { file in
            file.text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .contains { $0.contains("couldn't confirm it") }
        }.map(\.path)
        #expect(hits.isEmpty, Comment(rawValue: "constant safety rejection returned: \(hits)"))
    }
}
