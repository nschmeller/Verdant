import Foundation
import SwiftData

/// The discovery agent's own persisted **run state**, updated at the end of every pass that actually
/// REASONED.
///
/// Not every pass. A run where the model reported available and then every subagent call errored
/// (rate limit, contention) deliberately does not stamp this, because "last analyzed" is what the UI
/// shows to say how current the findings are, and a pass that reasoned about nothing has not analyzed
/// anything — `Orchestrator.runDiscovery` guards the write on `inferenceWhollyFailed`, and
/// `OrchestratorTests` pins it. So this row can be older than the last time the app ran, and that is
/// correct rather than a bug to chase. A singleton (exactly one row, keyed `current`) — distinct from the
/// agent's
/// *output* (`InsightLog`/`CorrelationLog`): this records that the agent ran, when, in what mode, and
/// to what effect. The app reads it to show how current the findings are, and it's the foundation for
/// any future cross-run reasoning (e.g. "you haven't run a deep analysis in a while").
@Model
final class AgentState {
    /// Singleton key; there is exactly one row (`current`).
    @Attribute(.unique) var key: String
    /// When the agent last completed a discovery pass.
    var lastRunAt: Date
    /// The kind of the last pass (`AgentState.Mode` raw value: "deep" or "standard").
    var lastRunMode: String
    /// How many findings that pass surfaced.
    var lastRunFindingCount: Int
    /// Total completed passes over the app's lifetime.
    var totalRuns: Int

    init(
        key: String = AgentState.singletonKey,
        lastRunAt: Date,
        lastRunMode: String,
        lastRunFindingCount: Int,
        totalRuns: Int
    ) {
        self.key = key
        self.lastRunAt = lastRunAt
        self.lastRunMode = lastRunMode
        self.lastRunFindingCount = lastRunFindingCount
        self.totalRuns = totalRuns
    }

    static let singletonKey = "current"

    /// How a pass ran. Only real reasoning passes are recorded (the no-LLM background refresh does no
    /// analysis and never updates the agent's state), so there are exactly two: the exhaustive Deep
    /// Analysis and the everyday bounded pass.
    enum Mode: String {
        case deep, standard
    }
}
