import Foundation
import SwiftData
import Testing
@testable import Verdant

/// A run that spends its whole budget before vetting must SAY it dropped the findings.
///
/// Measured end to end against the real on-device model: twelve investigators proposed twenty
/// findings in 432 seconds against a 420-second deadline, and all twenty died at one guard in
/// `persistProposed` that returned `false` without a word. Not one panel convened — no skeptic, no
/// replication, no safety — so the most expensive reasoning the app does never ran, and the live
/// feed went from "Investigator 12 proposes 1: Body Mass and Sleep Duration Are Perfectly Synced"
/// straight to "Keeping only the few findings worth your attention…" and then showed nothing.
///
/// The path that passes a deadline is the BACKGROUND on-power run — the two foreground callers pass
/// none — which `AppModel` describes as "the pass that spends the whole on-power window running
/// agents". An entire charging window can therefore produce nothing and leave no record of why, on
/// the one path nobody is watching.
///
/// Every other rejection on this path is narrated with its reason, by `drop`, whose own doc says
/// why: "so a run that vets many and keeps few reads as the rigorous filter it is, not as 'the
/// analysis stopped'". A budget-exhausted drop reads as exactly the thing that doc is guarding
/// against, and it was the one drop that said nothing.
struct BudgetExhaustionTests {
    private func orchestrator(_ container: ModelContainer) -> Orchestrator {
        Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(), subagents: FakeSubagents(), capability: { .available }
        )
    }

    private func proposal() -> ProposedFinding {
        ProposedFinding(
            kind: InsightKind.trend.rawValue,
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Steps up",
            story: "Your steps rose noticeably.",
            worth: 80
        )
    }

    private func context(
        _ container: ModelContainer, deadline: ContinuousClock.Instant?, progress: ProgressReporter?
    ) async throws -> DiscoveryContext {
        let now = Date()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(writer, metric: .stepCount, value: 12000, daysAgo: 1...7, now: now)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 8...37, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
        return DiscoveryContext(
            jobID: UUID(), now: now, deadline: deadline, progress: progress,
            substrate: substrate, adversarial: true
        )
    }

    @Test func `a proposal dropped for time says so on the feed`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let sink = ProgressSink()
        // Already expired: the exact state a run is in when its investigators overran the window.
        let ctx = try await context(
            container, deadline: ContinuousClock().now.advanced(by: .seconds(-1)),
            progress: sink.reporter()
        )

        let persisted = await orchestrator(container).persistProposed(proposal(), lens: "a lens", ctx)

        #expect(!persisted, "a proposal was persisted after the budget was spent")
        let lines = sink.everyLine
        #expect(!lines.isEmpty, "the drop was silent — nothing was narrated at all")
        #expect(
            lines.contains { $0.contains("Steps up") && $0.contains("time ran out") },
            Comment(rawValue: "no line explains the drop: \(lines)")
        )
    }

    /// The run's CLOSING note has to see it too. Per-proposal lines scroll past in a live feed of
    /// eight; the closing note is what stays on screen, and with `produced == 0`, inference neither
    /// failed nor degraded, it read "Nothing new rose above the noise this pass — that's a clean
    /// bill, not an empty one" after dropping twenty findings unexamined.
    @Test func `the run counts what it dropped for time`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let sink = ProgressSink()
        let reporter = sink.reporter()
        let ctx = try await context(
            container, deadline: ContinuousClock().now.advanced(by: .seconds(-1)), progress: reporter
        )

        _ = await orchestrator(container).persistProposed(proposal(), lens: "a lens", ctx)
        _ = await orchestrator(container).persistProposed(proposal(), lens: "a lens", ctx)

        #expect(await reporter.droppedForTime == 2)
    }

    /// And nothing is counted when the run had time — otherwise the closing note claims a timeout on
    /// a pass that finished cleanly.
    @Test func `a run with budget counts no time drops`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let reporter = ProgressSink().reporter()
        let ctx = try await context(
            container, deadline: ContinuousClock().now.advanced(by: .seconds(600)), progress: reporter
        )

        _ = await orchestrator(container).persistProposed(proposal(), lens: "a lens", ctx)

        #expect(await reporter.droppedForTime == 0)
    }

    /// And it must not fire when there IS budget — a line claiming the run ran out of time on a run
    /// that did not is the same defect pointed the other way.
    @Test func `a proposal with budget left is not reported as out of time`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let sink = ProgressSink()
        let ctx = try await context(
            container, deadline: ContinuousClock().now.advanced(by: .seconds(600)),
            progress: sink.reporter()
        )

        _ = await orchestrator(container).persistProposed(proposal(), lens: "a lens", ctx)

        #expect(
            !sink.everyLine.contains { $0.contains("time ran out") },
            Comment(rawValue: "claimed a timeout with ten minutes left: \(sink.everyLine)")
        )
        // Non-vacuity: the run really did get past the guard and do its work, so the absence of the
        // timeout line means something. Without this the test would pass on a run that never started.
        #expect(
            sink.everyLine.contains { $0.contains("Investigating") },
            Comment(rawValue: "the proposal never reached the persist path: \(sink.everyLine)")
        )
    }

    /// A run with no deadline at all — both foreground callers — must behave like the budgeted one
    /// with time remaining, not accidentally read as "expired".
    @Test func `an unbounded run is never out of time`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let sink = ProgressSink()
        let ctx = try await context(container, deadline: nil, progress: sink.reporter())

        _ = await orchestrator(container).persistProposed(proposal(), lens: "a lens", ctx)

        #expect(!sink.everyLine.contains { $0.contains("time ran out") })
        #expect(sink.everyLine.contains { $0.contains("Investigating") })
    }
}
