import Foundation

// MARK: - What an investigator must not re-propose

/// The ground already covered, gathered in one place instead of two.
///
/// This used to be assembled twice, in two files, and joined into the prompt at two different
/// points: `Orchestrator` appended "Retired this run…" and "Rejected this run…" and "Dead ends from
/// PRIOR runs…" onto the LENS STRING, while `Subagents.investigate` appended "Already surfaced
/// recently…" to the end of the prompt. Printing the assembled prompt showed what that produced —
/// the ban list ran into the middle of the task statement, doubled period and all:
///
///     Rejected this run — do NOT re-propose: … (could not be replicated).. Explore with at most
///     FOUR tool calls, then commit your findings — the context window is small.
///
/// So the sentence telling the investigator what to DO arrived as a continuation of a list of things
/// not to do. Measured separately, the steering is already weak (see the dated ARCHITECTURE entry:
/// an investigator told not to re-propose "Step Count and Resting Heart Rate Coherence" proposed
/// "Heart Rate Coherence" on the same pair). Burying the task statement inside the prohibition is
/// not the whole reason, but it is not helping, and it is free to fix.
///
/// Categories are kept rather than merged. "Already on the feed" and "we rejected this an hour ago"
/// mean different things to an agent deciding where to dig, and the labels cost a few characters
/// each out of a 4,096-token window.
nonisolated struct AvoidList {
    /// Standing findings the user can already see.
    var onFeed: [String] = []
    /// Hypotheses the panels killed during THIS run.
    var rejectedThisRun: [String] = []
    /// Leads a scout has already handed to investigators this run — the scout's own category, so
    /// scout 2 hunts new ground rather than re-surveying scout 1's.
    var handedToInvestigators: [String] = []
    /// Findings the audit tombstoned during this run — their own line because the novelty guards
    /// ignore tombstoned rows, so this steering is the only brake on re-surfacing one.
    var retiredThisRun: [String] = []
    /// Dead ends carried across runs by the persistent journal.
    var priorRunDeadEnds: [String] = []

    var isEmpty: Bool {
        onFeed.isEmpty && rejectedThisRun.isEmpty && retiredThisRun.isEmpty
            && priorRunDeadEnds.isEmpty && handedToInvestigators.isEmpty
    }

    /// One block, placed at the END of the prompt so it cannot swallow the task statement. Returns
    /// an empty string when there is nothing to avoid — a heading with no entries under it is worse
    /// than silence, because it invites the model to invent what belongs there.
    func rendered() -> String {
        let sections: [(String, [String])] = [
            ("already on the feed", onFeed),
            ("rejected this run", rejectedThisRun),
            ("already handed to investigators", handedToInvestigators),
            ("retired this run as no longer true", retiredThisRun),
            ("dead ends from earlier runs", priorRunDeadEnds)
        ]
        let lines = sections
            .filter { !$0.1.isEmpty }
            .map { "· \($0.0): \($0.1.joined(separator: "; "))" }
        guard !lines.isEmpty else { return "" }
        return "\n\nGround already covered — propose something else:\n" + lines.joined(separator: "\n")
    }
}
