import Foundation
import Testing
@testable import Verdant

/// The latch that decides whether a background task is completed exactly once.
///
/// `setTaskCompleted` called TWICE traps; called NEVER, the system kills the app and cuts its future
/// background windows — which for this app means less Neural Engine time, the one thing it is
/// measured by. Both callers race by design: the work task finishes on one queue while the OS fires
/// the expiration handler on another, and `BackgroundScheduler` already records a field bug in
/// exactly that area (`MainActor.assumeIsolated` in the expiration handler, which trapped).
///
/// `BGTask` cannot be faked, so the guard wrapping it stays untestable. The latch does not have to
/// be, which is why it is now its own type.
struct OnceLatchTests {
    @Test func `the first claim succeeds and every later one fails`() {
        let latch = OnceLatch()
        #expect(latch.claim())
        #expect(!latch.claim())
        #expect(!latch.claim())
    }

    /// The case the type exists for: two queues racing. Exactly one caller may win, however many
    /// try at once — one winner means one `setTaskCompleted`.
    ///
    /// Honest limitation, measured rather than assumed. Splitting the latch's read and write across
    /// two separate lock acquisitions — a real race — did NOT fail this test: 32 claimers over 50
    /// rounds never landed inside so narrow a window. Widening that window (a spin between the read
    /// and the write) fails it immediately, with 11-12 winners. So this detects a race whose window
    /// is non-trivial and can miss an instruction-width one; the reliable guarantee here is the
    /// sequential property above, and the single `withLock` in `claim()` is what actually makes the
    /// narrow case impossible.
    @Test func `exactly one of many concurrent claims wins`() async {
        for _ in 0..<50 {
            let latch = OnceLatch()
            var winners = 0
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<32 {
                    group.addTask { latch.claim() }
                }
                for await won in group where won {
                    winners += 1
                }
            }
            #expect(winners == 1, "\(winners) callers won the latch")
        }
    }

    /// Latches are independent — one task completing must not complete another. A shared or static
    /// latch would mean the second background window of a session never reports at all.
    @Test func `separate latches do not interfere`() {
        let first = OnceLatch()
        let second = OnceLatch()
        #expect(first.claim())
        #expect(second.claim(), "a second task's latch was consumed by the first")
    }
}
