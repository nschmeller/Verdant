import Foundation
import Testing
@testable import Verdant

/// Two prompts describe a DIFFERENT session's work, by count and by list.
///
/// `Instructions.challenger` sets the agenda for the skeptic panel and opens by telling the agent how
/// many reviewers will already ask the generic questions, then enumerating them. `retestPlanner` does
/// the same for the replication analysts. Both exist to answer one question — what would the generic
/// set MISS? — so both are only as good as their picture of that set.
///
/// Nothing connected either to the arrays they describe, and `challenger` had drifted: numeric
/// honesty was added to `scrutinyLenses` as a seventh lens and the prompt still said six, still
/// listing the original six. The agent whose job is finding the gap believed nobody was checking the
/// figures, making "has anyone verified the numbers?" its most natural proposal — a whole extra
/// session spent restating a lens that already existed, which is exactly what the prompt's closing
/// line tells it not to do. No crash, no wrong number, just a slower panel arriving at the same place.
///
/// A drifted count is also worse than a missing one: it reads as deliberate.
struct PanelAgendaTests {
    /// Spelled numbers, because that is how a prompt says it.
    private static let words = [
        1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight",
        9: "Nine", 10: "Ten"
    ]

    private func number(_ count: Int) throws -> String {
        try #require(Self.words[count], "no spelling for \(count) — extend the table")
    }

    @Test func `the challenger knows how many skeptics precede it`() throws {
        let actual = Orchestrator.scrutinyLenses.count
        let stated = try number(actual)
        #expect(
            Instructions.challenger.contains("\(stated) reviewers"),
            Comment(
                rawValue: "scrutinyLenses has \(actual) entries; challenger does not say “\(stated) reviewers”"
            )
        )
        // And no OTHER count is stated, or a stale sentence could sit beside a corrected one.
        for (value, word) in Self.words where value != actual {
            #expect(
                !Instructions.challenger.contains("\(word) reviewers"),
                Comment(rawValue: "challenger also claims “\(word) reviewers”")
            )
        }
    }

    @Test func `the retest planner knows how many analysts precede it`() throws {
        let actual = Orchestrator.replicationLenses.count
        let stated = try number(actual)
        #expect(
            Instructions.retestPlanner.contains("\(stated) analysts"),
            Comment(rawValue: "replicationLenses has \(actual); planner does not say “\(stated) analysts”")
        )
        for (value, word) in Self.words where value != actual {
            #expect(
                !Instructions.retestPlanner.contains("\(word) analysts"),
                Comment(rawValue: "retestPlanner also claims “\(word) analysts”")
            )
        }
    }

    /// The count alone would pass while the enumeration went stale, which is half the drift: the
    /// seventh lens is numeric honesty, and an agenda-setter that never hears the words cannot know
    /// the figures are already being checked.
    @Test func `the challenger's list reaches the newest lens`() {
        #expect(
            Instructions.challenger.lowercased().contains("figure"),
            "the challenger never mentions the numeric-honesty lens it is told precedes it"
        )
    }

    /// The planner also enumerates the analyst's TOOLS, and that list went stale the moment the
    /// replicator's tool set changed.
    ///
    /// `metricStats` was added to `replicatorTools` to fix a panel that completed zero re-tests in
    /// five runs — and `retestPlanner` still told the planner a check must be "something an analyst
    /// can actually compute with analyze, unusualDays or provenance". So the agent SIZING the panel
    /// was composing re-tests against three tools while the analysts held four, and the one it did
    /// not know about was the one added to make the panel work at all.
    ///
    /// `SessionToolsTests` cannot catch this: it checks a session's prompt against the tools that
    /// session holds. This prompt describes a DIFFERENT session's tools, which is the same class of
    /// bug and had no net at all.
    @Test func `the retest planner knows which tools the analysts hold`() throws {
        let s = try Subagents(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            writer: StoreWriter(modelContainer: TestSupport.inMemoryContainer()),
            embeddings: Embeddings()
        )
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let held = s.replicatorTools(substrate).map(\.name)
        #expect(held.count >= 3, "the replicator surface shrank; this test is measuring little")
        for tool in held {
            #expect(
                Instructions.retestPlanner.contains(tool),
                Comment(rawValue: "analysts hold \(tool) and the planner is never told")
            )
        }
        // And the reverse: a tool the planner names that the analysts do NOT hold sends it composing
        // re-tests nobody can run — the exact failure `SessionToolsTests` guards for a session's own
        // prompt.
        let everyToolName = Set(
            s.explorerTools(substrate).map(\.name)
                + s.scoutTools(substrate).map(\.name)
                + s.answererTools(substrate, now: Date()).map(\.name)
                + s.directorTools(now: Date()).map(\.name)
                + held
        )
        for name in everyToolName.subtracting(held)
            where Instructions.retestPlanner.contains(name)
        {
            Issue.record("the planner names \(name), which no replication analyst holds")
        }
    }

    /// Non-vacuity: these assertions are worthless if the arrays are empty or the prompts blank.
    @Test func `the panels being described are real`() {
        #expect(Orchestrator.scrutinyLenses.count >= 5)
        #expect(Orchestrator.replicationLenses.count >= 2)
        #expect(Instructions.challenger.count > 200)
        #expect(Instructions.retestPlanner.count > 200)
    }
}
