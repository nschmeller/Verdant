import Foundation
import FoundationModels
import Testing
@testable import Verdant

/// A prompt names its tools by hand. `Instructions.explorer` says "use eventWindow";
/// `Instructions.answerer` lists all seven of its own; the scout angles name `coverage`. Nothing in
/// the compiler connects those sentences to the array the session is built with, and the two drifted:
/// `Instructions.explorer` is shared by the investigator's explore pass and by Ask's gather pass,
/// which carried different tools, so the Ask pass was instructed to reach for `eventWindow` — which
/// it did not have — in exactly the "when a day looks strange" case the sentence describes. One
/// wasted call out of a permitted four, on the user-facing path, and nothing failed loudly.
///
/// This is the net for that. It is the mechanically checkable slice of prompt/code agreement: not
/// whether the prose is *good*, but whether the capabilities it promises exist.
struct SessionToolsTests {
    private func subagents() throws -> Subagents {
        let container = try TestSupport.inMemoryContainer()
        return Subagents(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings()
        )
    }

    /// One session's expected tool surface, by name.
    private struct Surface {
        let name: String
        let want: [String]
        let tools: [any Tool]
    }

    /// One session's prompt and the tools it actually holds.
    private struct Role {
        let name: String
        let prompt: String
        let tools: [any Tool]
    }

    /// Every role, as what it is told and what it holds. The lens builders are included with the
    /// instructions they are routed to — a lens is prompt text the same as the system instructions,
    /// and `focusedLenses`/`deepLenses` name tools just as freely.
    private func roles(_ s: Subagents) -> [Role] {
        let substrate = AnalysisSubstrate(
            provider: s.provider, series: [], now: Date()
        )
        let focus = InvestigationFocus(metric: .stepCount, secondaryMetric: nil, title: "A finding")
        let investigatorPrompt = ([Instructions.investigator]
            + Instructions.investigationLenses
            + Instructions.deepLenses(pass: 1, metrics: [.stepCount, .bodyMass])
            + Orchestrator.focusedLenses(focus)).joined(separator: "\n")
        let scoutPrompt = ([Instructions.scout]
            + Instructions.scoutAngles
            + Instructions.scoutLenses(pass: 1)).joined(separator: "\n")
        let replicatorPrompt = ([Instructions.replicator, Instructions.retestPlanner]
            + Orchestrator.replicationLenses).joined(separator: "\n")
        return [
            Role(
                name: "investigator",
                prompt: investigatorPrompt,
                tools: s.investigatorTools(substrate)
            ),
            Role(
                name: "explorer",
                prompt: Instructions.explorer,
                tools: s.explorerTools(substrate)
            ),
            Role(
                name: "ask gather",
                prompt: Instructions.explorer,
                tools: s.askGatherTools(substrate)
            ),
            Role(name: "scout", prompt: scoutPrompt, tools: s.scoutTools(substrate)),
            Role(
                name: "replicator",
                prompt: replicatorPrompt,
                tools: s.replicatorTools(substrate)
            ),
            Role(
                name: "director",
                prompt: Instructions.director,
                tools: s.directorTools(now: Date())
            ),
            Role(
                name: "answerer",
                prompt: Instructions.answerer,
                tools: s.answererTools(substrate, now: Date())
            )
        ]
    }

    /// Every tool name in the app, so a prompt can be scanned for mentions of tools it lacks as well
    /// as ones it has.
    private func everyToolName(_ s: Subagents) -> Set<String> {
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let all = s.askGatherTools(substrate)
            + s.answererTools(substrate, now: Date())
            + s.scoutTools(substrate)
            + s.directorTools(now: Date())
        return Set(all.map(\.name))
    }

