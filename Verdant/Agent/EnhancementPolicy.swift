/// Throughput knobs for the agentic discovery phase — deliberately separate from `TokenBudget`
/// (which caps *per-session token usage*). These govern how much work we issue, not how many tokens
/// a single session may use.
///
/// Everything here is either concurrency plumbing or a schema bound. There are deliberately no
/// per-kind caps: `maxCorrelations` / `maxVolatility` / `maxMilestones` / `maxRegimeShifts` existed
/// when a logical pipeline picked the strongest N of each kind to hand the model, and they were
/// referenced by nothing at all once the investigator agent started choosing for itself. They are
/// deleted rather than left sitting here reading like live limits on how much the app reasons.
nonisolated enum EnhancementPolicy {
    /// **Serial by design (1).** On-device inference serializes on the Neural Engine anyway, and issuing
    /// several sessions at once makes the OS split each one's resources and burns the generation
    /// rate-limit in bursts (more errors, less reasoning actually completes). Running exactly one agent
    /// at a time keeps every agent at full power and the engine saturated *continuously* — the way to
    /// run the most reasoning per unit time on-device. "Many subagents" is about VOLUME (deep, long
    /// runs), not concurrency. This single knob governs EVERY fan-out in the app: discovery, the
    /// safety and skeptic panels, and the deep run's fleet alike.
    static let maxConcurrentSubagents = 1

    /// Schema bound on how many findings one investigator may propose in a single session (rides in
    /// `InvestigationResult`'s count guide). A window limit, not a worth judgment — the panels decide
    /// what survives, and a lens that has more to say gets another session next pass.
    static let maxCandidates = 8

    /// The bounded findings budget. The feed should hold roughly 3–12 high-quality findings; the
    /// curator agent keeps the active insight + correlation set at or under this, retiring the
    /// rest. Held a touch under 12 so the feed always stays comfortably inside the "a few, not a
    /// wall" range. (The old deterministic quality floors are gone — worth is entirely the
    /// agents' decision, per the agents-decide architecture.)
    static let maxActiveFindings = 11
}

/// Knobs for the **Deep Analysis** research program — the indefinite, hours-or-days pass. It fans out
/// far wider than the bounded background job: a scout sweep and a per-metric investigator rotation on
/// top of the thematic fleet, refreshed against new data as it arrives. Depth comes from many long
/// passes, never from lowering the bar — every finding still clears the same agent panels.
///
/// Concurrency is NOT among these: every fan-out in the app runs at
/// `EnhancementPolicy.maxConcurrentSubagents`, and a separate deep-run copy of that knob was dead
/// code implying deep runs parallelise when the whole design says they deliberately do not.
nonisolated enum DeepAnalysisPolicy {
    /// Runaway backstop on discovery passes — NOT a target. A deep run is INDEFINITE by design: it
    /// keeps reasoning for as long as the app stays open, ending only by cancellation (the Stop
    /// button, or the app leaving the foreground). At real on-device pass durations this cap is days
    /// of continuous compute; it exists purely so a logic bug can't spin a truly infinite loop.
    static let maxPasses = 1000
    /// After this many consecutive dry breadth passes the run SWITCHES STRATEGY — drilling into its
    /// own strongest findings with the focused lens fleet — rather than stopping. Dryness picks the
    /// next move, never the end. Only the fallback when the director can't render a plan.
    static let dryStreakToStop = 2
    /// Rebuild the data substrate every N passes: an indefinite run must fold in the Health data
    /// that arrived while it was reasoning (and cross day boundaries correctly) instead of analyzing
    /// a frozen snapshot for hours.
    static let substrateRefreshPasses = 12

    // MARK: Discovery loop (scouts)

    /// Scouts per deep pass — the discovery loop's width. Each scout SURVEYS the data through a
    /// rotating angle and hands back testable leads; the investigator fleet chases them same-pass.
    static let scoutsPerPass = 2
    /// Leads one scout may hand over (rides in the `ScoutReport` count guide so it can't drift).
    static let maxLeadsPerScout = 4
    /// The most lead lenses one pass can gain — a consequence of the schema, not a separate cap.
    /// The old `maxLeadsPerPass = 6` truncated the sweep by arrival order (scout 1's weakest lead
    /// beating scout 2's strongest), which is a worth judgment nothing was qualified to make; every
    /// distinct lead is chased now. Kept as a derived figure so the pass's ceiling stays legible.
    static var maxLeadsPerPass: Int {
        maxLeadsPerScout * scoutsPerPass
    }

    // MARK: Verification loop (standing-finding audit)

    /// Standing findings re-tested against FRESH data at each substrate refresh. The audit points
    /// the armed replication panel at what the feed already shows: findings must keep earning
    /// their place as new data arrives, not just earn it once. The docket ROTATES through the feed
    /// across refreshes (see `auditCandidates`), so this is a per-refresh rate, not a ceiling on
    /// which findings are ever re-tested.
    static let auditFindingsPerRefresh = 4
}
