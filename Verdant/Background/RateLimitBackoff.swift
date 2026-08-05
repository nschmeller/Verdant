import Foundation
import FoundationModels

/// On-device inference shares the Apple Neural Engine as a serially rate-limited system resource,
/// surfaced as `GenerationError.rateLimited` regardless of remaining task budget. This retries with
/// exponential backoff, but counts its own sleeps against an optional wall-clock deadline so it
/// gives up gracefully instead of tight-looping when the background window is nearly spent.
nonisolated enum RateLimitBackoff {
    /// Carries WHY it gave up. `Exhausted` used to be empty, and `llm` logs only
    /// `localizedDescription` — so every abandoned call read as "Verdant.RateLimitBackoff.Exhausted
    /// error 1", which cannot distinguish "the Neural Engine was busy and we ran out of attempts"
    /// from "we ran out of background window". Those call for opposite responses, and the question
    /// comes up for real: when a panel renders three verdicts out of five, whether the missing two
    /// abstained or were never answered is the difference between a calibration problem and a
    /// throughput one.
    struct Exhausted: Error, CustomStringConvertible {
        let attempts: Int
        /// Nil when the deadline stopped it before the attempt limit did.
        let outOfAttempts: Bool
        let underlying: Error

        var description: String {
            let reason = outOfAttempts ? "attempt limit" : "deadline"
            return "rate-limit backoff gave up after \(attempts) attempt(s) on the \(reason) "
                + "— last error: \(underlying)"
        }

        var localizedDescription: String {
            description
        }
    }

    /// `isRetryable` is injectable so the retry/backoff mechanics can be unit-tested without
    /// constructing the SDK's private rate-limit error; it defaults to `isRateLimited`.
    static func run<T>(
        maxAttempts: Int = 3,
        deadline: ContinuousClock.Instant? = nil,
        isRetryable: @Sendable (Error) -> Bool = isRateLimited,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard isRetryable(error) else { throw error }
                attempt += 1
                if attempt >= maxAttempts {
                    throw Exhausted(attempts: attempt, outOfAttempts: true, underlying: error)
                }
                // Give up if the deadline has passed OR if the next backoff would run past it.
                // Checking only "has it passed" let a nearly-spent window start a 2-second sleep it
                // could not afford, then wake up already over budget — burning the tail of an
                // OS-granted background grant on waiting rather than reasoning, which is the exact
                // opposite of what that grant is for.
                let delay = Duration.seconds(1 << (attempt - 1))
                if let deadline, ContinuousClock.now.advanced(by: delay) >= deadline {
                    throw Exhausted(attempts: attempt, outOfAttempts: false, underlying: error)
                }
                try await Task.sleep(for: delay)
            }
        }
    }

    static func isRateLimited(_ error: Error) -> Bool {
        guard let generation = error as? LanguageModelSession.GenerationError else { return false }
        if case .rateLimited = generation { return true }
        return false
    }
}
