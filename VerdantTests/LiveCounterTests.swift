import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The three counters on the live card, and the two that were never written to.
///
/// `newInsights` was maintained. `correlationsSurfaced` and `correlationsTested` were declared on
/// `AnalysisProgress`, rendered on every run, and incremented by nothing anywhere in the app — so the
/// card told a person that zero relationships had been tested while `CorrelationEngine` was judging
/// every computable pair in their history, and that zero cross-signal links had been surfaced while
/// the app's premium finding is exactly that.
///
/// A plausible zero is the hardest wrong number to notice: early in a run it is correct, and it never
/// stops being displayed. It was found by looking at a screenshot of the app running, not by reading
/// the code, and the compiler had nothing to say — an unwritten `var` with a default is valid Swift.
struct LiveCounterTests {
    /// The mechanical version of the screenshot that found the two dead counters.
    ///
    /// Every number the live card shows is a stored `var` on `AnalysisProgress`, and an unwritten one
    /// is valid Swift that renders a plausible zero forever. This asserts each has a writer somewhere
    /// in the app, so the next counter added cannot be displayed and never filled — which is how both
    /// `correlationsTested` and `correlationsSurfaced` shipped.
    @Test func `every counter the live card shows is written by something`() throws {
        let sources = try SourceScan.swiftSources()
        let model = try #require(sources.first { $0.path == "AnalysisProgress.swift" })
        let app = sources.filter { $0.path != "AnalysisProgress.swift" }
            .map { SourceScan.code($0.text) }.joined(separator: "\n")

        // Stored counters only: computed properties have no writer by definition.
        let counters = SourceScan.code(model.text)
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("var "), trimmed.contains("= 0") else { return nil }
                return String(trimmed.dropFirst(4).prefix { $0.isLetter || $0.isNumber })
            }
        #expect(counters.count >= 5, "found only \(counters.count) counters — did the scan break?")

        // Both write forms the app uses: inside `progress.apply { $0.x = }` and directly on the
        // reporter's own `progress.x =`. Narrowing to the first flagged `elapsedSeconds`, which is
        // written the second way — a pattern too tight reports correct code, which is how a sweep
        // stops being trusted.
        for counter in counters {
            let written = [
                "$0.\(counter) =",
                "$0.\(counter) +=",
                "progress.\(counter) =",
                "progress.\(counter) +="
            ]
            guard !written.contains(where: app.contains) else { continue }
            Issue.record(Comment(rawValue: "\(counter) is displayed but nothing ever writes it"))
        }
    }

    private var now: Date {
        Calendar.civil.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// The pairs-tested chip reports what the engine actually judged.
    @Test func `relationships tested reports the engine's own pair count`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        for metric in [MetricKey.stepCount, .restingHeartRate, .bodyMass] {
            try await TestSupport.seed(
                writer, metric: metric, value: 60, daysAgo: 1...80, jitter: 4, now: now
            )
        }
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
        let sink = ProgressSink()
        let reporter = sink.reporter()

        Orchestrator.reportPairsTested(substrate, to: reporter)
        // The scan is awaited off the run's critical path, so wait for the value the same way the UI
        // does — by observing it arrive.
        let expected = await substrate.correlationScan().pairsTested
        #expect(expected > 0, "the fixture produced no testable pairs — the assertion below is empty")
        var seen = 0
        for _ in 0..<50 where seen == 0 {
            try await Task.sleep(for: .milliseconds(20))
            seen = sink.last?.correlationsTested ?? 0
        }
        #expect(seen == expected, "reported \(seen) of \(expected) pairs")
    }

    /// And it stays at zero rather than guessing before the scan has finished.
    @Test func `the count is not invented before the scan produces one`() {
        let sink = ProgressSink()
        #expect((sink.last?.correlationsTested ?? 0) == 0)
    }

    /// The surfaced-links chip counts a correlation that was actually kept.
    @Test func `a persisted correlation increments the cross-signal counter`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(
            writer,
            metric: .stepCount,
            value: 8000,
            daysAgo: 1...90,
            jitter: 900,
            now: now
        )
        try await TestSupport.seed(
            writer, metric: .restingHeartRate, value: 60, daysAgo: 1...90, jitter: 4, now: now
        )
        let sink = ProgressSink()
        let fake = FakeSubagents(proposals: [ProposedFinding(
            kind: InsightKind.correlation.rawValue,
            metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.restingHeartRate.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "A link", story: "Steps and resting heart rate move together.", worth: 80
        )])
        let orchestrator = Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: writer, embeddings: Embeddings(), subagents: fake, capability: { .available }
        )

        await orchestrator.runDiscovery(now: now, progress: sink.reporter())

        // The WIRING, not just the helper. Removing the call from `runDiscovery` left the direct
        // test above green — it exercises `reportPairsTested` itself, which is exactly the
        // "defaulted argument, hand-supplied test" shape that has produced dead features here.
        var tested = 0
        for _ in 0..<50 where tested == 0 {
            try await Task.sleep(for: .milliseconds(20))
            tested = sink.last?.correlationsTested ?? 0
        }
        #expect(tested > 0, "the run never reported how many pairs it tested")

        let context = ModelContext(container)
        let kept = try context.fetch(FetchDescriptor<CorrelationLog>()).count
        // Only meaningful if the fixture actually produced a correlation to count.
        try #require(kept > 0, "no correlation was persisted — the counter has nothing to report")
        #expect(
            sink.last?.correlationsSurfaced == kept,
            "counted \(sink.last?.correlationsSurfaced ?? -1) of \(kept)"
        )
    }
}
