import Foundation
import Testing
@testable import Verdant

/// The supervisor that keeps the research program alive — the state machine behind the app's entire
/// purpose (run the Neural Engine for as long as possible).
///
/// The bug it exists to fix: on a first launch Apple Intelligence is very often still DOWNLOADING.
/// `runDiscovery` correctly refuses to run without a model, so the program returned within
/// milliseconds and nothing ever restarted it — the device then sat idle for the whole session
/// unless the user happened to background and foreground the app. So the distinction these pin is
/// the one that matters: states that RESOLVE must be waited on; only a state that never will, or an
/// explicit Stop, may end the program.
struct ResearchProgramSupervisorTests {
    private func step(
        _ capability: LLMCapability,
        userStopped: Bool = false,
        healthDataAvailable: Bool = true
    ) -> AppModel.ProgramStep {
        AppModel.nextProgramStep(
            capability: capability,
            userStopped: userStopped,
            healthDataAvailable: healthDataAvailable
        )
    }

    @Test func `a usable model means reason now`() {
        #expect(step(.available) == .run)
    }

    /// The regression that motivated the supervisor. Both of these resolve on their own — one when
    /// the download finishes, one when the user flips the Settings toggle — so ending here is what
    /// used to strand the device idle for an entire session.
    @Test func `states that resolve on their own are waited on, never treated as the end`() {
        #expect(step(.downloading) == .waitForModel)
        #expect(step(.notEnabled) == .waitForModel)
    }

    /// The other half: this device will never run Apple Intelligence, so polling it forever would
    /// burn battery to learn nothing.
    @Test func `hardware that can never run the model ends the supervision`() {
        #expect(step(.unavailableForever) == .end)
    }

    /// An explicit Stop outranks everything — including a perfectly usable model. This is the latch
    /// that keeps auto-start from overruling the user.
    @Test func `an explicit stop ends the program whatever the model is doing`() {
        for capability: LLMCapability in [.available, .downloading, .notEnabled, .unavailableForever] {
            #expect(step(capability, userStopped: true) == .end)
        }
    }

    /// Nothing to analyze and no way to get any: waiting would never become running.
    @Test func `no health data means there is nothing to supervise`() {
        #expect(step(.available, healthDataAvailable: false) == .end)
        #expect(step(.downloading, healthDataAvailable: false) == .end)
    }
}
