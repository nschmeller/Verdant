import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What the research director knows about the ground it is choosing to explore.
///
/// The director picks each pass's strategy: breadth, drill into what the run already has, or
/// FRONTIER — push into unvisited ground. It was told the pass yield, the dry streak, the feed's
/// titles, what this run rejected and what prior runs ruled out. Nothing about the data. The shape of
/// the territory reached the SCOUTS, through `coverage`, and the scouts run after the strategy is
/// already chosen — so the one agent whose job is deciding where to look could not name a single
/// unexplored metric, and "frontier" carried little more meaning than "try harder".
struct DirectorTerritoryTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    private func substrate(_ metrics: [MetricKey]) async throws -> AnalysisSubstrate {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        for metric in metrics {
            try await TestSupport.seed(
                writer, metric: metric, value: 60, daysAgo: 1...60, jitter: 3, now: now
            )
        }
        let provider = MetricStatsProvider(modelContainer: container)
        return try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
    }

    private func context(_ substrate: AnalysisSubstrate) -> DiscoveryContext {
        DiscoveryContext(
            jobID: UUID(), now: now, deadline: nil, progress: nil,
            substrate: substrate, adversarial: true
        )
    }

    private func focus(_ metric: MetricKey, _ secondary: MetricKey? = nil) -> InvestigationFocus {
        InvestigationFocus(metric: metric, secondaryMetric: secondary, title: "A finding")
    }

    @Test func `metrics with history and nothing on the feed are named`() async throws {
        let built = try await substrate([.stepCount, .restingHeartRate, .bodyMass])
        let line = try #require(
            await Orchestrator.untouchedMetricsLine(context(built), feed: [focus(.stepCount)]),
            "the director was told nothing about the unexplored metrics"
        )
        #expect(line.contains(MetricKey.restingHeartRate.displayName))
        #expect(line.contains(MetricKey.bodyMass.displayName))
        #expect(!line.contains(MetricKey.stepCount.displayName), "a covered metric was listed")
    }

    /// A correlation's SECOND metric counts as covered too. Missing it would send the fleet at a
    /// metric that is half of a finding already on the feed — the opposite of frontier.
    @Test func `the second metric of a pair counts as covered`() async throws {
        let built = try await substrate([.stepCount, .restingHeartRate])
        let line = await Orchestrator.untouchedMetricsLine(
            context(built), feed: [focus(.stepCount, .restingHeartRate)]
        )
        #expect(line == nil, "reported \(line ?? "") when the feed covers both metrics")
    }

    /// Nothing to say is said as nothing — an empty list would spend tokens telling the director the
    /// frontier is closed in words it has to read to discover are empty.
    @Test func `a fully covered feed produces no line`() async throws {
        let built = try await substrate([.stepCount])
        #expect(await Orchestrator.untouchedMetricsLine(context(built), feed: [focus(.stepCount)]) == nil)
    }

    /// And it stays bounded: the director's state rides in a prompt, and a user with thirty
    /// unexplored metrics must not push the rest of the state out of the window.
    @Test func `the list is capped and says how many it left out`() async throws {
        let metrics: [MetricKey] = [
            .stepCount, .restingHeartRate, .bodyMass, .vo2Max, .respiratoryRate,
            .heartRateVariabilitySDNN, .walkingHeartRateAverage
        ]
        let built = try await substrate(metrics)
        let line = try #require(await Orchestrator.untouchedMetricsLine(context(built), feed: []))
        let named = metrics.count { line.contains($0.displayName) }
        #expect(named == Orchestrator.maxUntouchedNamed, "named \(named) metrics")
        #expect(line.contains("and \(metrics.count - Orchestrator.maxUntouchedNamed) more"))
    }

    /// The wiring: `directorState` is private, so this proves the line reaches the prompt through the
    /// only path that matters — a helper nothing calls is the failure mode these tests exist for.
    @Test func `the untouched line is part of what the director is sent`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator+DeepRun.swift" }
        )
        let code = SourceScan.code(source.text)
        #expect(
            code.contains("untouchedMetricsLine(ctx, feed: feed)"),
            "directorState no longer includes the territory line"
        )
    }
}
