import Foundation

// MARK: - Runtime steering for the investigator fleet

/// Facts about the person's own library that ride on the LENS rather than the instructions.
///
/// Split out when `Orchestrator` hit the 500-line limit, and the seam is a real one: everything here
/// is per-run context appended to an investigator's focus line, which costs nothing in the prefix —
/// the budget with twelve tokens spare — and so is where new steering belongs.
nonisolated extension Orchestrator {
    /// The metrics this person actually has data for, named for the investigator — or `nil` when
    /// saying so would not help.
    ///
    /// The thematic lenses are a fixed roster ("respiration, blood oxygen and wrist temperature";
    /// "body & metabolic measures"), so on a thin library they point the fleet at metrics that do not
    /// exist. Observed by running the real model over a store holding two metrics: investigators
    /// proposed Weekend Temperature Spikes, Oxygen Variability and a body-fat finding, and every one
    /// was dropped at persist time because the numbers could not be resolved from source. The
    /// boundary worked; the sessions were spent on findings that could not survive.
    ///
    /// That is not the rare case — it is the FIRST WEEKS of every install, and an iPhone-only user
    /// permanently. This costs no prefix tokens (it rides on the runtime lens, not the instructions,
    /// which have twelve tokens spare) and removes no model calls: the same fleet runs, aimed at
    /// ground that exists.
    ///
    /// Silent once the library is rich, because then it is not information. Naming thirty metrics
    /// tells an investigator nothing it cannot see and spends the window saying so.
    static func availableMetricsLine(_ substrate: AnalysisSubstrate) -> String? {
        let metrics = substrate.metricsWithData()
        guard !metrics.isEmpty, metrics.count <= maxNamedAvailableMetrics else { return nil }
        // Role-neutral wording: this same line now steers investigators (who propose) and replication
        // analysts (who re-test), and "do not propose" read as an instruction the analyst could not
        // follow.
        return "This person has usable data for ONLY these metrics: "
            + metrics.map(\.rawValue).joined(separator: ", ")
            + ". Any other metric has no data to work with."
    }

    /// Above this many, the list stops being informative and starts being a token cost: it would name
    /// most of the registry back to an agent that can already see them in any tool result.
    static let maxNamedAvailableMetrics = 12
}