    /// The other direction, which nothing checked: a tool a session HOLDS but its prompt never
    /// names. The session pays that tool's schema in its prefix every call and the agent has no
    /// reason to reach for it — the cost with none of the benefit, and silent.
    ///
    /// What it does NOT cover, stated because the near-miss that prompted it sits just outside:
    /// `provenance` was added to the replication analyst's tool set while `Instructions.retestPlanner`
    /// still told the planner its analysts could compute "with analyze or unusualDays", so the one
    /// agent whose job is choosing what to re-test believed the tool did not exist. This test would
    /// have passed throughout — a role's prompt is the CONCATENATION of the instructions its sessions
    /// read, and `Instructions.replicator` did mention the tool.
    ///
    /// It cannot be tightened to catch that, either: the planner is a session with NO tools of its
    /// own, so there is no held-tool set to compare its prompt against. Its knowledge of what the
    /// analysts can compute is prose describing another session, which nothing mechanical can pin.
    /// Worth knowing when adding a tool: the planner must be told by hand.
    @Test func `every tool a session holds is named in its prompt`() throws {
        let s = try subagents()
        var problems: [String] = []
        for role in roles(s) {
            for tool in role.tools where !role.prompt.contains(tool.name) {
                problems.append("\(role.name) carries \(tool.name) but never mentions it")
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func `no prompt tells an agent to use a tool its session does not have`() throws {
        let s = try subagents()
        let allNames = everyToolName(s)
        // Sanity: the vocabulary being scanned for is the real one, not an empty set.
        #expect(allNames.count >= 9, "only found \(allNames.count) tool names")

        var problems: [String] = []
        for role in roles(s) {
            let held = Set(role.tools.map(\.name))
            for name in allNames where !held.contains(name) {
                // Word-boundary-ish: the names are camelCase and distinctive, but `coverage` is also
                // an ordinary English word, so require it to read as a tool reference.
                guard role.prompt.contains(name) else { continue }
                problems.append("\(role.name) is told to use \(name) but does not have it")
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
    }

    /// The check above is only meaningful if the prompts really do name tools — if the scan found
    /// none, it would pass no matter what the sessions carried.
    @Test func `the prompts really do name their tools`() throws {
        let s = try subagents()
        for role in roles(s) {
            let held = Set(role.tools.map(\.name))
            let mentioned = held.filter { role.prompt.contains($0) }
            #expect(!mentioned.isEmpty, "\(role.name)'s prompt names none of its \(held.count) tools")
        }
    }

    /// Each role's surface, pinned by name. These are deliberate, documented design decisions —
    /// the scout carries neither `analyze` nor `metricStats` because a surveyor reads the map rather
    /// than computing views; the replicator carries two tools so re-tests get headroom; the commit
    /// pass omits `eventWindow` because its prefix already sits near the bound. A snapshot is the
    /// right shape for a decision like that: silent drift is exactly what must not happen, and the
    /// token harness alone would only notice a change big enough to blow a budget.
    @Test func `every session carries exactly the tools its role calls for`() throws {
        let s = try subagents()
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let investigator = [
            "analyze",
            "correlationScan",
            "metricStats",
            "metricsOverview",
            "patternScan",
            "unusualDays"
        ]
        let expected: [Surface] = [
            Surface(name: "investigator", want: investigator, tools: s.investigatorTools(substrate)),
            Surface(
                name: "explorer",
                want: investigator + ["eventWindow"],
                tools: s.explorerTools(substrate)
            ),
            Surface(
                name: "ask gather",
                want: investigator + ["eventWindow"],
                tools: s.askGatherTools(substrate)
            ),
            Surface(
                name: "scout",
                want: [
                    "correlationScan",
                    "coverage",
                    "metricsOverview",
                    "patternScan",
                    "unusualDays"
                ],
                tools: s.scoutTools(substrate)
            ),
            Surface(
                name: "replicator",
                // metricStats is here for its .anyOf metric vocabulary as much as its numbers — see
                // MetricVocabularyTests, and the five runs of "could not run this check" behind it.
                want: ["analyze", "unusualDays", "provenance", "metricStats"],
                tools: s.replicatorTools(substrate)
            ),
            Surface(
                name: "director",
                want: ["researchJournal"],
                tools: s.directorTools(now: Date())
            ),
            Surface(
                name: "answerer",
                want: investigator + ["insightSearch"],
                tools: s.answererTools(substrate, now: Date())
            )
        ]
        for (name, want, tools) in expected.map({ ($0.name, $0.want, $0.tools) }) {
            #expect(Set(tools.map(\.name)) == Set(want), "\(name)'s tool surface changed")
            #expect(tools.count == want.count, "\(name) carries a duplicate tool")
        }
    }

    /// The investigator's explore pass and Ask's gather pass are documented as the SAME pass — same
    /// instructions, same tools (`askGatherTools`). Their two-pass scaffolding was written out twice
    /// and had already drifted: one formatted the carried-over readings with a single leading
    /// newline, the other with two, and both clamps (5 readings, 160 characters each) were typed
    /// separately. Tuning either on one path would have left the other on the old budget, silently,
    /// on the window this app overflows soonest.
    @Test func `the two-pass scaffolding is written once`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Subagents.swift" }
        )
        let code = SourceScan.code(source.text)
        // The clamps may appear only inside the shared helper.
        #expect(
            code.components(separatedBy: "prefix(maxReadings)").count == 2,
            "the readings clamp is applied in more than one place"
        )
        #expect(!code.contains("prefix(5).map"), "a hand-written readings clamp came back")
        // And the budget sentence exists once, as a constant.
        #expect(
            code.components(separatedBy: "Use at most FOUR tool calls, then report").count == 2,
            "the gather budget sentence is written more than once"
        )
    }

    /// `Instructions.explorer` is the one prompt used by two sessions. Whatever it names must be
    /// held by BOTH, which is the specific invariant the bug broke.
    @Test func `the shared explorer prompt is true for both sessions that use it`() throws {
        let s = try subagents()
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let discovery = Set(s.explorerTools(substrate).map(\.name))
        let ask = Set(s.askGatherTools(substrate).map(\.name))
        for name in everyToolName(s) where Instructions.explorer.contains(name) {
            #expect(discovery.contains(name), "explore pass is told to use \(name)")
            #expect(ask.contains(name), "Ask's gather pass is told to use \(name)")
        }
        // The two are in fact the SAME set, which is what makes a shared prompt safe rather than
        // merely currently-true — and the tool at the heart of the bug is in both.
        #expect(discovery == ask)
        #expect(ask.contains("eventWindow"))
        // `insightSearch` belongs to the ANSWERING pass: these instructions say "MEASURE, not
        // conclude", and searching past findings is neither a measurement nor affordable here.
        #expect(!ask.contains("insightSearch"))
        #expect(Set(s.answererTools(substrate, now: Date()).map(\.name)).contains("insightSearch"))
    }
}
