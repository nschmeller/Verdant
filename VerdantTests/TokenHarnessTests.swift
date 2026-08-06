import Foundation
import FoundationModels
import SwiftData
import Testing
@testable import Verdant

/// Validates the context-protection scheme. The structural caps are always asserted; real token
/// measurement runs only when `tokenCount` is available (iOS 26.4+ with the model present), where
/// it confirms a subagent's prefix fits comfortably under the window.
struct TokenHarnessTests {
    /// The real `Subagents`, so every prefix below measures the tool set the app SHIPS. These tests
    /// used to build their own copy of each session's tool array — a third hand-maintained replica of
    /// something already written twice — which meant the harness could pass while the app carried a
    /// different surface entirely. Measuring the actual factories is the whole point of the exercise.
    private func subagents() throws -> Subagents {
        let container = try AppContainer.makeContainer(inMemory: true)
        return Subagents(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings()
        )
    }

    private func emptySubstrate(_ s: Subagents) -> AnalysisSubstrate {
        AnalysisSubstrate(provider: s.provider, series: [], now: Date())
    }

    @Test func `structural caps hold`() {
        // Per-session caps that protect the context window stay tight regardless of how many
        // sessions we run concurrently.
        #expect(TokenBudget.maxRetrievedMemories <= 3)
        // Pinned to the shipped value (120), not a slack ceiling — this cap exists to protect the
        // context window, so an upward drift is exactly the regression to catch.
        #expect(TokenBudget.maxMemoryCharacters <= 120)
        // Throughput knobs live in EnhancementPolicy (issue depth, not token quotas).
        //
        // Pinned to EXACTLY 1, not `>= 1`. This is the single knob every fan-out in the app reads —
        // discovery, the safety, skeptic and replication panels, the deep run's fleet — and the
        // whole Neural-Engine argument rests on its value: on-device inference serialises anyway, so
        // issuing several sessions at once makes the OS split each one's resources and burns the
        // generation rate limit in bursts, producing MORE errors and LESS completed reasoning. Set
        // it to 4 and nothing fails; the app just quietly runs four throttled agents where it
        // promised one at full power, which is the opposite of the design. `>= 1` accepted that.
        #expect(EnhancementPolicy.maxConcurrentSubagents == 1)
        #expect(EnhancementPolicy.maxCandidates >= 1)
    }

    /// Prints every role's prefix against the bound, on every run.
    ///
    /// The per-role assertions below already enforce these limits and have for weeks — and printed
    /// nothing while passing, so no number existed that a person could plan against. "The prefix sits
    /// near its bound" circulated as folklore and was acted on all day before anyone measured it; the
    /// true margin on two roles is a dozen tokens.
    ///
    /// A report rather than a tighter assertion, deliberately: a twelve-token margin is a fact to see
    /// before adding a field, not a build to break. Failing at some invented comfort threshold would
    /// block work that is currently fine and teach the next person to raise the threshold.
    @Test func `report every role's prefix budget`() async throws {
        let s = try subagents()
        let sub = emptySubstrate(s)
        struct Role {
            let name: String
            let instructions: String
            let tools: [any Tool]
        }
        let roles = [
            Role(
                name: "investigator",
                instructions: Instructions.investigator,
                tools: s.investigatorTools(sub)
            ),
            Role(name: "explorer", instructions: Instructions.explorer, tools: s.explorerTools(sub)),
            Role(
                name: "answerer",
                instructions: Instructions.answerer,
                tools: s.answererTools(sub, now: Date())
            ),
            Role(name: "replicator", instructions: Instructions.replicator, tools: s.replicatorTools(sub)),
            Role(name: "scout", instructions: Instructions.scout, tools: s.scoutTools(sub)),
            Role(name: "director", instructions: Instructions.director, tools: s.directorTools(now: Date()))
        ]
        let bound = TokenBudget.modelContextSize / 2
        var lines = ["PREFIX BUDGET (bound \(bound))"]
        var measured = 0
        for role in roles {
            guard let instructions = await TokenBudget.tokenCount(forText: role.instructions),
                  let schemas = await TokenBudget.tokenCount(forTools: role.tools)
            else { continue }
            measured += 1
            let total = instructions + schemas
            lines.append(
                "  \(role.name.padding(toLength: 13, withPad: " ", startingAt: 0))"
                    + "instr \(instructions)  tools \(schemas)  total \(total)  spare \(bound - total)"
            )
        }
        print(lines.joined(separator: "\n"))
        // Without the tokenizer (a bare CI runner) there is nothing to report and nothing to check —
        // the per-role tests fall back to their character proxies. Say which happened rather than
        // reporting an empty table as a clean bill.
        if measured == 0 { print("  (tokenizer unavailable — per-role character proxies applied)") }
    }

