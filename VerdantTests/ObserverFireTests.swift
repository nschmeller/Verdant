import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Verdant

/// What one HealthKit observer fire does.
///
/// The gate is taken so an observer ingest's deletion-tombstones cannot interleave with a discovery
/// run's appends — otherwise a finding built on just-deleted data could survive. When the gate is
/// held the ingest is skipped, which is safe: the delta sits at the saved anchor and the next gated
/// ingest processes it.
///
/// The part that is easy to lose is where `onIngested` sits. It is what ASKS for an enhancement
/// pass, and it must fire whether or not the gate was free. Move it inside the `if` and every
/// observer fire landing during a run stops requesting one — nothing errors, the app simply gets
/// less background compute, which is the single thing its purpose is measured in.
struct ObserverFireTests {
    /// Counts HealthKit reads so "did the ingest actually run" is observable.
    private final class CountingHealth: HealthReading, @unchecked Sendable {
        private(set) var scans = 0

        func anchoredScan(for _: MetricKey, anchor _: Data?) async throws -> AnchoredScan {
            scans += 1
            return AnchoredScan(newAnchor: Data([1]), affectedDays: [], hadDeletions: false, addedCount: 0)
        }

        func dailyValues(for _: MetricKey, dayStart _: Date) async throws -> DayValues? {
            nil
        }

        func dailyValuesRange(
            for _: MetricKey, from _: Date, to _: Date
        ) async throws -> [DayRollup] {
            []
        }

        func earliestSampleDate(for _: MetricKey) async throws -> Date? {
            nil
        }
    }

    private final class Signal: Sendable {
        private let count = Mutex(0)

        nonisolated var fired: Int {
            count.withLock { $0 }
        }

        nonisolated func mark() {
            count.withLock { $0 += 1 }
        }
    }

    @Test func `a free gate ingests and asks for an enhancement pass`() async throws {
        let health = CountingHealth()
        let signal = Signal()
        let writer = try StoreWriter(modelContainer: TestSupport.inMemoryContainer())

        await ObserverManager.handleObservedChange(
            metric: .stepCount,
            ingestor: Ingestor(healthStore: health, writer: writer),
            runGate: RunGate(),
            onIngested: { signal.mark() }
        )

        #expect(health.scans == 1, "the observer fire did not ingest")
        #expect(signal.fired == 1, "no enhancement pass was requested")
    }

    /// The property worth protecting: a busy gate skips the INGEST but must still request the pass.
    @Test func `a held gate skips the ingest but still asks for the pass`() async throws {
        let health = CountingHealth()
        let signal = Signal()
        let writer = try StoreWriter(modelContainer: TestSupport.inMemoryContainer())
        let gate = RunGate()
        #expect(await gate.tryAcquire(), "the test must hold the gate for this to mean anything")

        await ObserverManager.handleObservedChange(
            metric: .stepCount,
            ingestor: Ingestor(healthStore: health, writer: writer),
            runGate: gate,
            onIngested: { signal.mark() }
        )

        #expect(health.scans == 0, "the ingest ran while a run held the gate")
        #expect(
            signal.fired == 1,
            "a fire during a run asked for no enhancement pass — background compute silently lost"
        )
    }

    /// And the gate is released afterwards, or the first observer fire of a session would block every
    /// later run for good.
    @Test func `the gate is released after the fire`() async throws {
        let writer = try StoreWriter(modelContainer: TestSupport.inMemoryContainer())
        let gate = RunGate()

        await ObserverManager.handleObservedChange(
            metric: .stepCount,
            ingestor: Ingestor(healthStore: CountingHealth(), writer: writer),
            runGate: gate,
            onIngested: {}
        )

        // The release is deferred into a Task, so give it a turn to land.
        for _ in 0..<100 where await !(gate.tryAcquire()) {
            await Task.yield()
        }
        #expect(await !gate.tryAcquire(), "acquired twice — the gate was never released and retaken")
    }
}
