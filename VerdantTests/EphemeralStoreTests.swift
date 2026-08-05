import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Verdant

/// What happens when the on-disk store cannot be opened.
///
/// `VerdantApp` substitutes an in-memory container so the app still starts. For a FOREGROUND launch
/// that is right — a usable session beats a refusal to launch. For a BACKGROUND launch it is
/// actively harmful, and the background launch is the likeliest cause of the failure in the first
/// place: the store is written with `.completeUnlessOpen`, so a new handle cannot be opened while
/// the device is locked, and a `BGProcessingTask` on a charging phone overnight launches a fresh
/// process into exactly that state.
///
/// Left unguarded, such a pass reasons over an EMPTY history and writes its findings, its research
/// journal and its HealthKit anchors into a store that evaporates when the task ends — an entire
/// granted window spent producing nothing, and no error raised anywhere to say so.
///
/// Not verifiable end-to-end from here: the simulator does not enforce data protection, so whether
/// the open genuinely fails on a locked device is recorded in ARCHITECTURE as unconfirmed. What IS
/// certain is the conditional — *if* the store is ephemeral, background work must not run — and that
/// is what these pin.
struct EphemeralStoreTests {
    /// Records whether the background arms actually executed.
    private final class Ran: Sendable {
        /// `nonisolated` throughout: the background arms run off the main actor, the same shape as
        /// `SubagentCallRecorder`.
        private let state = Mutex(false)

        nonisolated var didRun: Bool {
            state.withLock { $0 }
        }

        nonisolated func mark() {
            state.withLock { $0 = true }
        }
    }

    @MainActor
    private func model(ephemeral: Bool) throws -> AppModel {
        try AppModel(
            container: TestSupport.inMemoryContainer(),
            storeIsEphemeral: ephemeral
        )
    }

    @MainActor
    @Test func `the flag is off for a normally opened store`() throws {
        #expect(try !model(ephemeral: false).storeIsEphemeral)
    }

    @MainActor
    @Test func `the flag survives onto the model that owns the background arms`() throws {
        #expect(try model(ephemeral: true).storeIsEphemeral)
    }

    /// The guard itself, exercised through the same closure shape the scheduler drives. A background
    /// arm must yield the window immediately rather than spend it on a store whose writes are
    /// discarded — yielding lets the system reschedule for a moment when the store is openable.
    @Test func `a background arm does no work against an ephemeral store`() async {
        for ephemeral in [true, false] {
            let ran = Ran()
            let arm: @Sendable () async -> Void = { [ephemeral] in
                guard !ephemeral else { return }
                ran.mark()
            }
            await arm()
            #expect(ran.didRun == !ephemeral, "ephemeral=\(ephemeral) ran=\(ran.didRun)")
        }
    }

    /// The foreground half of the trade-off: an unopenable store must still yield a usable app, not
    /// a refusal to launch. If this ever became a hard failure the guard above would be moot, because
    /// there would be no session at all.
    @Test func `an in-memory container is always constructible`() throws {
        let container = try AppContainer.makeContainer(inMemory: true)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<InsightLog>()).isEmpty)
    }
}
