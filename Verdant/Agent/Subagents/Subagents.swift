import Foundation
import FoundationModels

/// The model-facing operations the Orchestrator depends on. Abstracting them behind a protocol lets
/// tests inject a deterministic fake and exercise the full loop (verify → safety → persist) without
/// the on-device model.
protocol SubagentRunning: Sendable {
    func investigate(
        lens: String, avoid: AvoidList, substrate: AnalysisSubstrate, now: Date
    ) async throws -> [ProposedFinding]
    /// Warm the shared on-device model before the first real call (idle-gap reduction).
    nonisolated func prewarm()
    func scrutinize(finding: String, lens: String) async throws -> Verdict
    /// Write challenges specific to ONE finding, added to the skeptic panel's fixed lenses.
    func composeChallenges(finding: String) async throws -> ChallengeSet
    /// Write re-tests specific to ONE claim, added to the armed replication panel's fixed lenses.
    func composeRetests(claim: String, available: String?) async throws -> RetestPlan
    func reviewSafety(text: String, lens: String) async throws -> SafetyVerdict
    /// Survey the data and hand back testable leads (the discovery loop's agent).
    func scout(
        lens: String, avoid: AvoidList, substrate: AnalysisSubstrate, now: Date
    ) async throws -> [ProposedLead]
    /// Re-TEST a claim against the data with analysis tools (the verification loop's armed agent).
    func replicate(claim: String, lens: String, substrate: AnalysisSubstrate) async throws -> Verdict
    /// Plan the next deep-run pass from the run's state (the research director).
    func direct(state: String, now: Date) async throws -> PassPlan
    /// Decide which active findings keep their feed slots (the curator).
    func curate(roster: String, budget: Int) async throws -> CurationDecision
    /// Judge whether a candidate meaningfully updates the standing finding it collides with.
    func judgeNovelty(candidate: String, prior: String) async throws -> NoveltyVerdict
    /// Rewrite a finding the safety panel refused, given the reviewer's own objection.
    func rephrase(title: String, summary: String, objection: String) async throws -> Rephrasing
    func answer(
        question: String, history: [ConversationTurn], substrate: AnalysisSubstrate, now: Date
    ) async throws -> Answer
}

