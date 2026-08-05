import Foundation
import SwiftData

/// Agent run-state persistence, on the single `StoreWriter` actor so it stays serialized with the
/// finding writes it summarizes. The UI reads `AgentState` reactively via `@Query`; production only
/// ever *writes* it here, so there is no read method (a test-only reader lives in the test target).
extension StoreWriter {
    /// Update the singleton `AgentState` at the end of a discovery pass — fetch-or-create, then stamp
    /// the latest run. This is the agent keeping its own state current on every run.
    func recordRun(mode: AgentState.Mode, findingCount: Int, now: Date = .now) throws {
        let key = AgentState.singletonKey
        let descriptor = FetchDescriptor<AgentState>(predicate: #Predicate { $0.key == key })
        if let state = try modelContext.fetch(descriptor).first {
            state.lastRunAt = now
            state.lastRunMode = mode.rawValue
            state.lastRunFindingCount = findingCount
            state.totalRuns += 1
        } else {
            modelContext.insert(AgentState(
                lastRunAt: now, lastRunMode: mode.rawValue, lastRunFindingCount: findingCount, totalRuns: 1
            ))
        }
        try modelContext.save()
    }
}
