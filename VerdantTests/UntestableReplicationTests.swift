import Foundation
import SwiftData
import Testing
@testable import Verdant

/// An analyst that could not RUN its check has refuted nothing.
///
/// `Verdict.holdsUp` was carrying two different meanings: "I re-tested it and the effect vanished"
/// and "I could not get the data to re-test". The replicator's instruction says "when in doubt,
/// false", so the second became the first, and `panelHolds` counted it as evidence against.
///
/// Observed against the real on-device model: asked to re-test a resting-heart-rate step, an analyst
/// queried a metric with no data, answered "No data for Heart rate.", and the panel scored 0 of 5 —
/// rejecting a claim whose own verified basis stated the numbers. The panel already excludes verdicts
/// that never rendered on exactly this reasoning; "rendered but untestable" belongs in the same class.
struct UntestableReplicationTests {
    private func makeOrchestrator(
        _ container: ModelContainer, _ fake: FakeSubagents
    ) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(), subagents: fake, capability: { .available }
        )
    }

    private func context(_ container: ModelContainer) async throws -> DiscoveryContext {
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 8000, daysAgo: 1...40, jitter: 400, now: Date()
        )
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(), now: Date()
        )
        return DiscoveryContext(
            jobID: UUID(), now: Date(), deadline: nil, progress: nil,
            substrate: substrate, adversarial: true
        )
    }

    /// Untestable analysts do not vote the finding down.
    @Test func `a check that could not run is not counted against the finding`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.replicationCouldTest = false
        fake.replicationHoldsUp = false // exactly what "when in doubt, false" produces
        let ctx = try await context(container)
        let substrate = try #require(ctx.substrate)

        let outcome = await makeOrchestrator(container, fake).survivesReplication(
            "Your resting heart rate settled lower.", subject: "resting heart rate",
            metrics: [.restingHeartRate], substrate: substrate, ctx
        )

        #expect(outcome.rendered == 0, "an untestable check was tallied: \(outcome.rendered)")
        #expect(outcome.passed, "a claim was refuted by analysts that never tested it")
    }

    /// And a real refutation still counts. Without this the change would simply disable the panel.
    @Test func `a check that ran and failed still refutes`() async throws {
        let container = try TestSupport.inMemoryContainer()
        var fake = FakeSubagents()
        fake.replicationCouldTest = true
        fake.replicationHoldsUp = false
        let ctx = try await context(container)
        let substrate = try #require(ctx.substrate)

        let outcome = await makeOrchestrator(container, fake).survivesReplication(
            "Your resting heart rate settled lower.", subject: "resting heart rate",
            metrics: [.restingHeartRate], substrate: substrate, ctx
        )

        #expect(outcome.rendered > 0, "the panel never convened")
        #expect(!outcome.passed, "a genuine refutation stopped counting")
    }

    /// The analyst is told WHICH metric to re-test, by registry key.
    ///
    /// It never was. `subject` is a display name used only in a log line, and the claim an analyst
    /// receives is prose plus a basis sentence — neither carries a key. So it guessed from English:
    /// asked to re-test a resting-heart-rate step it queried "Heart rate", got nothing back, and
    /// reported that as a failure to replicate. Across three probes against the real model, not one
    /// analyst completed a re-test — on the panel whose entire job is checking findings against the
    /// data.
    @Test func `the analyst is given the claim's exact metric keys`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let recorder = SubagentCallRecorder()
        var fake = FakeSubagents()
        fake.calls = recorder
        let ctx = try await context(container)
        let substrate = try #require(ctx.substrate)

        _ = await makeOrchestrator(container, fake).survivesReplication(
            "Your resting heart rate settled lower.", subject: "resting heart rate",
            metrics: [.restingHeartRate, .stepCount], substrate: substrate, ctx
        )

        let asked = recorder.replicateLenses
        #expect(!asked.isEmpty, "the panel never convened")
        for lens in asked {
            #expect(
                lens.contains(MetricKey.restingHeartRate.rawValue)
                    && lens.contains(MetricKey.stepCount.rawValue),
                Comment(rawValue: "an analyst was not told the claim's keys: \(lens.suffix(120))")
            )
        }
    }

    /// The analyst is told what to do, or the flag is never set and the fix is inert.
    ///
    /// `couldTest` covers TWO ways a re-test comes back empty-handed, and the prompt has to name
    /// both or half the field is unreachable: the data was absent, or the check ran and bore on
    /// something else. The second was added after the panel first managed to complete re-tests at
    /// all — an analyst refuted a 30-day drop because weekday and weekend averages did not differ.
    ///
    /// Pinning prompt phrases is deliberate here. A reword should fail this and be looked at, which
    /// is what happened the one time it did: the sentence was rewritten, the word this test pinned
    /// vanished, and the meaning had genuinely changed.
    @Test func `the replicator is told to report an untestable check`() {
        #expect(Instructions.replicator.contains("couldTest false"))
        #expect(Instructions.replicator.contains("no samples"), "the data-absent case is unstated")
        #expect(
            Instructions.replicator.contains("bearing on this claim"),
            "the check-bore-on-nothing case is unstated"
        )
        // And the analyst is told what NOT to do with it, or "when in doubt, false" wins by default.
        #expect(Instructions.replicator.contains("neither for it nor against it"))
    }
}
