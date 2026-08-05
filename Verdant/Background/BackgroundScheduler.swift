import BackgroundTasks
import Foundation
import OSLog
import Synchronization

/// Schedules and handles the two background task classes, deliberately split by power:
///
/// - **Refresh** (`BGAppRefreshTask`, power-independent): a quick catch-up that drains HealthKit
///   deltas into fresh rollups. It produces NO findings off-power — every finding needs the model —
///   so its job is purely to keep the data current, so the next foreground or on-power run reasons
///   over an up-to-date base rather than re-ingesting years of history first.
/// - **Enhance** (`BGProcessingTask`, `requiresExternalPower`): the full reasoning pass — the heavier,
///   opportunistic LLM enhancement batch, which wants the multi-minute ANE window charging affords.
///
/// Both reschedule the next request *before* calling `setTaskCompleted` (tasks are one-shot), and
/// the expiration handler is the hard backstop that cancels in-flight work.
@MainActor
final class BackgroundScheduler {
    static let refreshIdentifier = Identifiers.refreshTask
    static let enhanceIdentifier = Identifiers.enhanceTask

    private let runCatchUp: @Sendable () async -> Void
    private let runEnhancement: @Sendable (ContinuousClock.Instant) async -> Void
    private static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "Background")

    /// Wall-clock budget for the enhancement batch. BGProcessingTask grants on external power
    /// routinely run for MINUTES (commonly 10+ when charging and idle); the old 150s budget
    /// yielded with most of that ANE window unused. The expiration handler remains the true hard
    /// stop — the orchestrator observes cancellation cooperatively and banks what it has — so this
    /// budget's only job is to stop issuing NEW sessions just before a typical grant expires,
    /// per the direction that on-power windows are used to their fullest.
    ///
    /// MEASURED 2026-08-03, and 540 seconds does not fit one pass. Every figure below is from the
    /// real on-device model; the phases are SEQUENTIAL, with a hard barrier — `runPass` fans every
    /// investigator out, waits for all of them, dedups, and only then vets (`Orchestrator.swift`,
    /// the `concurrentMap` over `unique`).
    ///
    ///     13 investigators, one pass          432 s   (446 s on a second run)
    ///     safety panel, per finding             4.5 s
    ///     skeptic panel, per finding           18 s
    ///     replication panel, per finding       41 s
    ///     -> vetting one finding               ~64 s
    ///
    /// A pass produced 20 proposals. Vetting them costs roughly 1,280 seconds against the 432 the
    /// investigators already spent — so **vetting is about three times more expensive than
    /// proposing**, and the budget covers neither. In practice the window buys 13 investigators and
    /// then has ~108 seconds left, enough to vet one or two findings; the rest are dropped at the
    /// deadline (see `Orchestrator.affordsVetting`, which now at least says so).
    ///
    /// Raising the number does not fix it: a full pass needs ~1,700 seconds and BGProcessingTask
    /// does not reliably grant that. The shapes that would are a scheduling decision, not a constant
    /// — vet each proposal as it arrives instead of batching after the barrier (loses only the tail,
    /// but re-vets duplicates the dedup currently removes), stop launching investigators once the
    /// remaining time cannot vet what is already in hand, or run fewer lenses per pass. Each trades
    /// something real, so the number is left alone and the arithmetic written down.
    private static let enhancementBudget: Duration = .seconds(540)

    init(
        runCatchUp: @escaping @Sendable () async -> Void,
        runEnhancement: @escaping @Sendable (ContinuousClock.Instant) async -> Void
    ) {
        self.runCatchUp = runCatchUp
        self.runEnhancement = runEnhancement
    }

    /// Both registrations report whether they took, and both results are CHECKED.
    ///
    /// `register(forTaskWithIdentifier:)` returns false when the identifier is not in
    /// `BGTaskSchedulerPermittedIdentifiers` or the call comes after launch has finished. Discarding
    /// that — which this did — means the app keeps running, keeps scheduling, and never wakes again:
    /// the compute it does while nobody is looking is the whole point of it, and its total loss was
    /// silent. `BackgroundIdentifierTests` pins the plist side, but a check on two strings cannot see
    /// a registration that failed for any other reason.
    ///
    /// A log rather than a crash: a foreground-usable app beats a refusal to start, which is the same
    /// trade `VerdantApp` makes for a store that will not open.
    func registerHandlers() {
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let refresh = task as? BGAppRefreshTask
                else { task.setTaskCompleted(success: false); return }
                self.handle(refresh)
            }
        }
        let enhanceRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.enhanceIdentifier, using: .main
        ) { task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask
                else { task.setTaskCompleted(success: false); return }
                self.handle(processing)
            }
        }
        for (identifier, registered) in [
            (Self.refreshIdentifier, refreshRegistered), (Self.enhanceIdentifier, enhanceRegistered)
        ] where !registered {
            Self.log.error("""
            Background task \(identifier, privacy: .public) FAILED to register — the app will never \
            wake for it. Check BGTaskSchedulerPermittedIdentifiers in Info.plist, and that this runs \
            before the app finishes launching.
            """)
        }
    }

    func scheduleAll() {
        scheduleRefresh()
        scheduleEnhancement()
    }

    func scheduleRefresh(earliest: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        submit(request)
    }

    func scheduleEnhancement(earliest: TimeInterval = 15 * 60) {
        let request = BGProcessingTaskRequest(identifier: Self.enhanceIdentifier)
        // The agent-running job runs only on external power (per product decision); within that
        // window it then uses resources liberally — many concurrent subagents, generous budget.
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        submit(request)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.log.error("Could not submit task \(request.identifier, privacy: .public)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh() // reschedule before completing
        let completion = CompletionGuard(task)
        let work = Task {
            await runCatchUp()
            completion.complete(success: !Task.isCancelled)
        }
        // Expiration is the hard backstop: cancel in-flight work and complete immediately. The
        // work task's own later completion becomes a no-op, so we never complete twice or late.
        // NOTE: the system fires this on a BACKGROUND queue (unlike the registration handler) —
        // `MainActor.assumeIsolated` here trapped in the field. Everything called is thread-safe:
        // `Task.cancel()` by design, `CompletionGuard` via its internal lock.
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }

    private func handle(_ task: BGProcessingTask) {
        scheduleEnhancement() // reschedule before completing
        let deadline = ContinuousClock.now.advanced(by: Self.enhancementBudget)
        let completion = CompletionGuard(task)
        let work = Task {
            await runEnhancement(deadline)
            completion.complete(success: !Task.isCancelled)
        }
        // Background queue — see the refresh handler's note; never assume main here.
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }
}