/// The ephemeral leaf subagents. Each call constructs a fresh `LanguageModelSession` used for one
/// focused job and discarded — separate sessions are independent contexts, so no long-lived
/// transcript ever accumulates. The `@Generable` structs are the only handoffs.
nonisolated struct Subagents: SubagentRunning {
    let provider: MetricStatsProvider
    let writer: StoreWriter
    let embeddings: Embeddings

    /// The default guardrails refuse health prompts as "sensitive content", which would disable the
    /// whole LLM layer on-device. `permissiveContentTransformations` is Apple's relaxed mode for
    /// transforming the user's *own* content — exactly our case. Output is still judged by the agent
    /// safety panel (`reviewSafety`), so this loosens the model's guardrail, not our safety.
    static let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    // MARK: Discovery loop

    /// The inverted discovery path: ONE agentic session drives the logical tools itself — it reads the
    /// overview, follows leads through correlationScan / patternScan / metricStats, and proposes the
    /// findings it judges worth telling. The tools are the closed, recomputable boundary (the model can
    /// only name metrics the registry resolves and only sees numbers a tool computed), so agency here
    /// costs nothing in verifiability. Ephemeral and single-use, like every other leaf session.
    func investigate(
        lens: String,
        avoid: AvoidList,
        substrate: AnalysisSubstrate,
        now: Date = .now
    ) async throws -> [ProposedFinding] {
        let tools = investigatorTools(substrate)
        // PASS 1 — EXPLORE. Its own session, so its tool round-trips are charged to its own window.
        // A failure here is not fatal: the commit pass below still has the full tool surface and
        // simply works without notes, which is exactly the old single-session behaviour.
        //
        // It alone among the discovery sessions gets `eventWindow` — see `explorerTools`.
        let exploreTools = explorerTools(substrate)
        func exploreSession() -> LanguageModelSession {
            LanguageModelSession(
                model: Self.model, tools: exploreTools, instructions: Instructions.explorer
            )
        }
        let explored = try? await Self.respondWithOverflowRetry(
            session: exploreSession(),
            prompt: """
            Measure what matters for this angle: \(lens)

            \(Self.gatherBudgetClause)
            """,
            generating: ExplorationNotes.self,
            freshSession: exploreSession
        ).notes
        let measured = Self.measuredBlock(explored)

        /// PASS 2 — COMMIT. A fresh window that starts already holding the first pass's numbers, so
        /// its own four calls go on TESTING the angle rather than re-discovering it.
        func commitSession() -> LanguageModelSession {
            LanguageModelSession(model: Self.model, tools: tools, instructions: Instructions.investigator)
        }
        // What's already on the feed joins the rest of the covered ground in ONE block — it used to
        // be appended here while the run-ledger's entries were appended to the lens string in
        // `Orchestrator`, so the prompt carried two differently-worded ban lists in two places.
        var covered = avoid
        covered.onFeed = await Array(((try? writer.recentFindingDescriptors(now: now)) ?? []).prefix(8))
        // Terse on purpose: the instructions carry the doctrine, and every repeated sentence here is
        // budget stolen from the exploration itself. The avoid-list goes LAST, after the task
        // statement — it used to arrive mid-sentence, so the instruction to commit findings read as
        // a continuation of the list of findings not to make.
        let prompt = """
        Focus this pass on: \(lens)

        Explore with at most FOUR tool calls, then commit your findings — the context window is \
        small. Propose zero rather than pad.\(measured)\(covered.rendered())
        """
        return try await Self.respondWithOverflowRetry(
            session: commitSession(), prompt: prompt, generating: InvestigationResult.self,
            freshSession: commitSession
        ).findings
    }

    // MARK: Scouting (the discovery loop's agent)

    /// One surveying scout: a lighter tool surface than the investigator (it drops the two
    /// heaviest schemas — metricStats' full 72-key vocabulary and analyze's 7 arguments — and gains
    /// `coverage`), because a scout READS the map and hands back leads; the investigator does the
    /// hypothesis testing. Ephemeral and single-use, like every leaf session.
    func scout(
        lens: String,
        avoid: AvoidList,
        substrate: AnalysisSubstrate,
        now _: Date = .now
    ) async throws -> [ProposedLead] {
        let tools = scoutTools(substrate)
        let session = LanguageModelSession(
            model: Self.model,
            tools: tools,
            instructions: Instructions.scout
        )
        // Same shape as the investigator's, and repaired for the same reason: the avoid-list used
        // to be appended to the LENS STRING, so it landed between the angle and the task statement
        // and left a doubled period where the two sentences met.
        let prompt = """
        Scout this angle: \(lens)

        Survey with at most THREE tool calls, then commit your leads — the context window is small. \
        Hand over zero rather than pad.\(avoid.rendered())
        """
        return try await Self.respondWithOverflowRetry(
            session: session, prompt: prompt, generating: ScoutReport.self
        ) {
            LanguageModelSession(model: Self.model, tools: tools, instructions: Instructions.scout)
        }.leads
    }

    // MARK: Replication (the verification loop's armed agent)

    /// One armed replication analyst: unlike the prose-only skeptic, it RE-TESTS the claim against
    /// the data itself. Deliberately the two lightest tools — analyze (agent-defined views; no
    /// metric vocabulary in its schema) and unusualDays — so the session is the roomiest in the
    /// app and the re-test gets real headroom for tool round-trips.
    /// Room for the whole vetting claim: a summary bounded at 600 plus a verified basis bounded at
    /// 900, plus the separator and the unsupported-figures clause. `ReplicationBudgetTests` pins the
    /// relationship to those two bounds, so raising either without raising this fails rather than
    /// silently truncating the evidence again.
    static let maxReplicationClaim = 1700

    /// The composed steering: the re-test itself (the only model-written part, bounded by the
    /// caller) plus two CODE-generated lines the analyst cannot work without — the exact registry
    /// keys, and which metrics have data at all. Generous on purpose: at 240 the metric-key line was
    /// the first thing cut, and it exists because analysts that guessed a key queried nothing and
    /// reported the claim as failing to replicate.
    ///
    /// 805 is the worst case `ReplicationBudgetTests` computes from the two lines' own bounds — the
    /// first value chosen here was 800, and the test caught the five characters rather than the
    /// truncation caught them in production.
    static let maxReplicationLens = 900

    /// Room for the whole assembled run state, whose own budget is `DirectorStateSizeTests`' 2,600.
    static let maxDirectorState = 2700

    /// Each side of a novelty comparison: a one-tap title plus a summary bounded at 600.
    static let maxNoveltySide = 700

    /// The curator's roster is bounded by ROW COUNT (18) rather than by characters, so this is sized
    /// against a saturated roster measured by `PromptDeliveryTests` rather than reasoned about.
    ///
    /// It matters more here than in the other three. The keep-list the curator returns is applied by
    /// walking the WHOLE roster and retiring every row the curator did not name — so a row past the
    /// clamp is not merely unread, it is retired for being unread. At 2,400 the tail of an 18-row
    /// roster was decided by the deterministic quality sort rather than by the agent whose entire
    /// job is that decision.
    static let maxCurationRoster = 4400

    func replicate(claim: String, lens: String, substrate: AnalysisSubstrate) async throws -> Verdict {
        let tools = replicatorTools(substrate)
        let session = LanguageModelSession(
            model: Self.model,
            tools: tools,
            instructions: Instructions.replicator
        )
        // Inputs are clamped here — stored summaries and lens strings are the caller's, but this
        // session's 4k window is ours to protect. The bounds are sized to the EVIDENCE, and were
        // measured on 2026-08-03 because the old ones were not.
        //
        // `claim.prefix(400)` threw away 535 characters of a realistic 935-character claim: the
        // analyst saw 229 of a 763-character verified basis. Two parts of the codebase disagreed
        // about that in writing — `BasisLengthTests` budgets the basis at 900 on the stated grounds
        // that it is "concatenated into the claim every skeptic and every replication analyst
        // reads", while this line ensured about a quarter of it arrived. This is the panel whose
        // entire job is checking a finding against the data, being handed a redacted copy of the
        // evidence.
        //
        // The window can afford it. The replicator prefix is 1,848 tokens against a 2,048 bound, so
        // roughly 2,248 of the 4,096 remain for the prompt, three tool round-trips and the verdict;
        // the old prompt spent about 100 tokens of that and the new one spends about 425. Overflow
        // is recoverable besides — `respondWithOverflowRetry` retries on a fresh session.
        let prompt = """
        Finding under re-test:
        \(PromptText.clamped(claim, to: Self.maxReplicationClaim))

        Your check: \(PromptText.clamped(lens, to: Self.maxReplicationLens))
        Run it with at most THREE tool calls, then judge.
        """
        return try await Self.respondWithOverflowRetry(
            session: session, prompt: prompt, generating: Verdict.self
        ) {
            LanguageModelSession(model: Self.model, tools: tools, instructions: Instructions.replicator)
        }
    }

    /// Run the guided respond; if the session dies from a full context window (or the truncated
    /// output it causes), retry ONCE on a fresh session with a two-call tool budget. Turns what used
    /// to be a hard-skipped pass (the on-device window is only 4,096 tokens) into a usually-recovered
    /// one; a second failure propagates and the orchestrator logs the skip as before. Generic so
    /// every role (investigator, scout, replicator, answerer) shares one recovery path.
    private static func respondWithOverflowRetry<Output: Generable & Sendable>(
        session: LanguageModelSession,
        prompt: String,
        generating _: Output.Type,
        freshSession: () -> LanguageModelSession
    ) async throws -> Output {
        do {
            return try await session.respond(to: prompt, generating: Output.self).content
        } catch {
            guard isContextFailure(error) else { throw error }
            let retryPrompt = prompt
                + "\nBudget is very tight: make at MOST two tool calls, then commit immediately."
            return try await freshSession().respond(to: retryPrompt, generating: Output.self).content
        }
    }

    /// Whether the error means the transcript outgrew the model's context window — directly
    /// (`exceededContextWindowSize`), as the downstream symptom of a truncated guided generation
    /// (`decodingFailure`), or as either of those wrapped in a `ToolCallError`: constrained
    /// decoding of a TOOL'S arguments fails the same way at the window's fullest moment, and field
    /// logs showed exactly that ("Failed to deserialize a Generable type" while invoking
    /// metricStats — the heaviest argument schema) killing whole investigator passes the one
    /// fresh-session retry recovers. Only these are worth a retry; everything else propagates.
    /// Internal (not private) so the unwrap behavior is test-pinned.
    static func isContextFailure(_ error: Error) -> Bool {
        if let toolCall = error as? LanguageModelSession.ToolCallError {
            return isContextFailure(toolCall.underlyingError)
        }
        guard let generation = error as? LanguageModelSession.GenerationError else { return false }
        switch generation {
        case .exceededContextWindowSize, .decodingFailure: return true
        default: return false
        }
    }

    /// The retained prewarm session. Deallocating a session cancels its prewarm — the field logs
    /// showed "Session … in Canceled state in response to PrewarmSession" from the old fire-and-
    /// forget version, meaning the warm-up was thrown away before it loaded anything. `nonisolated
    /// (unsafe)`: worst case a racing re-prewarm replaces an already-warm session, which is benign.
    private nonisolated(unsafe) static var warmSession: LanguageModelSession?

    /// Warm the shared on-device model so the first real generation starts immediately instead of
    /// stalling on a cold load — one fewer idle gap in a run meant to keep the engine busy. The
    /// session is RETAINED (see `warmSession`) so the load actually completes.
    func prewarm() {
        let session = LanguageModelSession(model: Self.model)
        session.prewarm()
        Self.warmSession = session
    }

    // MARK: Direction, curation, novelty (prose-only leaf sessions)

    /// The research director: reads the run's state (facts and numbers — pass yield, dry streak,
    /// feed contents, rejections, prior runs' dead ends) and DECIDES the next pass's strategy.
    /// Prose-only and toolless: the state rides in the prompt, so the session is tiny.
    func direct(state: String, now: Date = .now) async throws -> PassPlan {
        // The one agent that gets a tool without a substrate: its whole job is judging the run's
        // HISTORY, and a toolless session could only ever see the few lines the briefing chose for
        // it. Prose-only and tiny, so there is ample room for the small journal schema.
        let tools = directorTools(now: now)
        func session() -> LanguageModelSession {
            LanguageModelSession(model: Self.model, tools: tools, instructions: Instructions.director)
        }
        // Sized to the state's OWN budget, not to a round number. At 1,200 the director received
        // 1,200 of an assembled 2,500 characters, and the two lines it lost were the last two:
        // "Prior runs ruled out" and "Chased with no yield" — the journal steering and the barren
        // angles, which are the ONLY cross-run memory this agent has. The journal exists so the
        // research program iterates day over day instead of starting amnesiac, and the agent it
        // exists for could not see it.
        //
        // Nothing was being protected. The director has the roomiest session in the app — 447
        // tokens of prefix against a 4,096-token window, so ~3,649 remain — and the full state is
        // about 650.
        let prompt = "Run state:\n\(PromptText.clamped(state, to: Self.maxDirectorState))\n\n"
            + "Consult the journal if it would change your mind, then choose the next pass's "
            + "strategy, directive, and any extra angles."
        return try await Self.respondWithOverflowRetry(
            session: session(), prompt: prompt, generating: PassPlan.self, freshSession: session
        )
    }

    /// The curator: reads the numbered roster (with computed quality/age/overlap facts) and decides
    /// which findings keep their slots. The roster is clamped at the caller AND here — it is built
    /// from stored model-written titles and rides in a 4k window.
    func curate(roster: String, budget: Int) async throws -> CurationDecision {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.curator)
        let prompt = """
        Active findings (keep at most \(budget)):
        \(PromptText.clamped(roster, to: Self.maxCurationRoster))

        Choose the numbers to KEEP.
        """
        return try await session.respond(to: prompt, generating: CurationDecision.self).content
    }

    /// The novelty judge: compares a candidate against the standing finding it collides with and
    /// decides re-tread vs meaningful update. Both sides are clamped — stored and proposed prose
    /// are model-written.
    /// Rewrite a refused finding. Prose-only session, like the skeptic — it needs no tools, because
    /// it is forbidden from changing any number and the numbers are re-resolved from source anyway.
    func rephrase(title: String, summary: String, objection: String) async throws -> Rephrasing {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.rephraser)
        let prompt = """
        The finding, as written:
        \(PromptText.clamped(title, to: 120))
        \(PromptText.clamped(summary, to: FindingPhrasing.Phrasing.maxSummaryLength))

        What the safety reviewer objected to:
        \(PromptText.clamped(objection, to: 400))

        Rewrite it.
        """
        return try await session.respond(to: prompt, generating: Rephrasing.self).content
    }

    func judgeNovelty(candidate: String, prior: String) async throws -> NoveltyVerdict {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.noveltyJudge)
        // Both sides are "title: summary", and the summary alone is bounded at 600 — so 380 cut a
        // candidate roughly in half and did it mid-word. This agent's whole job is deciding whether
        // two pieces of prose say the same thing; handing it half of each is asking the question it
        // cannot answer. Its session is prose-only with no tools, so the room was always there.
        let prompt = """
        Standing finding:
        \(PromptText.clamped(prior, to: Self.maxNoveltySide))

        Newly proposed:
        \(PromptText.clamped(candidate, to: Self.maxNoveltySide))

        Meaningful update, or re-tread?
        """
        return try await session.respond(to: prompt, generating: NoveltyVerdict.self).content
    }

    /// Sizes the skeptic panel to the claim: a prose-only session that reads the finding and
    /// proposes the challenges the fixed six would miss. Cheap (no tools) relative to the extra
    /// skeptic sessions it buys, and additive — the fixed lenses always run regardless.
    func composeChallenges(finding: String) async throws -> ChallengeSet {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.challenger)
        let prompt = "Finding about to be scrutinised:\n\(PromptText.clamped(finding, to: 600))\n\n"
            + "What should the panel ask that a generic reviewer would not?"
        return try await session.respond(to: prompt, generating: ChallengeSet.self).content
    }

    /// Sizes the ARMED panel to the claim, as `composeChallenges` does for the prose panel. Each
    /// re-test it names becomes another analyst driving `analyze`/`unusualDays` against the data.
    /// `available` is the shortlist of metrics the person actually has data for. A re-test naming
    /// anything else is spent before it starts — see the note at its call site.
    func composeRetests(claim: String, available: String?) async throws -> RetestPlan {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.retestPlanner)
        let prompt = "Claim under re-test:\n\(PromptText.clamped(claim, to: 600))\n\n"
            + (available.map { "\($0)\n\n" } ?? "")
            + "What should be computed that a generic re-test would not?"
        return try await session.respond(to: prompt, generating: RetestPlan.self).content
    }

    func scrutinize(finding: String, lens: String) async throws -> Verdict {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.skeptic)
        let prompt = "Proposed finding:\n\(finding)\n\nScrutinize it specifically through this "
            + "challenge:\n\(lens)\n\nSet holdsUp to true only if it survives even this."
        return try await session.respond(to: prompt, generating: Verdict.self).content
    }

    func reviewSafety(text: String, lens: String) async throws -> SafetyVerdict {
        let session = LanguageModelSession(model: Self.model, instructions: Instructions.safetyReviewer)
        let prompt = "Text the app will show:\n\(text)\n\nJudge this specific safety concern:\n\(lens)"
        return try await session.respond(to: prompt, generating: SafetyVerdict.self).content
    }

    // MARK: Two-pass scaffolding (shared by the investigator's explore pass and Ask's gather pass)

    /// The tool budget both first passes state. One sentence, one place: the two prompts are
    /// documented as the same pass (see `askGatherTools`), and a budget tuned on one of them while
    /// the other kept the old number would make that claim quietly false.
    static let gatherBudgetClause = "Use at most FOUR tool calls, then report your readings."

    /// Readings kept from a first pass, and characters kept from each — the clamp that stops an
    /// exploratory pass's output from eating the second pass's 4,096-token window.
    static let maxReadings = 5
    static let maxReadingCharacters = 160

    /// The first pass's findings, clamped and formatted for the second pass's prompt.
    ///
    /// This was written out twice, and had already drifted: one site opened the block with a single
    /// newline and the other with two. Harmless in itself, and exactly the shape that is not harmless
    /// next time — the two clamps were duplicated alongside it, so tuning 5 or 160 on one path would
    /// silently have left the other on the old budget, on the window this app overflows soonest.
    static func measuredBlock(_ notes: [String]?) -> String {
        let readings = (notes ?? []).prefix(maxReadings).map { String($0.prefix(maxReadingCharacters)) }
        guard !readings.isEmpty else { return "" }
        return "\n\nAlready measured for you (verify anything you rely on):\n"
            + readings.map { "\u{00B7} \($0)" }.joined(separator: "\n")
    }

    // MARK: Q&A

    /// One agentic Q&A session over the full logical tool surface — the same tools the investigator
    /// drives, plus past-insight search. The agent decides what to look up (single metric, custom
    /// view, or a relationship) and pulls the real numbers itself; scope is its judgment too.
    /// `history` is the Ask screen's earlier exchanges, replayed in clamped form so a follow-up has
    /// a referent — see `ConversationTurn`.
    func answer(
        question: String,
        history: [ConversationTurn] = [],
        substrate: AnalysisSubstrate,
        now: Date = .now
    ) async throws -> Answer {
        let tools = answererTools(substrate, now: now)
        // PASS 1 — GATHER, on its own window, exactly like the investigator's explore pass. A
        // question that needs several lookups used to have to fit them, the reasoning, and the
        // written answer into one 4k window; the readings now arrive already paid for.
        //
        // Same prompt AND same tools as the investigator's explore pass — see `askGatherTools`.
        let gatherTools = askGatherTools(substrate)
        func gatherSession() -> LanguageModelSession {
            LanguageModelSession(
                model: Self.model, tools: gatherTools, instructions: Instructions.explorer
            )
        }
        // The gather pass needs the context MORE than the answering pass does: it has to resolve
        // "why?" into something measurable before it can pick a tool at all, and a tool call made
        // against the wrong referent spends one of its four on the wrong metric.
        let context = ConversationTurn.context(history).map { "\($0)\n\n" } ?? ""
        let explored = try? await Self.respondWithOverflowRetry(
            session: gatherSession(),
            prompt: """
            \(context)Measure what is needed to answer this question: \(question). \
            \(Self.gatherBudgetClause)
            """,
            generating: ExplorationNotes.self,
            freshSession: gatherSession
        ).notes
        let measured = Self.measuredBlock(explored)

        /// PASS 2 — ANSWER. Same recovery as every exploring role: an exploration that outgrows the
        /// 4k window gets ONE fresh-session retry with a hard tool budget rather than failing the
        /// user's question.
        func answerSession() -> LanguageModelSession {
            LanguageModelSession(model: Self.model, tools: tools, instructions: Instructions.answerer)
        }
        return try await Self.respondWithOverflowRetry(
            session: answerSession(),
            prompt: "\(context)Question: \(question)\(measured)",
            generating: Answer.self, freshSession: answerSession
        )
    }
}
