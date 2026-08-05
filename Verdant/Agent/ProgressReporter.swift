import Foundation

/// Serializes progress mutations from concurrent discovery tasks and emits an ordered snapshot
/// after each — the bridge from the off-main discovery job to the Deep Analysis UI's AsyncStream.
/// Beyond step updates it drives a heartbeat (`tick`) so the stream flows ~every 2 seconds with
/// fresh elapsed time, even during a long single inference (the activity line itself changes only on
/// a real event — no rotating filler).
actor ProgressReporter {
    private var progress = AnalysisProgress()
    private let emit: @Sendable (AnalysisProgress) -> Void
    private let start = ContinuousClock.now
    /// Monotonic id source for `LogLine`s, so each live-feed event has a stable identity.
    private var logCounter = 0
    // LLM call outcomes this run, so a genuine "nothing notable" pass can be told apart from a
    // wholesale inference failure (every model call errored) — the two must not share a closing note.
    private var llmAttempts = 0
    private var llmSuccesses = 0

    init(emit: @escaping @Sendable (AnalysisProgress) -> Void) {
        self.emit = emit
    }

    func apply(_ mutate: @Sendable (inout AnalysisProgress) -> Void) {
        mutate(&progress)
        refreshElapsed()
        emit(progress)
    }

    /// Record a concrete, real event: the specific operation now in flight (e.g. "Testing sleep ↔
    /// resting heart rate"). It becomes the headline `activity` AND is pushed onto the newest-first
    /// `activityLog` feed. This is the only thing that drives the activity line — there is no
    /// rotating filler, so what the user reads is always literally what's happening.
    func log(_ message: String) {
        logCounter += 1
        progress.activity = message
        progress.activityLog.insert(AnalysisProgress.LogLine(id: logCounter, text: message), at: 0)
        if progress.activityLog.count > AnalysisProgress.maxLogEntries {
            progress.activityLog.removeLast()
        }
        refreshElapsed()
        emit(progress)
    }

    /// Record whether one model call returned a result, so the run can distinguish "the model judged
    /// nothing worth telling" from "the model never answered."
    func noteLLMOutcome(success: Bool) {
        llmAttempts += 1
        if success { llmSuccesses += 1 }
    }

    /// True when the run issued model calls but none succeeded — reasoning didn't actually happen, so
    /// a `produced == 0` result is a failure to report, not a clean bill of health.
    var inferenceWhollyFailed: Bool {
        llmAttempts > 0 && llmSuccesses == 0
    }

    /// Findings the investigators proposed that the run had no time left to vet.
    ///
    /// A THIRD way `produced == 0` happens, and the one the closing note could not see. Inference did
    /// not fail and was not degraded — every call succeeded — the pass simply spent its budget
    /// generating proposals and hit the deadline before the panels could look at any of them.
    /// Measured: twenty proposals in one on-power window, all dropped this way. The run then told the
    /// user "that's a clean bill, not an empty one".
    private(set) var droppedForTime = 0

    func noteDroppedForTime() {
        droppedForTime += 1
    }

    /// True when a substantial share of model calls failed but some got through. The app's rule is
    /// that claiming "nothing notable" when nothing was reasoned is its worst failure — and a run
    /// where a quarter of the fleet never answered is a partial version of exactly that. One
    /// rate-limited retry among hundreds is noise; a third of the panel going missing is not, and
    /// the closing note should not call that a clean bill.
    var inferenceWasDegraded: Bool {
        llmAttempts > 0 && llmSuccesses > 0
            && Double(llmAttempts - llmSuccesses) / Double(llmAttempts) > 0.25
    }

    /// Heartbeat: advance the elapsed clock so the screen never looks frozen during a long single
    /// inference. It deliberately does NOT touch the activity text — only a real event changes that.
    func tick() {
        refreshElapsed()
        emit(progress)
    }

    private func refreshElapsed() {
        progress.elapsedSeconds = Int((ContinuousClock.now - start).components.seconds)
    }
}
