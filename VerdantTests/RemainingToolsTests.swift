import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The last two tools without direct coverage: `metricStats` and `metricsOverview`.
///
/// Both are served from the substrate's memoized cross-product rather than by re-querying, which is
/// what keeps a tool call from making the Neural Engine wait on the CPU. That design has a
/// consequence worth pinning: the answer must be the SAME number the rest of the session reasons
/// over, and an out-of-vocabulary key must report no confidence rather than a fabricated zero the
/// model might quote.
struct RemainingToolsTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    /// The pieces a tool test needs: the substrate it reads from, plus the provider and writer the
    /// overview's digest builder is constructed with.
    private struct Fixture {
        let substrate: AnalysisSubstrate
        let provider: MetricStatsProvider
        let writer: StoreWriter
    }

    private func seeded() async throws -> Fixture {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // A real move with real spread. This was a flat 9,000 for all 90 days, jitter-free — which
        // gives a baseline standard deviation of zero and therefore a `z` of exactly zero, so every
        // assertion about `z` passed by arithmetic rather than by the code working. The equality
        // check below (`digest.z == fromSubstrate.z`) sat at 0 == 0 and would have stayed green if
        // the field were never wired up at all.
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 11000, daysAgo: 1...7, jitter: 700, now: now
        )
        try await TestSupport.seed(
            writer, metric: .stepCount, value: 8500, daysAgo: 8...90, jitter: 700, now: now
        )
        try await TestSupport.seed(
            writer, metric: .restingHeartRate, value: 60, daysAgo: 1...90, jitter: 2, now: now
        )
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
        return Fixture(substrate: substrate, provider: provider, writer: writer)
    }

    /// The tool must answer with the substrate's own number, not a freshly computed one. A drifting
    /// second computation is how a session comes to hold two different values for one statistic —
    /// the tool says one thing and the finding's persisted figure says another.
    @Test func `metricStats serves the substrate's own number`() async throws {
        let substrate = try await seeded().substrate
        let tool = MetricStatsTool(substrate: substrate)

        let digest = try await tool.call(arguments: .init(
            metric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue
        ))
        let fromSubstrate = try #require(await substrate.allStats().first {
            $0.metric == .stepCount && $0.comparison == .recentVsBaseline
        })

        #expect(digest.confident, "the fixture should produce a confident stat")
        #expect(digest.recent == fromSubstrate.recent.toolRounded)
        #expect(digest.baseline == fromSubstrate.baseline.toolRounded)
        #expect(digest.dayCount == fromSubstrate.n)
        #expect(digest.z == fromSubstrate.z.toolRounded)
    }

    /// `z` is the only figure in the digest that compares ACROSS metrics — a 3% move in resting heart
    /// rate and a 3% move in step count read identically in `pctChange` and are not remotely the same
    /// event. The agent had no way to obtain it: it is not on the digest, and the model is forbidden
    /// from deriving it (it never sees the spread).
    ///
    /// Asserted separately from the field's presence because a field can be added, compiled, and
    /// returned as a constant zero — which is what "the agent can now see it" would still look like
    /// from the type. This pins a real, non-zero value that tracks the fixture.
    @Test func `metricStats reports the standardized move, not just the percentage`() async throws {
        let substrate = try await seeded().substrate
        let digest = try await MetricStatsTool(substrate: substrate).call(arguments: .init(
            metric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue
        ))
        #expect(digest.z != 0, "z came back as a placeholder zero")
        #expect(abs(digest.z) > 0.1, "the fixture's move should be measurable in SD: \(digest.z)")
        // Same direction as the percentage, or one of the two is being read off the wrong side.
        #expect((digest.z > 0) == (digest.pctChange > 0), "z and pctChange disagree on direction")
    }

    /// A metric with NO data comes back as absence-with-a-reason, not as zeros.
    ///
    /// This test has been wrong twice, and both errors are worth keeping. It first asserted that
    /// `confident: false` was enough, on the reasoning that "a confident zero would be quoted" — the
    /// zeros were quoted anyway, reaching a user as "0 beats per minute". It then asserted a THROW,
    /// which removed the number and killed the answering session 5 times out of 5. What the agents
    /// demonstrably read is a plain-language reason beside the numbers, which is how `analyze` has
    /// always reported absence.
    @Test func `a metric with no data reports absence rather than zeros`() async throws {
        let substrate = try await seeded().substrate
        let tool = MetricStatsTool(substrate: substrate)

        // `bodyMass` is absent from the fixture — and `allStats()` still manufactures rows for it,
        // which is why this case is the one that matters rather than an unreachable edge.
        let digest = try await tool.call(arguments: .init(
            metric: MetricKey.bodyMass.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue
        ))
        #expect(!digest.confident)
        #expect(digest.dayCount == 0)
        #expect(digest.note.contains("nothing was measured"), Comment(rawValue: "note: “\(digest.note)”"))
        // Says what the zeros are NOT, because that is the sentence the misreading needs.
        #expect(digest.note.contains("rather than a figure of zero"))
        #expect(digest.note.contains(MetricKey.bodyMass.displayName))
        // Sayable: an agent that quotes this field verbatim must not emit internal instructions.
        #expect(!digest.note.contains("do not"), Comment(rawValue: "note reads as an instruction"))
        #expect(digest.note == digest.note.replacingOccurrences(of: "ABSENCE", with: ""))
    }

    /// Non-vacuity: a metric that DOES have data must come back with an empty note, or the assertion
    /// above would pass on a tool that marked everything absent.
    @Test func `a metric with data carries no absence note`() async throws {
        let substrate = try await seeded().substrate
        let digest = try await MetricStatsTool(substrate: substrate).call(arguments: .init(
            metric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue
        ))
        #expect(digest.note.isEmpty, Comment(rawValue: "real figures were marked absent: “\(digest.note)”"))
        #expect(digest.dayCount > 0)
    }

    /// The overview is the agent's first read of the territory. It must actually describe the data —
    /// an empty or metric-less digest would send every investigator in blind, and nothing else in
    /// the session would report a problem.
    @Test func `metricsOverview describes the metrics that have data`() async throws {
        let fixture = try await seeded()
        let tool = MetricsOverviewTool(
            digestBuilder: HealthDigestBuilder(
                provider: fixture.provider, writer: fixture.writer
            ),
            substrate: fixture.substrate
        )

        let text = try await tool.call(arguments: .init(unused: false))
        #expect(!text.isEmpty, "the overview said nothing at all")
        #expect(
            text.contains(MetricKey.stepCount.displayName)
                || text.contains(MetricKey.restingHeartRate.displayName),
            "the overview named none of the seeded metrics: \(text.prefix(200))"
        )
    }

    /// And on an empty library it must still return something coherent rather than crashing or
    /// implying data exists — day one again, at the tool boundary.
    @Test func `metricsOverview on an empty library is coherent`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let provider = MetricStatsProvider(modelContainer: container)
        let writer = StoreWriter(modelContainer: container)
        let substrate = AnalysisSubstrate(provider: provider, series: [], now: now)
        let tool = MetricsOverviewTool(
            digestBuilder: HealthDigestBuilder(provider: provider, writer: writer),
            substrate: substrate
        )

        let text = try await tool.call(arguments: .init(unused: false))
        #expect(!text.contains("nan") && !text.contains("inf"), "\(text)")
    }
}

