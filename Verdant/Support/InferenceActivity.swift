import Dispatch
import Synchronization

/// Process-wide bookkeeping of on-device generations. Apple exposes **no public API for Neural Engine
/// utilization**, so the meter shows what CAN be measured honestly, counted at the one choke point
/// every model call flows through: whether the model is generating right now, how many calls have
/// run, and the cumulative time spent generating — from which the meter derives a duty cycle
/// ("the model was generating N% of the last minute"), the closest true proxy for ANE load available.
final nonisolated class InferenceActivity: Sendable {
    static let shared = InferenceActivity()

    private struct State {
        var inFlight = 0
        var totalCalls = 0
        /// Completed busy time, in monotonic nanoseconds.
        var busyNanos: UInt64 = 0
        /// When the current busy stretch began (valid while `inFlight > 0`).
        var busyStretchStart: UInt64 = 0
    }

    private let state = Mutex(State())

    func begin() {
        state.withLock {
            if $0.inFlight == 0 { $0.busyStretchStart = DispatchTime.now().uptimeNanoseconds }
            $0.inFlight += 1
            $0.totalCalls += 1
        }
    }

    func end() {
        state.withLock {
            $0.inFlight = max(0, $0.inFlight - 1)
            if $0.inFlight == 0 {
                $0.busyNanos &+= DispatchTime.now().uptimeNanoseconds &- $0.busyStretchStart
            }
        }
    }

    /// Generations currently in flight (with serial execution this is 0 or 1 — 1 means the ANE is
    /// actively generating).
    var inFlight: Int {
        state.withLock { $0.inFlight }
    }

    /// Total model calls since launch — the "agents run" odometer.
    var totalCalls: Int {
        state.withLock { $0.totalCalls }
    }

    /// Cumulative seconds the model has spent generating since launch, including the stretch in
    /// flight right now. Monotonic — the meter differences two samples to get a windowed duty cycle.
    var busySeconds: Double {
        state.withLock {
            var nanos = $0.busyNanos
            if $0.inFlight > 0 {
                nanos &+= DispatchTime.now().uptimeNanoseconds &- $0.busyStretchStart
            }
            return Double(nanos) / 1_000_000_000
        }
    }
}
