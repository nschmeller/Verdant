import Foundation
import Testing
@testable import Verdant

/// The bookkeeping the whole ANE story rests on. `busySeconds` is differenced by `ResourceMonitor`
/// to produce the duty cycle — the one number that says whether the app is achieving its purpose —
/// and `totalCalls` is the "agents run" odometer on the meter. None of it was tested.
///
/// Tests use their own instance rather than `.shared`, so they neither depend on nor disturb the
/// process-wide counter that real runs are writing to.
struct InferenceActivityTests {
    @Test func `a generation is in flight between begin and end`() {
        let activity = InferenceActivity()
        #expect(activity.inFlight == 0)
        activity.begin()
        #expect(activity.inFlight == 1)
        activity.end()
        #expect(activity.inFlight == 0)
    }

    /// The odometer counts every call ever issued and never goes down — the meter shows it as a
    /// running total for the session.
    @Test func `total calls only ever climbs`() {
        let activity = InferenceActivity()
        for _ in 0..<5 {
            activity.begin()
            activity.end()
        }
        #expect(activity.totalCalls == 5)
        activity.begin()
        #expect(activity.totalCalls == 6) // counted at begin, not at completion
        activity.end()
    }

    @Test func `busy time accumulates and is monotonic`() async throws {
        let activity = InferenceActivity()
        #expect(activity.busySeconds == 0)

        activity.begin()
        try await Task.sleep(for: .milliseconds(30))
        activity.end()
        let afterFirst = activity.busySeconds
        #expect(afterFirst >= 0.02)

        // Idle time does not accumulate.
        try await Task.sleep(for: .milliseconds(30))
        #expect(abs(activity.busySeconds - afterFirst) < 0.005)

        activity.begin()
        try await Task.sleep(for: .milliseconds(30))
        activity.end()
        #expect(activity.busySeconds > afterFirst)
    }

    /// Reading mid-generation must include the stretch still running, or a duty cycle sampled during
    /// a long generation would read as idle — exactly backwards for the metric's whole purpose.
    @Test func `busy time includes the stretch currently in flight`() async throws {
        let activity = InferenceActivity()
        activity.begin()
        try await Task.sleep(for: .milliseconds(30))
        let midFlight = activity.busySeconds
        #expect(midFlight >= 0.02)
        activity.end()
        #expect(activity.busySeconds >= midFlight)
    }

    /// Overlapping generations measure the UNION of busy time, not the sum. "Was the engine working"
    /// is the question a duty cycle answers; adding two concurrent seconds to make two would let the
    /// ratio exceed 1 and mean nothing.
    @Test func `overlapping generations measure wall-clock, not summed durations`() async throws {
        let activity = InferenceActivity()
        activity.begin()
        activity.begin() // a second one starts while the first is still running
        try await Task.sleep(for: .milliseconds(40))
        activity.end()
        activity.end()
        // ~40ms of wall clock, not ~80ms of summed generation time.
        #expect(activity.busySeconds < 0.075)
        #expect(activity.busySeconds >= 0.03)
    }

    /// An unbalanced `end` must not drive the counter negative and strand the meter reading
    /// "generating" forever.
    @Test func `an unmatched end cannot push in-flight below zero`() {
        let activity = InferenceActivity()
        activity.end()
        activity.end()
        #expect(activity.inFlight == 0)
        activity.begin()
        #expect(activity.inFlight == 1)
        activity.end()
        #expect(activity.inFlight == 0)
    }
}
