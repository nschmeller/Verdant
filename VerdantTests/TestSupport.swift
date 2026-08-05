import Foundation
import SwiftData
import Synchronization
@testable import Verdant

/// Test-only read of the singleton `AgentState` (production only writes it; the UI reads via `@Query`).
struct AgentStateReadback: Equatable {
    let mode: String
    let findingCount: Int
    let totalRuns: Int
    let at: Date
}

extension StoreWriter {
    /// Test-only: plant a 1,825-era `deepened#` marker, so the versioned-key migration (old markers
    /// must NOT count as deepened) stays pinned.
    func seedLegacyDeepenMarker(for metric: MetricKey, now: Date = .now) throws {
        modelContext.insert(SyncAnchor(
            sampleType: "deepened#\(metric.rawValue)", anchorData: Data(), updatedAt: now
        ))
        try modelContext.save()
    }

    /// Test-only: the titles of every ACTIVE finding the curator promoted to "Worth your attention"
    /// (production reads these through the feed's `@Query`).
    func highlightedTitlesForTest() throws -> [String] {
        let insights = try modelContext.fetch(FetchDescriptor<InsightLog>())
            .filter { $0.highlighted && !$0.tombstoned }.map(\.oneTapTitle)
        let correlations = try modelContext.fetch(FetchDescriptor<CorrelationLog>())
            .filter { $0.highlighted && !$0.tombstoned }.map(\.oneTapTitle)
        return insights + correlations
    }

    /// Test-only: when every journal row was stamped. Reading the DATES, not the text, is the point:
    /// the scan that guards this can only see that `now:` was passed, never that the value passed was
    /// the run's clock rather than `Date()`.
    func journalStampsForTest() throws -> [Date] {
        try modelContext.fetch(FetchDescriptor<ResearchJournalEntry>()).map(\.createdAt)
    }

    /// Test-only: the display prose of every ACTIVE finding — what the user would actually read.
    func activeSummariesForTest() throws -> [String] {
        let insights = try modelContext.fetch(FetchDescriptor<InsightLog>())
            .filter { !$0.tombstoned }.map(\.summary)
        let correlations = try modelContext.fetch(FetchDescriptor<CorrelationLog>())
            .filter { !$0.tombstoned }.map(\.summary)
        return insights + correlations
    }

    /// Test-only: the recorded provenance of every ACTIVE finding that has one.
    func provenanceForTest() throws -> [String] {
        let insights = try modelContext.fetch(FetchDescriptor<InsightLog>())
            .filter { !$0.tombstoned && !$0.provenance.isEmpty }.map(\.provenance)
        let correlations = try modelContext.fetch(FetchDescriptor<CorrelationLog>())
            .filter { !$0.tombstoned && !$0.provenance.isEmpty }.map(\.provenance)
        return insights + correlations
    }

    func agentStateForTest() throws -> AgentStateReadback? {
        guard let state = try modelContext.fetch(FetchDescriptor<AgentState>()).first else { return nil }
        return AgentStateReadback(
            mode: state.lastRunMode,
            findingCount: state.lastRunFindingCount,
            totalRuns: state.totalRuns,
            at: state.lastRunAt
        )
    }
}

/// A deterministic phrasing of a verified fact — TEST-ONLY. Production never templates a finding (all
/// shown prose is safety-vetted LLM output), so this generator lives in the test target; tests use it
/// to construct a neutral `Phrasing` for persistence/curation tests without invoking the model.
extension FindingPhrasing {
    static func phrasing(for fact: VerifiedFact) -> Phrasing {
        let name = fact.metric.displayName.lowercased()
        let recent = MetricFormatting.formatted(fact.recent, fact.metric)
        let baseline = MetricFormatting.formatted(fact.baseline, fact.metric)
        let pct = MetricFormatting.signedPercent(fact.pctChange)
        let magnitude = switch fact.magnitude {
        case .slight: "slightly"
        case .moderate: "moderately"
        case .large: "notably"
        }
        let summary = "Your \(name) was \(magnitude) \(fact.direction.word) over \(fact.comparison.recentLabel) "
            + "— about \(recent) versus \(baseline) for \(fact.comparison.baselineLabel) (\(pct))."
        let title = "\(fact.metric.displayName) \(fact.direction.word) (\(fact.comparison.displayName))"
        return Phrasing(summary: summary, oneTapTitle: title)
    }
}

/// Shared helpers for the test suite: in-memory stores, rollup seeding, and a deterministic fake
/// subagent so the Orchestrator loop can be exercised without the on-device model.
enum TestSupport {
    static func inMemoryContainer() throws -> ModelContainer {
        try AppContainer.makeContainer(inMemory: true)
    }