    @Test func `investigator prefix fits context window`() async throws {
        // The full tool surface the agentic investigator drives — the real ceiling on "more metrics",
        // since every .anyOf(MetricKey.allRawValues) in a tool schema grows with the registry.
        let s = try subagents()
        let tools = s.investigatorTools(emptySubstrate(s))

        let instructionTokens = await TokenBudget.tokenCount(forText: Instructions.investigator)
        let toolTokens = await TokenBudget.tokenCount(forTools: tools)

        guard let instructionTokens, let toolTokens else {
            // Fall back to a character-budget proxy when the real tokenizer is unavailable, so a
            // blow-up is still caught: the frozen investigator instruction must stay terse.
            //
            // This used to say "on the simulator (no Apple Intelligence) token measurement returns
            // nil". Not universally true, and worth correcting because it invites the reader to
            // assume the real measurement never runs: on a simulator with the model present it
            // returns real counts, and the numbers below are measured, not proxied. The fallback is
            // for a machine WITHOUT it — a bare CI runner — not for simulators as a class.
            //
            // MEASURED 2026-08-02, since a bound nobody has seen a number for is a bound nobody can
            // budget against: instructions 398 tokens + tools 1,638 = **2,036 against 2,048**. Twelve
            // tokens of margin. Anything added to `Instructions.investigator` or to the investigator's
            // tool schemas trips this, which is why the day's new angle went in as a LENS (runtime,
            // one session) rather than a line in the prefix.
            //
            // Where the 1,638 goes, measured the same day — the numbers to budget against before
            // adding a tool or a field:
            //
            //     metricStats 576 · analyze 524 · eventWindow 235 · unusualDays 198
            //     correlationScan 146 · patternScan 143 · metricsOverview 141
            //
            // Two tools are 67% of it, and both for the same reason: `metricStats` spends nearly all
            // of its 576 on `.anyOf(MetricKey.allRawValues)`, thirty-eight metric keys enumerated into
            // the schema. `AnalyzeTool` already dropped `.anyOf` from its metric argument for exactly
            // this ("with the full registry the vocabulary is heavy"), leaning on the registry resolve
            // to reject an unknown key.
            //
            // The same trade is available here and is deliberately NOT taken. `.anyOf` is what makes
            // the metric unforgeable through constrained decoding — `MetricStatsTool.call` logs a
            // missing stat as an INVARIANT VIOLATION on the strength of it — and buying ~300 tokens of
            // headroom nothing currently needs by weakening that is a product call, not a cleanup.
            // Recorded here so whoever needs the headroom knows exactly where it is.
            //
            // EVERY role, measured the same day, because a single role's margin understates the
            // constraint:
            //
            //     investigator 398 + 1,639 = 2,037   (11 spare)
            //     explorer     180 + 1,856 = 2,036   (12 spare)
            //     answerer     245 + 1,724 = 1,969   (79 spare)
            //     replicator   411 + 1,437 = 1,848  (200 spare)
            //     scout        230 +   712 =   942
            //     director     240 +   207 =   447
            //
            // A snapshot, and it goes stale — which is why the table is PRINTED every run and this
            // copy is only for reading alongside the argument. Naming the figures in
            // `metricsOverview`'s description first pushed the investigator to 2,050 and broke the
            // build, which is the twelve-token margin working exactly as this comment says it must.
            //
            // Three of the six sit within eighty tokens of the bound, and they are the three built on
            // `investigatorTools`. So the surface is SHARED: a field added to `metricStats`,
            // `analyze`, `correlationScan`, `patternScan`, `unusualDays` or `metricsOverview` is paid
            // three times and trips three roles at once. The effective budget for new evidence in a
            // shared tool schema is about twelve tokens.
            //
            // The replicator was 227 + 879 = 1,106 until `metricStats` was added to it, which is the
            // one line here that is a RESULT rather than a constraint. That role had the roomiest
            // session in the app and completed zero re-tests across five runs against the real model,
            // because every tool it held made it spell the metric key from memory and it kept getting
            // the spelling wrong. Spending 659 of its spare tokens on an anchored vocabulary is the
            // best trade in this table: unspent headroom bought nothing at all.
            //
            // Which sharpens the `metricStats` `.anyOf` trade above rather than settling it. Dropping
            // that list would free ~300 tokens across all three near-bound roles — real relief — but
            // it is now measured, not theorised, that the list is what makes a role able to name a
            // metric. Take the tokens from somewhere else first.
            #expect(Instructions.investigator.count < 2200)
            return
        }

        let prefix = instructionTokens + toolTokens
        // Generous headroom for prompt, several tool round-trips, and generated output.
        #expect(prefix < TokenBudget.modelContextSize / 2)
    }

