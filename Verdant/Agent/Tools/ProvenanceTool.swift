import Foundation
import FoundationModels

/// One day a metric changed hands, in the slim form an investigator reads. `daysAgo` plugs straight
/// into `analyze` windows and `eventWindow`, so an agent can measure the level either side of the
/// change it just learned about.
@Generable nonisolated struct ProvenanceRow {
    @Guide(description: "Metric key") let metric: String
    @Guide(description: "How many days ago the new recording setup started") let daysAgo: Int
    @Guide(description: "What recorded it before") let before: String
    @Guide(description: "What has recorded it since") let after: String
    @Guide(description: "Consecutive days on the old setup") let daysBefore: Int
    @Guide(description: "Consecutive days on the new setup") let daysAfter: Int
}

@Generable nonisolated struct ProvenanceResult {
    @Guide(description: "Best-established changes first — longest run of data either side")
    let changes: [ProvenanceRow]
    @Guide(description: "Further changes not shown, mostly brief ones")
    let withheld: Int
}

/// A **logical tool** answering the one question the numbers cannot: did the way this metric is
/// RECORDED change?
///
/// Every other tool describes the data. This one describes where the data came from, and it exists
/// because two completely different stories produce identical numbers. Buying an Apple Watch shifts
/// resting heart rate a few bpm and holds it there. A new scale reads two pounds heavy forever. A
/// phone upgrade changes which device counts the steps taken with it on a desk. Each is a genuine,
/// sustained, statistically unimpeachable level shift, `patternScan` reports it as a regime change
/// correctly, and each is about equipment rather than the person. An investigator with no access to
/// provenance cannot even pose the alternative — so it writes the only story it has, and tells the
/// user their body changed.
///
/// It reports facts and takes no view: transitions, with how long each setup ran either side. Deciding
/// whether a device change explains a finding, partly explains it, or is a coincidence sitting on top
/// of something real is the investigating agent's judgment — and "coincidence sitting on top of
/// something real" is exactly the case an automatic rule would throw away. 100% local.
nonisolated struct ProvenanceTool: Tool {
    let name = "provenance"
    let description = "Reports when a metric started being recorded by a different device or app — "
        + "a watch or scale swap, a new phone. A level shift on the same day the source changed may "
        + "be the equipment, not the person. Give a metric key to ask about one, or omit it to see "
        + "every change. Returns real, already-computed facts."

    static let maxChanges = 8

    @Generable nonisolated struct Arguments {
        @Guide(description: "Metric key to ask about, or empty for all metrics")
        let metric: String
        @Guide(
            description: "Max changes to return (1-\(ProvenanceTool.maxChanges))",
            .range(1...ProvenanceTool.maxChanges)
        )
        let limit: Int
    }

    let substrate: AnalysisSubstrate

    func call(arguments: Arguments) async throws -> ProvenanceResult {
        let all = await substrate.provenance()
        let wanted = MetricKey(rawValue: arguments.metric.trimmingCharacters(in: .whitespaces))
        // An unrecognised metric string falls through to "all" rather than returning nothing: a
        // silent empty result reads to the agent as "this metric never changed hands", which is a
        // stronger claim than the truth and points it away from the very evidence it asked for.
        let matching = wanted.map { key in all.filter { $0.metric == key } } ?? all
        // Ordered by how much data sits either side, which is a property of the record rather than a
        // judgment about importance. A swap with a year on both sides outranks a watch left on the
        // charger for one night — and the agent still sees the run lengths and decides for itself.
        let ranked = matching.sorted {
            ($0.establishedDays, $0.daysAfter) > ($1.establishedDays, $1.daysAfter)
        }
        let limit = max(1, min(Self.maxChanges, arguments.limit))
        let anchor = Calendar.civil.startOfDay(for: substrate.now)
        let rows = ranked.prefix(limit).map { change in
            ProvenanceRow(
                metric: change.metric.rawValue,
                daysAgo: Calendar.civil.dateComponents([.day], from: change.day, to: anchor).day ?? 0,
                before: SourceSignature.describe(change.before),
                after: SourceSignature.describe(change.after),
                daysBefore: change.daysBefore,
                daysAfter: change.daysAfter
            )
        }
        return ProvenanceResult(changes: Array(rows), withheld: max(0, ranked.count - rows.count))
    }
}