    /// Seed daily rollups for `metric` across `daysAgo` (relative to `now`), with light deterministic
    /// jitter so the baseline has non-zero spread (a zero-SD baseline is intentionally "not
    /// confident"). `jitter: 0` produces a flat series.
    static func seed(
        _ writer: StoreWriter,
        metric: MetricKey,
        value: Double,
        daysAgo: ClosedRange<Int>,
        jitter: Double = 40,
        now: Date
    ) async throws {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        var rollups: [DayRollup] = []
        for k in daysAgo {
            let day = calendar.date(byAdding: .day, value: -k, to: today)!
            let v = value + Double((k % 3) - 1) * jitter
            rollups.append(DayRollup(
                metric: metric,
                dayStart: day,
                values: DayValues(mean: v, sum: v, count: 1)
            ))
        }
        try await writer.applyRollups(upserts: rollups, deletions: [])
    }
}

/// Reference-type call recorder shared across copies of the value-type fake, so tests can assert
/// that a flow actually issued the calls it claims to (nothing else in the suite records counts).
/// Mutex-guarded: the fan-outs are serial (`maxConcurrent = 1`) but the recorder shouldn't rely on it.
final class SubagentCallRecorder: Sendable {
    private struct State {
        var investigateLenses: [String] = []
        var scoutLenses: [String] = []
        var scrutinyLenses: [String] = []
        var safetyLenses: [String] = []
        var scrutinyClaims: [String] = []
        var replicateClaims: [String] = []
        var replicateLenses: [String] = []
        /// The available-metrics shortlist handed to the re-test PLANNER — nil when it planned blind.
        var retestPlanAvailable: [String?] = []
        var directStates: [String] = []
        var curateRosters: [String] = []
        var noveltyPriors: [String] = []
        var answerHistories: [[ConversationTurn]] = []
    }

    private let state = Mutex(State())

    func recordInvestigate(lens: String) {
        state.withLock { $0.investigateLenses.append(lens) }
    }

    /// The conversation replayed into each Q&A call. Recorded because the parameter carrying it is
    /// defaulted the whole way down the chain, so every link can compile, run, and silently pass
    /// nothing.
    func recordAnswer(history: [ConversationTurn]) {
        state.withLock { $0.answerHistories.append(history) }
    }

    var answerHistories: [[ConversationTurn]] {
        state.withLock { $0.answerHistories }
    }

    func recordScout(lens: String) {
        state.withLock { $0.scoutLenses.append(lens) }
    }

    /// The concern each safety reviewer was given. The panel's value rests on those being DIFFERENT
    /// — it fails closed on a unanimous rule, so identical reviewers would agree repeatedly about
    /// one concern while every other went unasked.
    func recordSafety(lens: String) {
        state.withLock { $0.safetyLenses.append(lens) }
    }

    func recordScrutinize(finding: String, lens: String) {
        state.withLock {
            $0.scrutinyClaims.append(finding)
            $0.scrutinyLenses.append(lens)
        }
    }

    func recordReplicate(claim: String, lens: String) {
        state.withLock {
            $0.replicateClaims.append(claim)
            $0.replicateLenses.append(lens)
        }
    }

    func recordDirect(state stateDigest: String) {
        state.withLock { $0.directStates.append(stateDigest) }
    }

    func recordCurate(roster: String) {
        state.withLock { $0.curateRosters.append(roster) }
    }

    func recordNovelty(prior: String) {
        state.withLock { $0.noveltyPriors.append(prior) }
    }

    var investigateLenses: [String] {
        state.withLock { $0.investigateLenses }
    }

    var scoutLenses: [String] {
        state.withLock { $0.scoutLenses }
    }

    /// The challenges each skeptic was actually given — the fixed six plus whatever the challenger
    /// composed for the specific finding.
    var scrutinyLenses: [String] {
        state.withLock { $0.scrutinyLenses }
    }

    var safetyLenses: [String] {
        state.withLock { $0.safetyLenses }
    }

    /// The full claim text each skeptic was shown — prose, verified basis, and the computed
    /// unsupported-figures line when there is one.
    var scrutinyClaims: [String] {
        state.withLock { $0.scrutinyClaims }
    }

    var replicateClaims: [String] {
        state.withLock { $0.replicateClaims }
    }

    var replicateLenses: [String] {
        state.withLock { $0.replicateLenses }
    }

    func recordRetestPlan(available: String?) {
        state.withLock { $0.retestPlanAvailable.append(available) }
    }

    var retestPlanAvailable: [String?] {
        state.withLock { $0.retestPlanAvailable }
    }

