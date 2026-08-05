import Foundation
import Testing
@testable import Verdant

/// The investigator's avoid-list: one block, at the end, with its categories intact.
///
/// It used to be two lists assembled in two files and joined at two points in the prompt, which
/// produced `…(could not be replicated).. Explore with at most FOUR tool calls` — the sentence
/// telling the investigator what to DO arriving as a continuation of a list of things not to do.
/// That was invisible in both files and obvious the moment the assembled prompt was printed.
struct AvoidListTests {
    @Test func `nothing to avoid renders nothing at all`() {
        // Not an empty heading: a "Ground already covered:" with no entries invites the model to
        // supply what it thinks belongs there.
        #expect(AvoidList().rendered().isEmpty)
    }

    @Test func `each category is labelled, and empty ones are left out`() {
        let list = AvoidList(
            onFeed: ["Resting Heart Rate Settling"],
            rejectedThisRun: ["Step Count Coherence (the skeptics rejected it)"],
            priorRunDeadEnds: ["Weekend Sleep Debt"]
        )
        let text = list.rendered()
        #expect(text.contains("· already on the feed: Resting Heart Rate Settling"))
        #expect(text.contains("· rejected this run: Step Count Coherence (the skeptics rejected it)"))
        #expect(text.contains("· dead ends from earlier runs: Weekend Sleep Debt"))
        #expect(!text.contains("retired"), Comment(rawValue: "an empty category was rendered: \(text)"))
    }

    @Test func `the block leads with a blank line so it cannot run into the task statement`() {
        let text = AvoidList(rejectedThisRun: ["A"]).rendered()
        #expect(text.hasPrefix("\n\n"), Comment(rawValue: "would abut the preceding sentence: \(text)"))
        #expect(!text.contains(".."), Comment(rawValue: text))
    }

    @Test func `entries within a category are separated, not concatenated`() {
        let text = AvoidList(rejectedThisRun: ["First Claim", "Second Claim"]).rendered()
        #expect(text.contains("First Claim; Second Claim"))
    }

    /// The EXPLORE pass measures and proposes nothing, so a list of things not to propose is budget
    /// taken from the exploration itself — it was 230 of that prompt's 480 characters, out of a
    /// 4,096-token window. Pinned by scanning the source, because the split is the whole point of
    /// `investigate` taking `lens` and `avoid` separately and would be silently undone by
    /// interpolating the wrong one.
    ///
    /// The end marker is CODE (`func commitSession()`), not the "PASS 2" comment that reads more
    /// naturally: `SourceScan.code` strips comments, so a comment marker makes the range empty and
    /// the assertion vacuously true. It failed that way on first run.
    @Test func `the explore pass is not handed the avoid-list`() throws {
        let file = try #require(
            try SourceScan.swiftSources().first { $0.path == "Subagents.swift" }
        )
        let code = SourceScan.code(file.text)
        let start = try #require(code.range(of: "Measure what matters for this angle"))
        let end = try #require(code.range(of: "func commitSession()"))
        let explore = String(code[start.lowerBound..<end.lowerBound])
        #expect(
            !explore.contains("avoid") && !explore.contains("covered"),
            Comment(rawValue: "the explore prompt regained the avoid-list: \(explore)")
        )
    }
}
