import Foundation
import Testing
@testable import Verdant

private struct DummyError: Error {}

private actor Counter {
    private(set) var count = 0
    func next() -> Int {
        defer { count += 1 }; return count
    }
}

struct RateLimitBackoffTests {
    @Test func `returns value on success`() async throws {
        let result = try await RateLimitBackoff.run { 42 }
        #expect(result == 42)
    }

    @Test func `rethrows non retryable immediately`() async {
        await #expect(throws: DummyError.self) {
            try await RateLimitBackoff.run(isRetryable: { _ in false }, operation: { throw DummyError() })
        }
    }

    @Test func `gives up at deadline without sleeping`() async {
        // Deadline already in the past → it must give up immediately rather than sleep.
        let deadline = ContinuousClock.now
        await #expect(throws: RateLimitBackoff.Exhausted.self) {
            try await RateLimitBackoff.run(
                deadline: deadline,
                isRetryable: { _ in true },
                operation: { throw DummyError() }
            )
        }
    }

    /// The deadline bounds the SLEEP, not just the moment before it. A window with a little time
    /// left used to start a backoff it could not afford and wake up already over budget — spending
    /// the tail of an OS-granted background grant on waiting instead of reasoning.
    @Test func `a backoff that would overrun the deadline is not started`() async {
        let counter = Counter()
        // Comfortably inside the deadline now, but the first backoff is a full second.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        let started = ContinuousClock.now
        do {
            _ = try await RateLimitBackoff.run(
                deadline: deadline,
                isRetryable: { _ in true },
                operation: { _ = await counter.next(); throw DummyError() }
            )
            Issue.record("expected the backoff to give up")
        } catch {
            #expect(error is RateLimitBackoff.Exhausted)
        }
        // It attempted once and returned promptly rather than sleeping past the deadline.
        #expect(await counter.count == 1)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    @Test func `retries then succeeds`() async throws {
        let counter = Counter()
        let result = try await RateLimitBackoff.run(isRetryable: { _ in true }, operation: {
            if await counter.next() == 0 { throw DummyError() }
            return 7
        })
        #expect(result == 7)
        #expect(await counter.count == 2)
    }

    @Test func `gives up after the attempt cap, the only backstop when there is no deadline`() async {
        // The Q&A path runs with deadline: nil, so the attempt cap is the ONLY thing stopping a
        // persistently rate-limited call from retrying forever. maxAttempts: 1 → one try, then give up,
        // with no sleep — proving the cap throws Exhausted independent of any deadline.
        let counter = Counter()
        await #expect(throws: RateLimitBackoff.Exhausted.self) {
            try await RateLimitBackoff.run(maxAttempts: 1, isRetryable: { _ in true }, operation: {
                _ = await counter.next()
                throw DummyError()
            })
        }
        #expect(await counter.count == 1) // tried exactly once, then stopped — never an unbounded loop
    }

    @Test func `is rate limited false for arbitrary error`() {
        #expect(!RateLimitBackoff.isRateLimited(DummyError()))
    }
}

/// Why the backoff gave up, not just that it did.
///
/// `Exhausted` was an empty struct, and `Orchestrator.llm` logs only `localizedDescription` — so
/// every abandoned model call read as "Verdant.RateLimitBackoff.Exhausted error 1". That cannot
/// distinguish a busy Neural Engine from a spent background window, and those call for opposite
/// responses.
///
/// It is not a hypothetical distinction. When a replication panel renders three verdicts out of
/// five, whether the missing two ABSTAINED or were never answered decides whether the problem is
/// the panel's calibration or the app's throughput — and the log could not say.
struct ExhaustedDiagnosisTests {
    private struct Busy: Error {}

    @Test func `running out of attempts says so, with the error it gave up on`() async {
        do {
            _ = try await RateLimitBackoff.run(
                maxAttempts: 2,
                deadline: nil,
                isRetryable: { _ in true },
                operation: { throw Busy() }
            )
            Issue.record("the operation should not have succeeded")
        } catch let exhausted as RateLimitBackoff.Exhausted {
            #expect(exhausted.outOfAttempts, "blamed the deadline when there was none")
            #expect(exhausted.attempts == 2)
            #expect(exhausted.underlying is Busy, "the original error was discarded")
            #expect(
                exhausted.description.contains("attempt limit"),
                Comment(rawValue: exhausted.description)
            )
        } catch {
            Issue.record("threw \(error) rather than Exhausted")
        }
    }

    /// The other reason, which reads identically in a log without this field: the window ran out
    /// before the attempts did.
    @Test func `running out of window blames the deadline`() async {
        do {
            _ = try await RateLimitBackoff.run(
                maxAttempts: 99,
                deadline: ContinuousClock.now, // already spent
                isRetryable: { _ in true },
                operation: { throw Busy() }
            )
            Issue.record("the operation should not have succeeded")
        } catch let exhausted as RateLimitBackoff.Exhausted {
            #expect(!exhausted.outOfAttempts, "blamed the attempt limit on a 99-attempt budget")
            #expect(exhausted.underlying is Busy)
            #expect(
                exhausted.description.contains("deadline"),
                Comment(rawValue: exhausted.description)
            )
        } catch {
            Issue.record("threw \(error) rather than Exhausted")
        }
    }

    /// And a non-retryable error still comes through untouched — wrapping everything would lose the
    /// distinction this exists to preserve.
    @Test func `a non-retryable error is not wrapped`() async {
        do {
            _ = try await RateLimitBackoff.run(
                isRetryable: { _ in false },
                operation: { throw Busy() }
            )
            Issue.record("the operation should not have succeeded")
        } catch is RateLimitBackoff.Exhausted {
            Issue.record("a non-retryable error was wrapped as Exhausted")
        } catch {
            #expect(error is Busy)
        }
    }
}
