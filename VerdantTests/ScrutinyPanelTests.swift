import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The adversarial panel's threshold is the app's core "only exceptional findings survive" gate, and
/// the live `FakeSubagents` can only make every skeptic vote alike — so the mixed-panel boundaries
/// (a 2-1 split holds, a tie or 1-2 split drops) would otherwise go unguarded. These pin them on the
/// pure decision, where a `>`→`>=` slip flipping tie-rejects-to-survives is caught.
struct ScrutinyPanelTests {
    private func verdicts(hold: Int, reject: Int) -> [Verdict] {
        Array(repeating: Verdict(why: "", couldTest: true, holdsUp: true), count: hold)
            + Array(repeating: Verdict(why: "", couldTest: true, holdsUp: false), count: reject)
    }

    @Test func `an empty panel falls open, but a lone rendered verdict counts`() {
        // Nothing rendered → pure infra failure → fall open (don't drop a vetted finding).
        #expect(Orchestrator.panelHolds([]))
        // A lone "hold" keeps it; a lone "reject" now DROPS it — a rendered verdict is a quality
        // judgment, not infra noise, so a thinned-to-one-reject panel must not silently pass a finding.
        #expect(Orchestrator.panelHolds(verdicts(hold: 1, reject: 0)))
        #expect(!Orchestrator.panelHolds(verdicts(hold: 0, reject: 1)))
    }

    @Test func `a strict majority is required and a tie rejects`() {
        // Two rendered: both must hold; a 1-1 tie drops ("when in doubt, leave it out").
        #expect(Orchestrator.panelHolds(verdicts(hold: 2, reject: 0)))
        #expect(!Orchestrator.panelHolds(verdicts(hold: 1, reject: 1)))
        #expect(!Orchestrator.panelHolds(verdicts(hold: 0, reject: 2)))
    }

    @Test func `a full panel holds on two of three and drops on one of three`() {
        #expect(Orchestrator.panelHolds(verdicts(hold: 3, reject: 0)))
        #expect(Orchestrator.panelHolds(verdicts(hold: 2, reject: 1)))
        #expect(!Orchestrator.panelHolds(verdicts(hold: 1, reject: 2)))
        #expect(!Orchestrator.panelHolds(verdicts(hold: 0, reject: 3)))
    }
}

