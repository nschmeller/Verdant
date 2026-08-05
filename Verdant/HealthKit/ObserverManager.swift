import Foundation

/// Wires HealthKit background delivery to deterministic ingestion. On each observer fire it runs
/// a brief, LLM-free ingest for the changed metric and then signals `onIngested` so the caller can
/// request a (heavier, opportunistic) background enhancement pass. Re-run `startObserving()` on
/// every launch to re-register observers.
@MainActor
final class ObserverManager {
    private let healthStore: HealthStore
    private let ingestor: Ingestor
    private let runGate: RunGate
    private let onIngested: @Sendable () async -> Void

    init(
        healthStore: HealthStore,
        ingestor: Ingestor,
        runGate: RunGate,
        onIngested: @escaping @Sendable () async -> Void
    ) {
        self.healthStore = healthStore
        self.ingestor = ingestor
        self.runGate = runGate
        self.onIngested = onIngested
    }

    func startObserving() async {
        let ingestor = ingestor
        let runGate = runGate
        let onIngested = onIngested
        await healthStore.startBackgroundObservers { metric in
            await Self.handleObservedChange(
                metric: metric, ingestor: ingestor, runGate: runGate, onIngested: onIngested
            )
        }
    }

    /// What one observer fire does. Extracted from the closure so it can be tested: `Ingestor` now
    /// takes `any HealthReading`, so the whole path is reachable without HealthKit.
    ///
    /// Take the run gate so this ingest's deletion-tombstone can't interleave with a discovery run's
    /// appends (which would let a finding built on just-deleted data survive). If a run holds the
    /// gate, SKIP the ingest: the delta sits at the saved anchor and the next gated ingest — or the
    /// next launch's catch-up — processes it, so nothing is lost.
    ///
    /// `onIngested` fires either way, and that placement is load-bearing. It is what asks for an
    /// enhancement pass; move it inside the `if` and every observer fire that lands while a run holds
    /// the gate stops requesting one. Nothing errors — the app just gets less background compute,
    /// which is the single thing its purpose is measured in.
    static func handleObservedChange(
        metric: MetricKey,
        ingestor: Ingestor,
        runGate: RunGate,
        onIngested: @Sendable () async -> Void
    ) async {
        if await runGate.tryAcquire() {
            defer { Task { await runGate.release() } }
            _ = try? await ingestor.ingest(metric: metric)
        }
        await onIngested()
    }
}
