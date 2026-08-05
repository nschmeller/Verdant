import Foundation
import Testing
@testable import Verdant

/// Locks the deep-analysis live-feed contract: `log` records real events (newest-first, capped, and
/// it sets the headline `activity`), while the heartbeat `tick` advances only the clock — there is no
/// rotating filler that could overwrite what's actually happening.
struct ProgressReporterTests {
    /// Capture the latest emitted snapshot from the actor's off-main `emit` callback. `nonisolated`
    /// so it's callable from the reporter's actor context; safe because the test awaits each call
    /// sequentially (no real concurrency).
    private final class Sink: @unchecked Sendable {
        nonisolated(unsafe) var latest = AnalysisProgress()
        nonisolated func receive(_ progress: AnalysisProgress) {
            latest = progress
        }
    }

    @Test func `log sets the headline and prepends newest-first`() async {
        let sink = Sink()
        let reporter = ProgressReporter { sink.receive($0) }
        await reporter.log("first")
        await reporter.log("second")
        #expect(sink.latest.activity == "second") // headline is the latest event
        #expect(sink.latest.activityLog.map(\.text) == ["second", "first"]) // newest-first feed
        #expect(Set(sink.latest.activityLog.map(\.id)).count == 2) // each event has a distinct id
    }

    @Test func `log caps the feed at maxLogEntries`() async {
        let sink = Sink()
        let reporter = ProgressReporter { sink.receive($0) }
        for index in 0..<(AnalysisProgress.maxLogEntries + 5) {
            await reporter.log("event \(index)")
        }
        #expect(sink.latest.activityLog.count == AnalysisProgress.maxLogEntries)
        // The most recent event is retained; the oldest have fallen off.
        #expect(sink.latest.activityLog.first?.text == "event \(AnalysisProgress.maxLogEntries + 4)")
        #expect(!sink.latest.activityLog.contains { $0.text == "event 0" })
    }

    @Test func `tick advances the clock without touching the activity line`() async {
        let sink = Sink()
        let reporter = ProgressReporter { sink.receive($0) }
        await reporter.log("doing the real thing")
        await reporter.tick()
        // No rotating filler: the headline still names the real operation after a heartbeat.
        #expect(sink.latest.activity == "doing the real thing")
        #expect(sink.latest.activityLog.count == 1)
    }

    @Test func `wholesale inference failure is reported only when every model call failed`() async {
        let reporter = ProgressReporter { _ in }
        // No calls attempted yet → not a failure (a real clean pass also starts here).
        #expect(await reporter.inferenceWhollyFailed == false)
        await reporter.noteLLMOutcome(success: false)
        await reporter.noteLLMOutcome(success: false)
        // Calls were attempted and all failed → the run reasoned about nothing; not a clean bill.
        #expect(await reporter.inferenceWhollyFailed)
        // A single success means the model WAS working, so a 0-finding result is a genuine clean pass.
        await reporter.noteLLMOutcome(success: true)
        #expect(await reporter.inferenceWhollyFailed == false)
    }

    /// The THIRD way a pass produces nothing, and the one the closing note could not see: every
    /// model call succeeded, so neither of the two signals above fires, but the run spent its budget
    /// proposing findings and had no time left to vet any of them. Measured: twenty proposals in one
    /// on-power window, all dropped, and the run reported "that's a clean bill, not an empty one".
    ///
    /// Independent of the inference signals on purpose — a pass can be degraded AND out of time, and
    /// conflating them is the defect this whole family of counters exists to prevent.
    @Test func `dropping findings for time is its own signal, not an inference failure`() async {
        let reporter = ProgressReporter { _ in }
        #expect(await reporter.droppedForTime == 0)
        for _ in 0..<20 {
            await reporter.noteLLMOutcome(success: true)
        }
        await reporter.noteDroppedForTime()
        await reporter.noteDroppedForTime()
        #expect(await reporter.droppedForTime == 2)
        // A run whose calls all worked is neither failed nor degraded — which is exactly why the
        // closing note needed this counter to tell it anything at all.
        #expect(await !reporter.inferenceWhollyFailed)
        #expect(await !reporter.inferenceWasDegraded)
    }

    /// "Nothing rose above the noise — that's a clean bill" is a strong claim, and the app's own rule
    /// is that making it when nothing was reasoned is its worst failure. A pass where a quarter of
    /// the fleet never answered is a partial version of the same thing and must not read identically
    /// to a thorough pass that genuinely found nothing.
    @Test func `a pass is degraded when a substantial share of calls fail, but not on stray misses`(
    ) async {
        let quiet = ProgressReporter { _ in }
        for _ in 0..<20 {
            await quiet.noteLLMOutcome(success: true)
        }
        await quiet.noteLLMOutcome(success: false) // 1 in 21 — noise, not degradation
        #expect(await !quiet.inferenceWasDegraded)

        let struggling = ProgressReporter { _ in }
        for _ in 0..<6 {
            await struggling.noteLLMOutcome(success: true)
        }
        for _ in 0..<4 {
            await struggling.noteLLMOutcome(success: false)
        } // 40% lost
        #expect(await struggling.inferenceWasDegraded)
        #expect(await !struggling.inferenceWhollyFailed) // some did get through

        // Wholly failed is its own case and must not also read as merely degraded.
        let dead = ProgressReporter { _ in }
        for _ in 0..<5 {
            await dead.noteLLMOutcome(success: false)
        }
        #expect(await dead.inferenceWhollyFailed)
        #expect(await !dead.inferenceWasDegraded)
    }
}
