import Foundation
import SwiftData
import Testing
@testable import Verdant

/// A detector is only half a finding. Adding `patternScan seasonal` gave the fleet something new to
/// SEE, but the pipeline that carries a finding from proposal to card is a chain of five separate
/// correspondences — an `InsightKind`, a persist route that resolves numbers from the right scan, a
/// sentinel `comparison` so novelty doesn't collide with unrelated findings, card copy, and a chart
/// span. Every one of those was written for volatility/milestone/regimeShift by hand, and a fourth
/// kind silently inherits `default` on all of them.
///
/// That default is not neutral: it is the ANOMALY treatment. Before this suite, an annual rhythm
/// would have been persisted with recent-vs-baseline numbers, titled "Insight", explained as "a
/// change that stood out from its usual day-to-day range", and charted over 30 days — every one of
/// them false for a claim about January.
struct SeasonalFindingTests {
    /// The correspondence itself. Each pattern kind the investigator may propose must have an
    /// `InsightKind` to be proposed AS — otherwise the agent shoehorns it into `trend` and the
    /// resolved numbers describe a different question than the prose does.
    @Test func `every pattern kind can be proposed as a finding kind`() {
        for kind in PatternKind.allCases {
            let name = kind == .regime ? "regimeShift" : kind.rawValue
            #expect(
                InsightKind.investigatorFacingRawValues.contains(name),
                "patternScan emits “\(kind.rawValue)” but no investigator-facing InsightKind carries it"
            )
        }
    }

    /// Its own sentinel comparison, for the same reason volatility has one: "runs high every January"
    /// and "the level moved recently" are different questions about the same metric, and neither may
    /// suppress the other through the novelty guard.
    @Test func `a seasonal finding does not collide with a trend on the same metric`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()
        let swing = Self.swing()

        let first = try await writer.appendSeasonalIfNovel(
            swing, phrasing: .init(summary: "January runs high.", oneTapTitle: "A winter rhythm"),
            quality: 70, jobRunID: UUID(), now: now
        )
        #expect(first != nil)

        // The same rhythm again is NOT novel.
        let repeated = try await writer.appendSeasonalIfNovel(
            swing, phrasing: .init(summary: "January runs high.", oneTapTitle: "A winter rhythm"),
            quality: 70, jobRunID: UUID(), now: now
        )
        #expect(repeated == nil, "the same annual rhythm was surfaced twice")

        // A volatility finding on the SAME metric is a different question and must still land.
        let volatility = try await writer.appendVolatilityIfNovel(
            VolatilityShift(
                metric: swing.metric, recentSD: 4, baselineSD: 2, recentMean: 60, baselineMean: 60,
                cvRatio: 2, seZ: 3, n: 30
            ),
            phrasing: .init(summary: "Swing widened.", oneTapTitle: "More erratic"),
            quality: 70, jobRunID: UUID(), now: now
        )
        #expect(volatility != nil, "a seasonal finding suppressed an unrelated volatility finding")
    }

    /// The stored row must carry the numbers the CLAIM is about. Getting this wrong is not a crash —
    /// it is a card showing a real number that answers a different question.
    @Test func `the stored row carries the rhythm's own numbers`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let swing = Self.swing()
        _ = try await writer.appendSeasonalIfNovel(
            swing, phrasing: .init(summary: "January runs high.", oneTapTitle: "A winter rhythm"),
            quality: 70, jobRunID: UUID()
        )
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<InsightLog>())
        let row = try #require(rows.first)
        #expect(row.insightKind == .seasonal)
        #expect(row.comparison == StoreWriter.seasonalComparison)
        #expect(row.verifiedRecent == swing.peakEffect)
        #expect(row.verifiedBaseline == swing.oppositeEffect)
        // The swing in the metric's OWN units — the figure the card shows, and the only one a person
        // can judge. An SD score rendered as "bpm" would be meaningless.
        #expect(row.verifiedPctChange == swing.swingInUnits)
        #expect(row.sampleCount == swing.yearsObserved)
    }

    /// Three years of a metric with a real January/July swing, as stored rollups — so a run builds
    /// its substrate from the provider exactly as production does.
    private func seedSeasonalHistory(_ writer: StoreWriter, now: Date) async throws {
        let calendar = Calendar.civil
        let anchor = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        )
        var rollups: [DayRollup] = []
        // One metric, and just over two years — the smallest history that still lets all four
        // detectors fire (seasonality needs two Januaries; milestone needs 120 days and 60 rolling
        // windows). A second metric only adds correlation pairs this suite never asserts on, and
        // this fixture is rebuilt once per kind, so the saving is fourfold.
        for metric in [MetricKey.restingHeartRate] {
            for ago in 0..<790 {
                let day = try #require(calendar.date(byAdding: .day, value: -ago, to: anchor))
                let month = calendar.component(.month, from: day)
                let seasonal = month == 1 ? 9.0 : (month == 7 ? -9.0 : 0)
                // A recent stretch above anything in the history, so `milestone` has a record to
                // find too. EXACTLY the last seven days, not eight: the rolling windows overlap, so
                // an eight-day boost makes the final window tie the one before it and `latest.mean >
                // maxPrior` is false — a record that is not strictly a record. Seven days out of
                // 1,100 does not disturb the yearly rhythm. The generalised surfacing test is what
                // proved the fixture needed any of this: a repeating pattern never sets a record.
                let record = ago < 7 ? 26.0 : 0
                let value = 60 + seasonal + record + Double(ago % 3) - 1
                rollups.append(DayRollup(
                    metric: metric, dayStart: day,
                    values: DayValues(mean: value, sum: value, count: 1)
                ))
            }
        }
        try await writer.applyRollups(upserts: rollups, deletions: [])
    }

    /// Does `patternScan` actually SURFACE every kind it declares?
    ///
    /// The detectors run, the substrate memoizes them, `PatternKind` has the cases, and the cap tests
    /// iterate every kind — but a kind with ZERO rows satisfies a cap trivially. Delete any
    /// detector's block from the tool's reply and nothing else here fails: it would be computed on
    /// every substrate build and no agent would ever see it. That was true of all four, not just the
    /// one added most recently.
    @Test func `patternScan surfaces every kind it declares`() async throws {
        let substrate = try await allKindsSubstrate()
        let patterns = try await PatternScanTool(substrate: substrate)
            .call(arguments: .init(perKind: 3)).patterns
        let surfaced = Set(patterns.map(\.kind))
        for kind in PatternKind.allCases {
            #expect(surfaced.contains(kind.rawValue), "no \(kind.rawValue) row reached the agent")
        }
    }

    /// And does a proposal of each kind reach ITS OWN persist route?
    ///
    /// The router is exhaustive, so every case must exist — but a case can point at the wrong
    /// function. Routing any kind to `persistTrendProposal` compiles, passes the vocabulary checks,
    /// and stores the finding with recent-vs-baseline numbers under a claim about something else:
    /// exactly the defect the exhaustive switch was introduced to prevent, reachable straight
    /// through it. Nothing asserted this for ANY kind.
    @Test func `a proposal of each pattern kind is stored as that kind`() async throws {
        let now = try #require(Calendar.civil.date(from: DateComponents(
            year: 2026, month: 7, day: 17, hour: 12
        )))
        for kind in PatternKind.allCases {
            let container = try TestSupport.inMemoryContainer()
            let writer = StoreWriter(modelContainer: container)
            try await seedSeasonalHistory(writer, now: now)
            let provider = MetricStatsProvider(modelContainer: container)
            let substrate = try await AnalysisSubstrate(
                provider: provider, series: provider.dailySeries(now: now), now: now
            )
            // Ask the detector itself which metric it fired on, so the proposal names something the
            // persist route can actually resolve — rather than guessing from the fixture's shape.
            guard let metric = await Self.firedMetric(kind, substrate) else {
                Issue.record("\(kind.rawValue) fired on no metric — fixture too thin to test it")
                continue
            }
            let expected =
                try #require(InsightKind(rawValue: kind == .regime ? "regimeShift" : kind.rawValue))
            let fake = FakeSubagents(proposals: [ProposedFinding(
                kind: expected.rawValue,
                metric: metric.rawValue,
                secondaryMetric: metric.rawValue,
                comparison: ComparisonKey.recentVsBaseline.rawValue,
                title: "A \(kind.rawValue) finding",
                story: "Something about \(metric.displayName).",
                worth: 85
            )])
            let orchestrator = Orchestrator(
                provider: provider, writer: writer, embeddings: Embeddings(),
                subagents: fake, capability: { .available }
            )

            await orchestrator.runDiscovery(now: now)

            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<InsightLog>()).filter { !$0.tombstoned }
            let row = try #require(rows.first, "\(kind.rawValue) proposal was not persisted at all")
            #expect(
                row.insightKind == expected,
                "\(kind.rawValue) stored as \(row.insightKind?.rawValue ?? "nil")"
            )
        }
    }

    /// The metric a given detector actually fired on for this substrate, or `nil`.
    private static func firedMetric(_ kind: PatternKind, _ s: AnalysisSubstrate) async -> MetricKey? {
        switch kind {
        case .volatility: await s.volatility().first?.metric
        case .milestone: await s.milestones().first?.metric
        case .regime: await s.regimes().first?.metric
        case .seasonal: await s.seasonality().first?.metric
        }
    }

    /// A substrate shaped so all four detectors have something to report: a yearly swing, a sustained
    /// step, a recent change in spread, and a record stretch.
    private func allKindsSubstrate() async throws -> AnalysisSubstrate {
        let now = try #require(Calendar.civil.date(from: DateComponents(
            year: 2026, month: 7, day: 17, hour: 12
        )))
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await seedSeasonalHistory(writer, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        return try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
    }

    private static func swing() -> SeasonalSwing {
        SeasonalSwing(
            metric: .restingHeartRate,
            swingInUnits: 3.5,
            peakMonth: 1,
            peakEffect: 1.2,
            oppositeMonth: 7,
            oppositeEffect: -1.1,
            monthsCompared: 12,
            yearsObserved: 3,
            yearsAgreeing: 3
        )
    }
}