    /// The investigator's FIRST session carries the full tool surface PLUS `eventWindow`, so it is
    /// the widest schema in the discovery path — splitting exploration from commitment only buys
    /// depth if each half still fits comfortably.
    ///
    /// Ask's gather pass runs on this exact prefix (`SessionToolsTests` pins that the two sets are
    /// identical), so this covers both. It did not always: the gather pass carried `insightSearch`
    /// instead of `eventWindow` while running these instructions, which name `eventWindow`. Carrying
    /// both is not an option — measured at 2,118 tokens against the 2,048 allowed here.
    @Test func `explorer prefix fits context window`() async throws {
        let s = try subagents()
        let tools = s.explorerTools(emptySubstrate(s))

        let instructionTokens = await TokenBudget.tokenCount(forText: Instructions.explorer)
        let toolTokens = await TokenBudget.tokenCount(forTools: tools)

        guard let instructionTokens, let toolTokens else {
            #expect(Instructions.explorer.count < 1200)
            return
        }

        let prefix = instructionTokens + toolTokens
        #expect(prefix < TokenBudget.modelContextSize / 2)
    }

    /// The Q&A session carries the WIDEST tool surface in the app — the investigator's six plus
    /// `insightSearch` — and was the only role with no budget test at all, which made it the one
    /// most likely to blow the window unnoticed.
    @Test func `answerer prefix fits context window`() async throws {
        let s = try subagents()
        let tools = s.answererTools(emptySubstrate(s), now: Date())

        let instructionTokens = await TokenBudget.tokenCount(forText: Instructions.answerer)
        let toolTokens = await TokenBudget.tokenCount(forTools: tools)

        guard let instructionTokens, let toolTokens else {
            #expect(Instructions.answerer.count < 1300)
            return
        }

        let prefix = instructionTokens + toolTokens
        #expect(prefix < TokenBudget.modelContextSize / 2)
    }

