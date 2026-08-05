import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Telling the fleet what data the person actually has.
///
/// The thematic lenses are a fixed roster — "respiration, blood oxygen and wrist temperature", "body
/// & metabolic measures" — so on a thin library they aim investigators at metrics that do not exist.
/// Observed by running the REAL on-device model over a store holding two metrics: the fleet proposed
/// Weekend Temperature Spikes, Oxygen Variability and a body-fat finding, and every one was dropped
/// at persist time because the numbers could not be resolved from source.
///
/// The boundary worked. The sessions were spent on findings that could not survive — and that is not
/// an exotic case, it is the first weeks of every install and an iPhone-only user permanently.
struct AvailableMetricsSteeringTests {
    private var now: Date {
        Calendar.civil.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
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

    @Test func `a thin library is named to the investigator`() async throws {
        let built = try await substrate([.stepCount, .restingHeartRate])
        let line = try #require(
            Orchestrator.availableMetricsLine(built), "a two-metric library said nothing"
        )
        #expect(line.contains(MetricKey.stepCount.rawValue))
        #expect(line.contains(MetricKey.restingHeartRate.rawValue))
        // Raw keys, not display names: the investigator has to name these back through the registry.
        #expect(!line.contains(MetricKey.stepCount.displayName))
    }

    /// Silent once the library is rich — naming most of the registry back to an agent that can see it
    /// in any tool result is a token cost, not information.
    @Test func `a rich library says nothing`() async throws {
        let many = Array(MetricKey.allCases.prefix(Orchestrator.maxNamedAvailableMetrics + 3))
        let built = try await substrate(many)
        #expect(Orchestrator.availableMetricsLine(built) == nil)
    }

    /// And an empty library says nothing either: there is no shortlist to give, and the run already
    /// reports having no history to work from.
    @Test func `an empty library says nothing`() async throws {
        #expect(try await Orchestrator.availableMetricsLine(substrate([])) == nil)
    }

    /// The replication analyst gets it too.
    ///
    /// Observed against the real model: asked to re-test a resting-heart-rate step, an analyst
    /// queried "Heart rate" — a real registry key with no data in that library — and returned "No
    /// data for Heart rate." as its verdict. The panel scored 0 of 5 and rejected a claim whose own
    /// basis had just stated the numbers. The steering added for investigators did not reach the
    /// panel that re-tests their work.
    @Test func `the shortlist reaches the replication analysts`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator+Replication.swift" }
        )
        let code = SourceScan.code(source.text)
        #expect(code.contains("Orchestrator.availableMetricsLine(substrate)"))
        #expect(
            code.contains("lens: steered"),
            "the shortlist never reaches the analyst's own re-test"
        )
    }

    /// And its wording works for both roles — the analyst re-tests, it does not propose.
    @Test func `the shortlist reads correctly for a role that does not propose`() async throws {
        let line = try #require(await Orchestrator.availableMetricsLine(substrate([.stepCount])))
        #expect(!line.contains("propose"), Comment(rawValue: line))
        #expect(line.contains("no data to work with"))
    }

    /// The wiring: it must reach the investigator's own prompt, not just exist.
    @Test func `the shortlist is steered into the investigator prompt`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator.swift" }
        )
        let code = SourceScan.code(source.text)
        #expect(code.contains("let available = Self.availableMetricsLine(substrate)"))
        #expect(
            code.contains("if let available { angle += "),
            "the shortlist never reaches the lens the investigator is given"
        )
    }
}
