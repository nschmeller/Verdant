import Foundation
import Testing
@testable import Verdant

/// `concurrentMap` is the fan-out under EVERY agent panel — the investigator fleet, the safety
/// reviewers, the skeptics, the replication analysts, and the persist loop all run through it. It
/// had no tests at all, which is a poor place for that: if it dropped a result the skeptic panel
/// would silently vote with fewer members and its majority threshold would shift, and nothing else
/// in the suite would notice.
struct ConcurrentMapTests {
    /// Tracks how many transforms are in flight at once, so the bound can be asserted rather than
    /// assumed.
    private actor Watcher {
        private(set) var peak = 0
        private var current = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    @Test func `every item is transformed and nothing is dropped`() async {
        let input = Array(1...50)
        let out = await concurrentMap(input, maxConcurrent: 4) { $0 * 2 }
        // Order is explicitly not guaranteed, so compare as multisets.
        #expect(out.sorted() == input.map { $0 * 2 })
    }

    @Test func `no more than maxConcurrent run at once`() async {
        let watcher = Watcher()
        _ = await concurrentMap(Array(1...40), maxConcurrent: 3) { _ in
            await watcher.enter()
            try? await Task.sleep(for: .milliseconds(2))
            await watcher.leave()
        }
        #expect(await watcher.peak <= 3)
        #expect(await watcher.peak > 1) // and it really did overlap, so the bound means something
    }

    /// The production setting is 1 — on-device inference serializes on the Neural Engine anyway, and
    /// the whole panel design assumes one agent at a time at full power.
    @Test func `a limit of one is strictly serial`() async {
        let watcher = Watcher()
        _ = await concurrentMap(Array(1...20), maxConcurrent: 1) { _ in
            await watcher.enter()
            try? await Task.sleep(for: .milliseconds(1))
            await watcher.leave()
        }
        #expect(await watcher.peak == 1)
    }

    @Test func `an empty input yields nothing, and a nonsense limit still runs`() async {
        #expect(await concurrentMap([Int](), maxConcurrent: 4) { $0 }.isEmpty)
        // A zero or negative limit is clamped rather than deadlocking or dropping the work.
        let out = await concurrentMap([1, 2, 3], maxConcurrent: 0) { $0 }
        #expect(out.sorted() == [1, 2, 3])
    }

    /// More workers than items must not hang waiting for tasks that were never started.
    @Test func `fewer items than the limit completes`() async {
        let out = await concurrentMap([1, 2], maxConcurrent: 16) { $0 + 1 }
        #expect(out.sorted() == [2, 3])
    }
}