/// `allStats()` manufactures a row for every (metric, comparison) pair whether or not the metric has
/// data — five bodyMass rows on a fixture with no body mass, each `0/0/0/0`. Those rows are a
/// standing hazard: one of them reached a user on 2026-08-03 as "your body mass has remained stable
/// at 0 over the past year". `MetricStatsTool` now reports them as absence, and these pin the other
/// two consumers, which were already safe and must stay that way.
struct ManufacturedZeroContainmentTests {
    private struct OnlyHeartRate {
        let substrate: AnalysisSubstrate
        let provider: MetricStatsProvider
        let writer: StoreWriter
    }

    private func substrateWithOnlyHeartRate() async throws -> OnlyHeartRate {
        let now = Date()
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(writer, metric: .restingHeartRate, value: 56, daysAgo: 1...60, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
        return OnlyHeartRate(substrate: substrate, provider: provider, writer: writer)
    }

    /// Non-vacuity first: the hazard must actually exist, or everything below is theatre.
    @Test func `the substrate really does manufacture empty rows`() async throws {
        let empties = try await substrateWithOnlyHeartRate().substrate.allStats()
            .filter { $0.metric == .bodyMass }
        #expect(!empties.isEmpty, "no manufactured rows — this suite is guarding nothing")
        #expect(empties.allSatisfy { $0.recentCount == 0 && $0.baselineCount == 0 })
    }

    /// No FINDING can be built on one. This is the consequential path: a fact here becomes prose on
    /// the feed, and "your weight changed 0%" would be a fabricated finding rather than a bad answer.
    @Test func `an empty stat yields no verified fact`() async throws {
        let empties = try await substrateWithOnlyHeartRate().substrate.allStats()
            .filter { $0.metric == .bodyMass }
        for stat in empties {
            #expect(
                MaterialityRules.buildFact(stat: stat, requestedSalience: 90) == nil,
                Comment(rawValue: "a finding was built on an empty \(stat.comparison.rawValue) row")
            )
        }
    }

    /// And none reaches the overview the agents read to see what exists at all.
    @Test func `an empty stat never appears in the metrics overview`() async throws {
        let fx = try await substrateWithOnlyHeartRate()
        let text = await HealthDigestBuilder(provider: fx.provider, writer: fx.writer)
            .build(now: fx.substrate.now, stats: fx.substrate.allStats())
            .renderedText()
        #expect(!text.contains(MetricKey.bodyMass.displayName), Comment(rawValue: text))
        // Non-vacuity: the metric that DOES have data has to be in there.
        #expect(text.contains(MetricKey.restingHeartRate.displayName), Comment(rawValue: text))
    }
}