    @Test func `scout prefix fits context window`() async throws {
        // The scout's 5-tool surface: deliberately lighter than the investigator's — it drops the
        // only .anyOf(MetricKey.allRawValues) schema (metricStats) and analyze's 7 arguments, and
        // gains the small coverage tool.
        let s = try subagents()
        let tools = s.scoutTools(emptySubstrate(s))

        let instructionTokens = await TokenBudget.tokenCount(forText: Instructions.scout)
        let toolTokens = await TokenBudget.tokenCount(forTools: tools)

        guard let instructionTokens, let toolTokens else {
            // Simulator fallback: the frozen scout instruction must stay terse.
            #expect(Instructions.scout.count < 1400)
            return
        }

        let prefix = instructionTokens + toolTokens
        #expect(prefix < TokenBudget.modelContextSize / 2)
    }

    /// The director is prose-only apart from its one journal tool, so it should be the roomiest
    /// session in the app — locked under a THIRD of the window so that staying true is the
    /// regression to catch if the role ever grows a real tool surface.
    @Test func `director prefix fits context window`() async throws {
        let tools = try subagents().directorTools(now: Date())

        let instructionTokens = await TokenBudget.tokenCount(forText: Instructions.director)
        let toolTokens = await TokenBudget.tokenCount(forTools: tools)

        guard let instructionTokens, let toolTokens else {
            #expect(Instructions.director.count < 1200)
            return
        }

        let prefix = instructionTokens + toolTokens
        #expect(prefix < TokenBudget.modelContextSize / 3)
    }

    @Test func `replicator prefix fits context window`() async throws {
        // This was locked under a THIRD of the window, on the theory that a re-test's scarce resource
        // was headroom for tool round-trips. Five runs against the real model completed zero
        // re-tests, all of them failing to spell the metric key rather than running out of room, so
        // `metricStats` and its anchored vocabulary were added: 1,106 -> 1,765 measured, which the
        // old pin would have refused. The bound is now half the window, the same as every other role.
        //
        // Keeping the third would have been the tidier number and the wrong one. It is worth being
        // exact about what it was protecting: not a measurement, a guess about what the panel needed.
        let s = try subagents()
        let tools = s.replicatorTools(emptySubstrate(s))

        let instructionTokens = await TokenBudget.tokenCount(forText: Instructions.replicator)
        let toolTokens = await TokenBudget.tokenCount(forTools: tools)

        guard let instructionTokens, let toolTokens else {
            // 1000 was stale and had never once been evaluated: this branch only runs where the model
            // cannot tokenise — below iOS 26.4, or on a simulator with no model provisioned — which
            // is never a dev machine, so the bound went unchecked while the instructions grew to
            // 1,982 characters. It is a crude proxy for "the prompt has not run away" when no real
            // count is available; 2,400 leaves room to edit without silently licensing a rewrite.
            #expect(Instructions.replicator.count < 2400)
            return
        }

        let prefix = instructionTokens + toolTokens
        #expect(prefix < TokenBudget.modelContextSize / 2, "replicator prefix is \(prefix)")
    }

    @Test func `a context failure wrapped in a tool-call error still triggers the overflow retry`(
    ) throws {
        let container = try AppContainer.makeContainer(inMemory: true)
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = AnalysisSubstrate(provider: provider, series: [], now: Date())
        let tool = UnusualDaysTool(substrate: substrate)
        let decoding = LanguageModelSession.GenerationError.decodingFailure(
            .init(debugDescription: "truncated guided generation")
        )
        struct Plain: Error {}
        // Bare generation failures were always retried; the regression this pins is the WRAPPED
        // form — constrained decoding of a tool's arguments arrives as ToolCallError and used to
        // skip the whole pass instead of retrying on a fresh session.
        #expect(Subagents.isContextFailure(decoding))
        #expect(Subagents.isContextFailure(
            LanguageModelSession.ToolCallError(tool: tool, underlyingError: decoding)
        ))
        #expect(!Subagents.isContextFailure(Plain()))
        #expect(!Subagents.isContextFailure(
            LanguageModelSession.ToolCallError(tool: tool, underlyingError: Plain())
        ))
    }
}
