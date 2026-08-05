import Foundation

// MARK: - How a finding is RANKED, as opposed to whether it is kept

nonisolated extension Orchestrator {
    /// The feed's ranking blend, in one place instead of five copies of the same expression.
    ///
    /// `worth` is the agent's, 0-100. `strength` is an engine number pre-scaled to 0-100 by a
    /// per-kind multiplier at the call site. The weights say how much of a finding's prominence the
    /// agent decides: 0.6 for four kinds, 0.55 for correlation.
    ///
    /// This is a deterministic decision about what the user sees FIRST — it orders the feed, picks
    /// which findings the audit re-examines, and reaches the curator as a plain `q85`, which is the
    /// one unambiguously agentic use since the curator can weigh it against everything else.
    ///
    /// The per-kind multipliers are the part worth a second look, because they saturate at wildly
    /// different points and `QualityBlendTests` prints what that does. Flagged, not changed: what
    /// decides prominence is a product decision, not one to retune quietly.
    static func qualityScore(worth: Int, strength: Double, worthWeight: Double) -> Int {
        min(100, max(0, Int((worthWeight * Double(worth) + (1 - worthWeight) * strength).rounded())))
    }
}