    /// The shortlist the planner got on its first call, flattened — `nil` means it planned blind.
    ///
    /// Flattened HERE rather than at the call site, and spelled out with a `guard` rather than any
    /// shorter form, because `retestPlanAvailable.first` is a `String??` and the tooling disagrees
    /// with every concise way of collapsing one: swiftformat rewrites `flatMap { $0 }` into
    /// `flatMap(\.self)`, which does not compile, and swiftlint calls `?? nil` redundant when it is
    /// doing the actual work. The first cost a passing test one `swiftformat .` later.
    var firstRetestPlanAvailable: String? {
        state.withLock {
            guard let first = $0.retestPlanAvailable.first else { return nil }
            return first
        }
    }

    var directStates: [String] {
        state.withLock { $0.directStates }
    }

    var curateRosters: [String] {
        state.withLock { $0.curateRosters }
    }

    var noveltyPriors: [String] {
        state.withLock { $0.noveltyPriors }
    }
}

/// A deterministic `SubagentRunning` for integration tests — returns fixed canned values so the
/// Orchestrator's verify → safety → persist path can be tested without the model.
struct FakeSubagents: SubagentRunning {
    /// Findings the agentic investigator "uncovers" — the inverted discovery path (all finding kinds).
    var proposals: [ProposedFinding] = []
    var answerText: String?
    /// Verdict every skeptic returns. Defaults to "holds up" so adversarial verification is a no-op
    /// unless a test deliberately makes the panel reject findings.
    var scrutinyHoldsUp = true
    /// When true, every skeptic call throws — simulating a rate-limit/transient infra failure so the
    /// fall-open behavior (don't drop a good finding because the panel was thinned) can be exercised.
    var scrutinyFails = false
    /// When true, every finding-generation call (discover/analyze/phrase…) throws — simulating a
    /// wholesale inference failure (model "available" but every call errors), so the run can be checked
    /// to report it honestly and NOT record itself as a completed analysis.
    var failAllLLM = false
    /// Verdict the safety panel returns for every lens. Defaults to safe so the pipeline runs; a test
    /// sets it false to prove the agent panel (not a blocklist) is what gates unsafe prose.
    /// Whether a replication analyst could RUN its check. False simulates the observed real-model
    /// case: the analyst queried a metric with no data and reported "No data for …".
    var replicationCouldTest = true
    var safetyIsSafe = true
    /// Set to exercise the rescue path: the rephraser returns this instead of the original summary.
    var rephrasedSummary: String?
    var rephrasedTitle: String?
    /// When set, the safety panel refuses ONLY text containing this substring — so a rewrite that
    /// drops the phrase clears the same panel that refused the original.
    var safetyRefusesTextContaining: String?
    /// The reviewer's own sentence. Distinctive by default so a test asserting the feed names the
    /// reviewer's reasoning cannot pass on the lens text, which is what the feed used to print.
    var safetyWhy = "names a condition as the user's"
    /// When true, every safety-panel call throws — exercising the fail-CLOSED posture (a finding whose
    /// safety can't be confirmed is dropped).
    var safetyFails = false
    /// Leads every scout hands over — the discovery loop's agent.
    var scoutLeads: [ProposedLead] = []
    /// Verdict every armed replication analyst returns. Defaults to "holds up" so the replication
    /// panel is a pass-through in tests that aren't about it (the persistence quartet stays green).
    var replicationHoldsUp = true
    /// When true, every replication call throws — exercising the panel's fall-open-on-empty posture.
    var replicationFails = false
    /// Plan the research director returns each pass. Defaults to breadth so deep-run tests
    /// exercise the same sweep path as the pre-director loop; a test overrides it to pin
    /// drill/frontier routing.
    var passPlan = PassPlan(strategy: "breadth", directive: "", extraLenses: [])
    /// When true, director calls throw — exercising the deterministic dry-streak fallback.
    var directorFails = false
    /// Roster numbers the curator keeps. Defaults to keep-everything (numbers beyond the roster
    /// are ignored by the orchestrator's closed-roster boundary) so persistence-focused tests see
    /// an untouched feed.
    var curationKeep: [Int] = Array(0..<64)
    /// Roster numbers the curator promotes to "Worth your attention". Defaults to none, so the
    /// feed's highlight section is empty unless a test is specifically about it.
    var curationHighlight: [Int] = []
    /// When true, curator calls throw — exercising the deterministic curation fallback.
    var curatorFails = false
    /// Whether the novelty judge calls a collision a meaningful update. Defaults false — the
    /// standing finding keeps its slot, matching the old deterministic window's behavior.
    var noveltyIsUpdate = false
    /// Optional shared recorder for call-count/ordering assertions.
    var calls: SubagentCallRecorder?

    struct FakeError: Error {}

    /// Angles the investigator chases and comes back empty from, matched against the START of the
    /// lens (the orchestrator appends its steering lines before calling). Lets a test make SOME
    /// lenses barren while others produce, which is the per-lens yield the barren journal records.
    var lensesWithNoFindings: Set<String> = []
    /// Angles for which the investigator session THROWS — a rate-limit or model blip. Distinct from
    /// `lensesWithNoFindings` on purpose: a session that never rendered is not evidence that the
    /// angle is barren, and the two must not be conflated.
    var lensesThatFail: Set<String> = []

