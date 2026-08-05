import Testing
@testable import Verdant

/// The single cross-cutting lock that keeps foreground, background, and observer runs from fanning out
/// over the store at once. These pin its exclusion semantics so the concurrency regression can't return.
struct RunGateTests {
    @Test func `a held gate blocks a second acquire until released`() async {
        let gate = RunGate()
        #expect(await gate.tryAcquire()) // first run acquires
        #expect(await gate.tryAcquire() == false) // second is skipped while the first holds it
        await gate.release()
        #expect(await gate.tryAcquire()) // available again once released
    }

    /// Unlike most concurrency tests, this one is RELIABLE, and that was verified rather than
    /// assumed: introducing the realistic regression — an `await` inside `tryAcquire`, which breaks
    /// atomicity through actor reentrancy — fails it every time, with 31 winners instead of 1.
    ///
    /// The reason it is trustworthy where `OnceLatchTests`' equivalent is not: a suspension point is
    /// a real, scheduler-visible interleaving opportunity, so every racer piles into it. A split
    /// read/write behind a `Mutex` leaves only an instruction-width window, which 32 racers can miss
    /// entirely. Same test shape, very different evidence.
    @Test func `concurrent racers: exactly one acquires`() async {
        let gate = RunGate()
        // Every entry point (2 foreground, 2 background, the observer) can race for the gate at once;
        // the actor serializes tryAcquire, so exactly one sees it idle and the rest are skipped.
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask { await gate.tryAcquire() }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(winners == 1)
    }
}
