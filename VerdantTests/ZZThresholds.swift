import Foundation
import SwiftData
import Testing
@testable import Verdant

/// TEMPORARY. Per-panel hold COUNTS, so every candidate `panelHolds` threshold can be scored against
/// what the panels actually did. The binomial table in ARCHITECTURE assumes independent skeptics and
/// overestimates (it predicts 21% where the observed rate is ~6%); this needs no such assumption.
struct ZZThresholds {
    /// Two arms for the panels to score: resting heart rate steps 63 → 56 bpm at day 70 (a real
    /// regime shift), while body mass stays flat at 78 kg (nothing to find).
    private func seedArms(_ writer: StoreWriter, now: Date) async throws {
        try await TestSupport.seed(
            writer,
            metric: .restingHeartRate,
            value: 56,
            daysAgo: 1...70,
            jitter: 1,
            now: now
        )
        try await TestSupport.seed(
            writer,
            metric: .restingHeartRate,
            value: 63,
            daysAgo: 71...220,
            jitter: 1,
            now: now
        )
        try await TestSupport.seed(
            writer,
            metric: .bodyMass,
            value: 78,
            daysAgo: 1...220,
            jitter: 0.3,
            now: now
        )
    }

    @Test func probe() async throws {
        let now = Date()
        let container = try AppContainer.makeContainer(inMemory: true)
        let writer = StoreWriter(modelContainer: container)
        try await seedArms(writer, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        let substrate = try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
        let regimes = await substrate.regimes()
        guard let real = regimes.first(where: { $0.metric == .restingHeartRate }),
              let spurious = regimes.first(where: { $0.metric == .bodyMass })
        else { print("T| ABORT"); return }
        let subagents = try Subagents(provider: provider, writer: writer, embeddings: Embeddings())
        let orchestrator = Orchestrator(
            provider: provider, writer: writer, embeddings: Embeddings(),
            subagents: subagents, capability: { .available }
        )
        let ctx = DiscoveryContext(
            jobID: UUID(), now: now, deadline: nil, progress: nil, substrate: substrate, adversarial: true
        )
        let arms = [
            (
                "REAL",
                "Your resting heart rate settled at a lower level — it has averaged about 56 bpm "
                    + "since, against about 63 bpm before.\n\nVerified basis: \(real.verifiedBasis)"
            ),
            (
                "SPUR",
                "Your body mass settled at a new level — it has averaged about 78 kg since, "
                    + "against about 78 kg before.\n\nVerified basis: \(spurious.verifiedBasis)"
            )
        ]
        var observed: [String: [(held: Int, rendered: Int)]] = [:]
        for round in 0..<20 {
            let (label, claim) = arms[round % 2]
            let outcome = await orchestrator.survivesScrutiny(claim, subject: "the step", ctx)
            observed[label, default: []].append((outcome.held, outcome.rendered))
            print("T| \(label) panel: \(outcome.held)/\(outcome.rendered) held")
        }
        // Score every threshold against the ACTUAL panels — no distribution assumed.
        print("T| ==== threshold   REAL passes   SPURIOUS passes")
        for k in 2...6 {
            let real = observed["REAL"]?.count(where: { $0.held >= k }) ?? 0
            let spur = observed["SPUR"]?.count(where: { $0.held >= k }) ?? 0
            let realN = observed["REAL"]?.count ?? 0
            let spurN = observed["SPUR"]?.count ?? 0
            print("T|      >= \(k)          \(real)/\(realN)           \(spur)/\(spurN)")
        }
        // And the rule in force today, for reference.
        let realMaj = observed["REAL"]?.count(where: { $0.held * 2 > $0.rendered }) ?? 0
        let spurMaj = observed["SPUR"]?.count(where: { $0.held * 2 > $0.rendered }) ?? 0
        print("T|      majority     \(realMaj)/\(observed["REAL"]?.count ?? 0)           "
            + "\(spurMaj)/\(observed["SPUR"]?.count ?? 0)   (current rule)")
    }
}