/// The skeptic panel driven end to end through a live `Orchestrator` — the posture tests (bypassed,
/// rejects, endorses, falls open on infra failure, fails closed on a spent budget) and the
/// challenger that sizes the panel to the claim. Split out of `OrchestratorTests`, which had grown
/// past its length limit; the pure threshold arithmetic stays in the struct above.
struct LiveScrutinyPanelTests {
    private func makeOrchestrator(
        _ container: ModelContainer,
        capability: LLMCapability,
        subagents: any SubagentRunning
    ) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(),
            subagents: subagents,
            capability: { capability }
        )
    }

    private func scrutinyContext(adversarial: Bool) -> DiscoveryContext {
        DiscoveryContext(jobID: UUID(), now: Date(), deadline: nil, progress: nil, adversarial: adversarial)
    }

    @Test func `the skeptic panel is bypassed when adversarial is off`() async throws {
        let container = try TestSupport.inMemoryContainer()
        // Even a panel that would reject everything is bypassed when adversarial is off.
        var fake = FakeSubagents()
        fake.scrutinyHoldsUp = false
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let survives = await orchestrator.survivesScrutiny(
            "any story", subject: "a test finding", scrutinyContext(adversarial: false)
        )
        #expect(survives.passed)
    }

    @Test func `a deep finding the skeptics reject is dropped`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.scrutinyHoldsUp = false
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let survives = await orchestrator.survivesScrutiny(
            "a flimsy story",
            subject: "a test finding",
            scrutinyContext(adversarial: true)
        )
        #expect(!survives.passed)
    }

    @Test func `a deep finding the skeptics endorse survives`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let fake = FakeSubagents() // scrutinyHoldsUp defaults to true
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let survives = await orchestrator.survivesScrutiny(
            "a robust story",
            subject: "a test finding",
            scrutinyContext(adversarial: true)
        )
        #expect(survives.passed)
    }

    /// The panel used to pose the same six questions to every finding, however different the
    /// claims. A challenger agent now reads the specific finding and adds the questions the fixed
    /// six would miss — so the panel's SIZE tracks the claim rather than a constant.
    @Test func `the challenger's questions become extra skeptics`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.composedChallenges = [
            "could the lag simply be the weekend?", "   ", "is the pair mechanically coupled?"
        ]
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        let survives = await orchestrator.survivesScrutiny(
            "a story", subject: "a test finding", scrutinyContext(adversarial: true)
        )

        #expect(survives.passed)
        // The fixed six all ran, PLUS the two non-blank composed questions.
        #expect(survives.rendered == Orchestrator.scrutinyLenses.count + 2)
        #expect(calls.scrutinyLenses.contains { $0.contains("could the lag simply be the weekend?") })
        // A blank challenge never becomes a skeptic session with no question in it.
        #expect(!calls.scrutinyLenses.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Every reviewer must get a DIFFERENT question.
    ///
    /// Panel diversity is the whole reason a panel beats one reviewer — the code says so in several
    /// places: "giving each reviewer its own angle catches failure modes that identical reviewers
    /// would all miss together". Nothing checked it. A fan-out that handed the same lens to every
    /// member would still produce the right panel SIZE, still contain the composed challenge, and
    /// still have no blank lens — passing every existing check here — while actually being six
    /// copies of one skeptic that all agree for the same reason. The finding would clear a majority
    /// vote it never really faced.
    @Test func `every skeptic is asked a different question`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.composedChallenges = ["could the lag simply be the weekend?"]
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        _ = await orchestrator.survivesScrutiny(
            "a story", subject: "a test finding", scrutinyContext(adversarial: true)
        )

        let asked = calls.scrutinyLenses
        #expect(asked.count == Orchestrator.scrutinyLenses.count + 1)
        #expect(Set(asked).count == asked.count, "a question was posed twice: \(asked)")
        // And the roster really is the fixed six plus the composed one, not six of something else.
        #expect(Set(Orchestrator.scrutinyLenses).isSubset(of: Set(asked)))
    }

    /// The same property for the safety panel, where losing it matters more: safety fails CLOSED on
    /// a unanimous rule, so five identical reviewers would agree five times over on whichever single
    /// concern they all happened to be given — and every OTHER concern would go unasked.
    @Test func `every safety reviewer is given a different concern`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        let calls = SubagentCallRecorder()
        fake.calls = calls
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)

        _ = await orchestrator.passesSafety("some prose about a finding")

        let asked = calls.safetyLenses
        #expect(asked.count == Orchestrator.safetyLenses.count)
        #expect(Set(asked).count == asked.count, "a concern was reviewed twice: \(asked)")
        #expect(Set(asked) == Set(Orchestrator.safetyLenses))
    }

    /// Strictly additive: a challenger that says nothing — or fails outright — must leave the panel
    /// exactly as strong as it was, never weaker.
    @Test func `a silent challenger leaves the fixed panel untouched`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let orchestrator = makeOrchestrator(
            container, capability: .available, subagents: FakeSubagents()
        )

        let survives = await orchestrator.survivesScrutiny(
            "a story", subject: "a test finding", scrutinyContext(adversarial: true)
        )

        #expect(survives.rendered == Orchestrator.scrutinyLenses.count)
    }

    @Test func `scrutiny falls open when the skeptic panel fails on infrastructure`() async throws {
        let container = try TestSupport.inMemoryContainer()
        // Every skeptic call errors (rate-limit/transient). A finding that already cleared phrasing
        // and safety must NOT be dropped just because the panel couldn't render a verdict.
        var fake = FakeSubagents()
        fake.scrutinyFails = true
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: fake)
        let survives = await orchestrator.survivesScrutiny(
            "a good story",
            subject: "a test finding",
            scrutinyContext(adversarial: true)
        )
        #expect(survives.passed)
    }

    @Test func `scrutiny fails closed when the budget is spent before the panel can run`() async throws {
        let container = try TestSupport.inMemoryContainer()
        // The panel WOULD endorse (default), but the deadline has already passed — so the panel never
        // ran, the finding is unvetted, and "when in doubt, leave it out" wins. The next run re-derives
        // and vets it. This proves it's the spent budget dropping the finding, not a reject verdict.
        let orchestrator = makeOrchestrator(container, capability: .available, subagents: FakeSubagents())
        let spent = DiscoveryContext(
            jobID: UUID(), now: Date(),
            deadline: ContinuousClock.now.advanced(by: .seconds(-1)),
            progress: nil, adversarial: true
        )
        let survives = await orchestrator.survivesScrutiny("a good story", subject: "a test finding", spent)
        #expect(!survives.passed)
    }
}