/// Ensures `setTaskCompleted` is called exactly once, whether the work finishes or the OS expires
/// the task first. The work task completes on the main actor while the system fires the expiration
/// handler on a background queue, so the once-latch is a `Mutex`, not actor isolation.
/// `@unchecked Sendable`: `BGTask` carries no Sendable annotation, but `setTaskCompleted` is
/// documented safe to call from any queue, and the latch guarantees exactly one call ever reaches it.
private final nonisolated class CompletionGuard: @unchecked Sendable {
    private let task: BGTask
    private let latch = OnceLatch()

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        if latch.claim() { task.setTaskCompleted(success: success) }
    }
}

/// A once-only latch: `claim()` returns `true` for exactly one caller, ever, across any number of
/// threads.
///
/// Extracted from `CompletionGuard` so it can be tested. It is small, but it is the thing standing
/// between two real crashes: `setTaskCompleted` called TWICE traps, and called NEVER gets the app
/// killed by the scheduler and its future background windows cut. Both callers race by design — the
/// work task finishes on one queue while the OS fires the expiration handler on another — and this
/// file already records a field bug in exactly that area (`MainActor.assumeIsolated` in the
/// expiration handler, which trapped).
///
/// `BGTask` itself cannot be faked, so the guard around it stays untestable; the LATCH does not have
/// to be.
final nonisolated class OnceLatch: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { alreadyClaimed in
            if alreadyClaimed { return false }
            alreadyClaimed = true
            return true
        }
    }
}
