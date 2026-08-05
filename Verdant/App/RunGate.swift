/// The single cross-cutting lock that serializes whole store-mutating runs across EVERY entry point —
/// foreground catch-up, Deep Analysis, the two background tasks, and the HealthKit observer's ingest.
///
/// Before this gate, mutual exclusion lived in two `@MainActor` view-state booleans that only the
/// foreground paths checked, so a background discovery pass (BGProcessingTask) or an observer-triggered
/// ingest could run *concurrently* with a foreground run — two passes fanning out over the same store
/// at once, letting one run's curation tombstone the other's just-surfaced findings, double-counting the
/// run state, and racing a deletion's tombstone against a persist's insert. An `actor` (not a MainActor
/// flag) is required because the background and observer callers run off the main actor.
///
/// A caller that arrives while a run holds the gate is **skipped**, not queued: discovery re-derives
/// from scratch each pass and ingest is anchored/idempotent, so the in-flight holder already covers the
/// skipped caller's work, and the next launch's catch-up reconciles anything missed.
actor RunGate {
    private var inFlight = false

    /// Acquire the gate, or return `false` if a run is already in flight. The check-and-set is one
    /// actor method, so it's atomic even though many callers race for it.
    func tryAcquire() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    func release() {
        inFlight = false
    }
}