    func investigate(
        lens: String,
        avoid: AvoidList,
        substrate _: AnalysisSubstrate,
        now _: Date
    ) async throws -> [ProposedFinding] {
        // Recorded as the model sees it, so steering assertions read the real prompt text.
        calls?.recordInvestigate(lens: lens + avoid.rendered())
        if failAllLLM { throw FakeError() }
        if lensesThatFail.contains(where: { lens.hasPrefix($0) }) { throw FakeError() }
        if lensesWithNoFindings.contains(where: { lens.hasPrefix($0) }) { return [] }
        return proposals
    }

    nonisolated func prewarm() {}

    /// Challenges the challenger adds to the skeptic panel. Empty by default, so panel-size
    /// assertions elsewhere stay pinned to the fixed six unless a test is about this.
    var composedChallenges: [String] = []

    /// Extra re-tests the planner adds to the armed panel. Empty by default.
    var composedRetests: [String] = []

    func composeRetests(claim _: String, available: String?) async throws -> RetestPlan {
        calls?.recordRetestPlan(available: available)
        if failAllLLM || replicationFails { throw FakeError() }
        return RetestPlan(retests: composedRetests)
    }

    func composeChallenges(finding _: String) async throws -> ChallengeSet {
        if failAllLLM || scrutinyFails { throw FakeError() }
        return ChallengeSet(challenges: composedChallenges)
    }

    func scrutinize(finding: String, lens: String) async throws -> Verdict {
        calls?.recordScrutinize(finding: finding, lens: lens)
        if scrutinyFails { throw FakeError() }
        return Verdict(why: "", couldTest: true, holdsUp: scrutinyHoldsUp)
    }

    func direct(state: String, now _: Date) async throws -> PassPlan {
        calls?.recordDirect(state: state)
        if failAllLLM || directorFails { throw FakeError() }
        return passPlan
    }

    func curate(roster: String, budget _: Int) async throws -> CurationDecision {
        calls?.recordCurate(roster: roster)
        if failAllLLM || curatorFails { throw FakeError() }
        return CurationDecision(keep: curationKeep, highlight: curationHighlight)
    }

    /// Default: the rephraser hands back the summary UNCHANGED, which the orchestrator reads as
    /// "this finding cannot be said without the objection" and drops without re-running the panel.
    /// So every existing safety-rejection test keeps its exact old meaning; a test that wants the
    /// rescue path sets `rephrasedSummary`.
    func rephrase(title: String, summary: String, objection _: String) async throws -> Rephrasing {
        if failAllLLM { throw FakeError() }
        return Rephrasing(
            changed: rephrasedSummary == nil ? "nothing — the finding IS the cause" : "removed the cause",
            oneTapTitle: rephrasedTitle ?? title,
            summary: rephrasedSummary ?? summary
        )
    }

    func judgeNovelty(candidate _: String, prior: String) async throws -> NoveltyVerdict {
        calls?.recordNovelty(prior: prior)
        if failAllLLM { throw FakeError() }
        return NoveltyVerdict(meaningfulUpdate: noveltyIsUpdate)
    }

    func reviewSafety(text: String, lens: String) async throws -> SafetyVerdict {
        calls?.recordSafety(lens: lens)
        if failAllLLM || safetyFails { throw FakeError() }
        // Text-sensitive so the rephrase path can be exercised: a panel that answers identically
        // whatever it reads cannot tell a rewrite from the prose it replaced.
        if let trigger = safetyRefusesTextContaining {
            return SafetyVerdict(why: safetyWhy, isSafe: !text.contains(trigger))
        }
        return SafetyVerdict(why: safetyWhy, isSafe: safetyIsSafe)
    }

    func scout(
        lens: String, avoid: AvoidList, substrate _: AnalysisSubstrate, now _: Date
    ) async throws -> [ProposedLead] {
        calls?.recordScout(lens: lens + avoid.rendered())
        if failAllLLM { throw FakeError() }
        return scoutLeads
    }

    func replicate(claim: String, lens: String, substrate _: AnalysisSubstrate) async throws -> Verdict {
        calls?.recordReplicate(claim: claim, lens: lens)
        if failAllLLM || replicationFails { throw FakeError() }
        return Verdict(why: "", couldTest: replicationCouldTest, holdsUp: replicationHoldsUp)
    }

    func answer(
        question _: String, history: [ConversationTurn], substrate _: AnalysisSubstrate, now _: Date
    ) async throws -> Answer {
        calls?.recordAnswer(history: history)
        if failAllLLM { throw FakeError() }
        return Answer(text: answerText ?? "Here's what your data shows.")
    }
}
