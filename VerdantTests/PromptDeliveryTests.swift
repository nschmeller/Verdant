import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Every prompt clamp must be at least as large as the budget of the thing it carries.
///
/// This is a defect CLASS, not one bug. A producer is bounded and tested at one size; a consumer
/// clamps it at a smaller one; nothing compares the two, and the difference is silently deleted
/// evidence. Every `prefix(n)` in `Subagents.swift` was compared against the budget of what it
/// truncates on 2026-08-03. Two were live, two were latent, and the distinction is kept because
/// three of the four numbers below were MEASURED and the fourth was arithmetic that turned out
/// wrong in both directions on the same day:
///
///     consumer                    clamp   what it carries        verdict
///     replicate(claim:)             400   935 realistic          LIVE — 535 lost, most of the basis
///     direct(state:)              1,200   2,590 in a real run    LIVE — both cross-run lines lost
///     curate(roster:)             2,400   1,847 saturated        latent: fits today, unpinned
///     judgeNovelty(candidate:)      380   ~260 typical / 660 max  latent: bites only a long summary
///
/// The two live ones were protecting nothing — the director's session has ~3,649 spare tokens and
/// the replicator was measured rendering 4/4 verdicts on the full claim. They were round numbers
/// written before the budgets they had to fit existed.
///
/// The curator entry is the one worth reading twice, because hand-arithmetic predicted 3,762
/// characters for a saturated 18-row roster and the real figure is 1,847 — an estimate wrong by 2x
/// in the OPPOSITE direction to the three times this repo has recorded estimates coming out low.
/// It was written up as a live defect before being measured, and it is not one. The clamp is raised
/// and pinned anyway, because the roster is bounded by ROW COUNT and nothing bounded its characters.
///
/// These tests pin the RELATIONSHIP, so raising a producer's bound without raising its consumer's
/// clamp fails here rather than quietly redacting the input.
struct PromptDeliveryTests {
    @Test func `the director receives its whole assembled state`() {
        #expect(
            Subagents.maxDirectorState >= DirectorStateSizeTests.maxStateCharacters,
            Comment(rawValue: "director clamp \(Subagents.maxDirectorState) is under the state's own "
                + "budget \(DirectorStateSizeTests.maxStateCharacters) — the last lines are lost, and "
                + "the last lines are the cross-run memory")
        )
    }

    @Test func `the novelty judge receives both summaries in full`() {
        // Each side is "title: summary". The summary alone is bounded at 600.
        #expect(Subagents.maxNoveltySide >= FindingPhrasing.Phrasing.maxSummaryLength + 60)
    }

    /// The curator's roster is bounded by ROW COUNT (18) and not by characters, so its clamp has to
    /// be measured against a saturated roster rather than reasoned about. Built from the real writer
    /// — hand-arithmetic has come out low three separate times in this repo.
    @Test func `the curator reads every row of a saturated roster`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()
        let long = String(repeating: "an overlong model-written finding title that keeps going ", count: 4)
        for (index, metric) in MetricKey.allCases.prefix(18).enumerated() {
            let fact = VerifiedFact(
                metric: metric, comparison: .recentVsBaseline, recent: 12000, baseline: 8000,
                pctChange: 50, z: 6, n: 7, kind: .trend, direction: .up, magnitude: .large,
                salience: 90 - index
            )
            _ = try await writer.appendInsightIfNovel(
                fact: fact, phrasing: .init(summary: long, oneTapTitle: long), jobRunID: UUID()
            )
        }
        let roster = try await writer.curationRoster(now: now).map(\.line).joined(separator: "\n")
        // Non-vacuity: the fixture must actually saturate the row cap, or this measures nothing.
        #expect(roster.components(separatedBy: "\n").count >= 12, "fixture did not fill the roster")
        print("ROSTER: \(roster.count) chars over "
            +
            "\(roster.components(separatedBy: "\n").count) rows; curator clamps to \(Subagents.maxCurationRoster)")
        #expect(
            Subagents.maxCurationRoster >= roster.count,
            Comment(rawValue: "roster is \(roster.count) characters and the curator sees "
                + "\(Subagents.maxCurationRoster) — rows past the cut are retired without being read, "
                + "because the retire loop walks the WHOLE roster")
        )
    }
}

/// Both halves of a finding's display prose are model-written, and both ride into the safety panel
/// as "title\nsummary". The summary was clamped after being measured at 12,318 characters; the title
/// was not, and the doc beside it claimed the summary "was the last unbounded model string reaching
/// a prompt" — an absolute that did not survive reading the line above it.
struct PhrasingClampTests {
    @Test func `an overlong title is clamped on a word boundary`() {
        let runaway = String(repeating: "an unreasonably verbose model-written heading ", count: 30)
        let phrasing = FindingPhrasing.Phrasing(summary: "fine", oneTapTitle: runaway)
        #expect(phrasing.oneTapTitle.count <= FindingPhrasing.Phrasing.maxTitleLength)
        #expect(phrasing.oneTapTitle.hasSuffix("…"))
        #expect(!phrasing.oneTapTitle.contains("  "))
    }

    @Test func `an ordinary title is left exactly as written`() {
        let title = "Resting Heart Rate Settled Lower"
        #expect(
            FindingPhrasing.Phrasing(summary: "fine", oneTapTitle: title).oneTapTitle == title,
            "a title of ordinary length was altered"
        )
    }
}
