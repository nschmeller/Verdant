import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

/// The app's four tabs, addressable so a flow can send the user somewhere (e.g. a finding's
/// "Ask about this" jumps to the Ask tab with the question staged).
enum RootTab: Hashable {
    case insights, trends, ask, settings
}

/// The composition root and the UI's source of truth. Owns the object graph (health store, store
/// writer, stats provider, embeddings, orchestrator, scheduler) and exposes the handful of intents
/// the UI calls. `@MainActor` + `@Observable` so SwiftUI observes its state directly.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer

    private let healthStore = HealthStore()
    private let embeddings = Embeddings()
    let writer: StoreWriter
    let statsProvider: MetricStatsProvider
    let ingestor: Ingestor
    /// Internal, not private: the research-program extension in
    /// `AppModel+ResearchProgram.swift` drives it. Same for `ingestor` and `deepRunTask`.
    let orchestrator: Orchestrator
    private let scheduler: BackgroundScheduler
    private var observerManager: ObserverManager?
    /// Cross-cutting lock so foreground, background, and observer runs never fan out over the store
    /// at once (see `RunGate`). Every store-mutating RUN acquires it; the one exception is the
    /// user's delete-all override (`deleteAllInsights`), which stays ungated so it can't silently
    /// no-op against a long deep run — mid-run deletion safety is handled at the write layer
    /// instead (the audit's `retire` re-fetches defensively by id and no-ops on a vanished row).
    let runGate: RunGate

    /// Internal, not private: the migration extension (`AppModel+Migrations`) logs through it, and
    /// `private` is file-scoped.
    static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "AppModel")

    // Observable UI state.
    var capability: LLMCapability = .downloading
    var healthDataAvailable = HealthStore.isHealthDataAvailable
    var isWorking = false
    /// True while at least one tracked type still needs the HealthKit permission sheet. Queries on
    /// those types throw "Authorization not determined" until the sheet has been through — surfaced
    /// in Settings so silent ingest failures have a visible, actionable cause.
    var healthAccessPending = false
    /// Live progress of the foreground catch-up — its first run backfills years of history (a
    /// multi-minute wait), so the feed's loading state narrates it instead of a static spinner.
    var catchUpProgress = AnalysisProgress()
    var didBootstrap = false
    /// Re-entrancy latch: SwiftUI can fire `.task` more than once. Set synchronously before any await in
    /// `bootstrap()` so a second call can't double-register observers or race the civil-day migration.
    private var didStartBootstrap = false

    // Deep Analysis (user-triggered, foreground) — the INDEFINITE research program: it runs for as
    // long as the app stays open, ending only via Stop or the app leaving the foreground.
    var deepProgress = AnalysisProgress()
    var isDeepAnalyzing = false
    /// The indefinite run in flight (nil when none) — held so Stop / backgrounding can cancel it.
    var deepRunTask: Task<Void, Never>?
    /// True while the program is alive but *waiting* for the model to become usable (Apple
    /// Intelligence still downloading, or switched off). It is neither running nor stopped — it will
    /// start reasoning by itself — and the UI must say so rather than claim it stopped.
    private(set) var isAwaitingModel = false

    /// Whether the research program is alive at all: reasoning now, or supervising and waiting for
    /// the model. This — not "a generation is in flight" — is what Stop acts on, so the button can't
    /// offer Start for a program that is already running and no-op the tap.
    var isProgramActive: Bool {
        deepRunTask != nil
    }

    /// The progress of whichever RESEARCH run is narrating right now — deep analysis wins over the
    /// catch-up — or `nil` when neither is running. The switch the feed, the program card and the
    /// live activity list all read, so the app's own work is never invisible: the catch-up gets the
    /// same narration as a deep analysis.
    ///
    /// Not the only such switch: the Ask tab narrates its own question through `askProgress`.
    /// Deliberately separate — a question is the user's work, not the program's, and folding it in
    /// here would make the Insights feed claim the research program was running whenever someone
    /// typed in the chat.
    var activeProgress: AnalysisProgress? {
        if isDeepAnalyzing { return deepProgress }
        if isWorking { return catchUpProgress }
        return nil
    }

    /// Cross-tab navigation: which tab is showing, and a question staged for the Ask tab (a
    /// finding's "Ask about this" sets both; ChatView consumes the question on arrival).
    var selectedTab: RootTab = .insights
    var pendingQuestion: String?

    /// True when the on-disk store could not be opened and an in-memory one was substituted.
    ///
    /// That substitution is right for a FOREGROUND launch — the app stays usable for the session
    /// rather than refusing to start. It is actively wrong for a BACKGROUND one. The most likely
    /// cause of the failure is exactly the background case: the store is written with
    /// `.completeUnlessOpen`, so a new handle cannot be opened while the device is locked, and a
    /// `BGProcessingTask` on a charging phone at 3am launches a fresh process into precisely that
    /// state. Running the pass anyway would reason over an EMPTY history and write its findings, its
    /// journal and its HealthKit anchors into a store that evaporates when the task ends — a whole
    /// granted window spent producing nothing, with no error anywhere.
    let storeIsEphemeral: Bool

    init(container: ModelContainer, storeIsEphemeral: Bool = false) {
        self.container = container
        self.storeIsEphemeral = storeIsEphemeral
        let writer = StoreWriter(modelContainer: container)
        let statsProvider = MetricStatsProvider(modelContainer: container)
        let embeddings = embeddings
        self.writer = writer
        self.statsProvider = statsProvider

        let runGate = RunGate()
        self.runGate = runGate

        let ingestor = Ingestor(healthStore: healthStore, writer: writer)
        self.ingestor = ingestor

        let subagents = Subagents(provider: statsProvider, writer: writer, embeddings: embeddings)
        let orchestrator = Orchestrator(
            provider: statsProvider,
            writer: writer,
            embeddings: embeddings,
            subagents: subagents,
            // The deep run's collection loop: at every substrate-refresh boundary it pulls the
            // HealthKit deltas that arrived while it was reasoning (observer ingests skip while the
            // run holds the gate, so without this the refresh would re-read unchanged rollups) and
            // deepens any still-shallow history. Safe under the gate: the deep run itself holds it,
            // same as the ingest it already runs up front.
            collector: { progress in
                await ingestor.ingestAll(progress: progress)
                await ingestor.deepenHistory(progress: progress)
            }
        )
        self.orchestrator = orchestrator

        scheduler = BackgroundScheduler(
            // Background refresh (any power): ingest HealthKit deltas only, so the next foreground or
            // on-power run starts from fresh rollups. No findings are produced off-power — every
            // finding needs the model, and the agents run only while charging. Gated like every other
            // run so it never ingests concurrently with a foreground pass.
            runCatchUp: { [storeIsEphemeral] in
                // Nothing written here would survive the task — see `storeIsEphemeral`. Yielding the
                // window immediately lets the system reschedule for a moment when the store is
                // openable, which is strictly better than burning it on a store we will discard.
                guard !storeIsEphemeral else { return }
                guard await runGate.tryAcquire() else { return }
                defer { Task { await runGate.release() } }
                BackgroundRunDiagnostics.stampRefresh() // visible proof the OS granted this window
                await ingestor.ingestAll()
            },
            // Power-gated processing task: the full agent-running discovery job. The gate is what stops
            // it overlapping a foreground catch-up / Deep Analysis the user starts while it's in flight.
            runEnhancement: { [storeIsEphemeral] deadline in
                // Same reasoning as the refresh arm, and it matters more here: this is the pass that
                // spends the whole on-power window running agents. Every finding it produced would be
                // thrown away with the store.
                guard !storeIsEphemeral else { return }
                guard await runGate.tryAcquire() else { return }
                defer { Task { await runGate.release() } }
                BackgroundRunDiagnostics.stampEnhance() // visible proof the on-power window fired
                await ingestor.ingestAll()
                await orchestrator.runDiscovery(deadline: deadline)
            }
        )
    }

    /// Must run before the app finishes launching (BGTaskScheduler requirement).
    func registerBackgroundHandlers() {
        scheduler.registerHandlers()
    }

    /// First-launch / each-launch setup: authorization, observers, scheduling, foreground catch-up.
    func bootstrap() async {
        // Guard-and-set before the first `await` (atomic on the main actor) so a re-fired `.task` no-ops.
        guard !didStartBootstrap else { return }
        didStartBootstrap = true
        capability = LLMCapability.current
        healthDataAvailable = HealthStore.isHealthDataAvailable
        guard healthDataAvailable else { didBootstrap = true; return }

        await ensureHealthAccess()

        await migrateToCivilDayBoundariesIfNeeded()
        await backfillProvenanceIfNeeded()
        scheduler.scheduleAll()
        // Run the catch-up (which, on first launch, backfills years of history) BEFORE registering
        // observers. Otherwise an observer firing mid-backfill would kick off a second concurrent
        // full-history ingest for the same metric (anchor still nil) — idempotent, but it doubles the
        // single most expensive operation in the app's lifetime. After the catch-up has saved each
        // metric's anchor, observer-triggered ingests take the cheap incremental path.
        await runForegroundCatchUp()

        let observer = ObserverManager(
            healthStore: healthStore, ingestor: ingestor, runGate: runGate
        ) { [weak self] in
            await self?.onObservedNewData()
        }
        observerManager = observer
        await observer.startObserving()

        // The WAL/SHM sidecars exist only after the first write; protect them now.
        AppContainer.reapplyProtections()
        didBootstrap = true

        // The research program is the DEFAULT, not a button: launch it now and let it run for as
        // long as the app stays open. The awaited catch-up above already banked fast first findings
        // and saved every anchor, so the program's own ingest pass is a cheap incremental one; its
        // polite gate-wait means the ordering here can never race it.
        startDeepAnalysis()
    }

    /// Make sure every tracked type has been through the permission sheet. The old one-shot
    /// `try?` at bootstrap silently stranded types as "authorization not determined" whenever the
    /// sheet couldn't present (or new registry rows appeared on an existing install) — every query
    /// on them then failed forever. Now: ask HealthKit whether a request is still NEEDED, request if
    /// so, log failures loudly, and re-check on every foregrounding until the sheet has been shown.
    func ensureHealthAccess() async {
        // One flow at a time: presenting the Health sheet bounces the scene through
        // inactive → active, and the `.active` handler calls this again — a SECOND concurrent
        // requestAuthorization tears the first sheet down (in the field: a white page that pops up
        // and immediately disappears). Set synchronously before the first await, so the re-entrant
        // call is a no-op instead of a sheet-killer.
        guard healthDataAvailable, !ensuringHealthAccess else { return }
        ensuringHealthAccess = true
        defer { ensuringHealthAccess = false }
        guard await healthStore.needsAuthorizationRequest() else {
            healthAccessPending = false
            return
        }
        do {
            try await healthStore.requestAuthorization()
        } catch {
            Self.log.error("""
            Health authorization request failed: \(error.localizedDescription, privacy: .public)
            """)
        }
        // Re-check rather than trusting the call: a dismissed or unpresentable sheet leaves types
        // undetermined even when `requestAuthorization` returned without throwing.
        healthAccessPending = await healthStore.needsAuthorizationRequest()
    }

    /// Re-entrancy latch for `ensureHealthAccess` — see its comment; overlapping authorization
    /// requests are what killed the permission sheet mid-presentation.
    private var ensuringHealthAccess = false

    /// Drain HealthKit deltas and run a full discovery pass in the foreground, where LLM inference
    /// is not background-rate-limited. This is the primary correctness guarantee for users whose
    /// devices never get a background window.
    func runForegroundCatchUp() async {
        // The run gate makes this mutually exclusive with EVERY other store-mutating run — a deep
        // analysis, a background pass, or an observer ingest — not just other foreground runs.
        // Overlapping passes double the work (especially the first-launch backfill) and let one run's
        // curation tombstone another's findings.
        guard await runGate.tryAcquire() else { return }
        defer { Task { await runGate.release() } }
        isWorking = true
        // `defer` so a thrown/cancelled await can't strand `isWorking == true` (the UI's loading flag).
        defer { isWorking = false }
        catchUpProgress = AnalysisProgress(phase: .scanning)
        let ingestor = ingestor
        let orchestrator = orchestrator
        await narrate(
            into: { [weak self] in self?.catchUpProgress = $0 },
            job: { reporter in
                orchestrator.prewarm() // warm across the ingest — see runDeepAnalysis
                await ingestor.ingestAll(progress: reporter)
                await orchestrator.runDiscovery(exhaustive: false, progress: reporter)
            }
        )
        capability = LLMCapability.current
    }

    /// Start the INDEFINITE deep analysis: it reasons for as long as the app stays open, and stays
    /// stopped only while the user has explicitly stopped it. Starting (by tap or auto-start)
    /// clears that latch.
    func startDeepAnalysis() {
        guard deepRunTask == nil else { return }
        userStoppedDeepAnalysis = false
        // `.userInitiated` so the OS gives the reasoning work high scheduling priority — the goal is
        // the on-device compute at full capacity, not deferred behind lower-QoS work.
        deepRunTask = Task(priority: .userInitiated) { [weak self] in
            await self?.superviseResearchProgram()
            self?.deepRunTask = nil
        }
    }

    /// How long to wait before re-checking whether the model became usable. Short, because every
    /// second spent waiting is a second the device is not reasoning; cheap, because the check is a
    /// single `SystemLanguageModel.availability` read.
    private static let programRetryInterval = Duration.seconds(20)

    /// Keeps the research program alive for as long as the app is open — the program is the app's
    /// DEFAULT state, not a button, so a run that ends on its own must not leave the device idle for
    /// the rest of the session.
    ///
    /// The failure this exists to fix: on a first launch Apple Intelligence is very often still
    /// **downloading**. `runDiscovery` correctly refuses to run without a model, so the program
    /// returned within milliseconds, `deepRunTask` cleared, and nothing ever restarted it — the app
    /// then sat idle until the user happened to background and foreground it, which was the only
    /// restart path. The whole point of the app is to keep the Neural Engine working, so "the model
    /// wasn't ready yet" must cost a short wait, not the entire session.
    ///
    /// The deep run itself is indefinite (it ends only by cancellation), so ANY plain return means
    /// it could not reason or hit its runaway backstop — both are worth retrying. Only an explicit
    /// Stop, backgrounding (both cancel this task), or hardware that can never run the model ends
    /// the supervision.
    private func superviseResearchProgram() async {
        defer { isAwaitingModel = false }
        while !Task.isCancelled {
            capability = LLMCapability.current // also refreshes the UI's availability banner
            switch Self.nextProgramStep(
                capability: capability,
                userStopped: userStoppedDeepAnalysis,
                healthDataAvailable: healthDataAvailable
            ) {
            case .end:
                return
            case .run:
                isAwaitingModel = false
                await runDeepAnalysis()
            case .waitForModel:
                // Honest about why nothing is happening, and that it resumes by itself.
                isAwaitingModel = true
                deepProgress.phase = .finished
                deepProgress.note = capability == .downloading
                    ? "Waiting for Apple Intelligence to finish downloading — research starts on its own."
                    : "Waiting for Apple Intelligence to be turned on — research starts on its own."
            }
            guard !Task.isCancelled, !userStoppedDeepAnalysis else { return }
            try? await Task.sleep(for: Self.programRetryInterval)
        }
    }

    /// User-requested stop: cancel the research program and HOLD it stopped — the auto-start must
    /// not overrule an explicit Stop until the user starts it again (or relaunches the app).
    /// Everything already surfaced is saved.
    func stopDeepAnalysis() {
        userStoppedDeepAnalysis = true
        deepRunTask?.cancel()
    }

    /// The app is leaving the foreground: stop the run cleanly (a suspended process can't reason
    /// anyway; the power-gated background task covers charging windows). No resume flag needed —
    /// the research program is the DEFAULT, so returning to active auto-starts it unless the user
    /// explicitly stopped it.
    func pauseDeepAnalysisForBackground() {
        deepRunTask?.cancel()
    }

    /// Whether foregrounding should (re)start the research program: always, unless the user
    /// explicitly stopped it this session. This is what makes "works for as long as the app is
    /// open" the app's default behavior rather than a button.
    var shouldAutoStartDeepAnalysis: Bool {
        !userStoppedDeepAnalysis && healthDataAvailable
    }

    /// The explicit-Stop latch — the ONE thing that keeps the app from auto-starting the research
    /// program. Backgrounding never sets it; the Stop button does; Start (tap or auto) clears it.
    private var userStoppedDeepAnalysis = false

    /// Politely wait for the run gate instead of silently dying — the holder may be an hourly
    /// observer ingest, the launch catch-up, or a just-interrupted run winding down, all brief.
    /// "The program runs while the app is open" must not be lost to that race. Returns `false`
    /// only if cancelled while waiting.
    func acquireRunGateWaiting() async -> Bool {
        while !Task.isCancelled {
            if await runGate.tryAcquire() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// The indefinite ingest → discover research program, narrated into `deepProgress`.
    private func runDeepAnalysis() async {
        // Gated against EVERY other store-mutating run (background pass, catch-up, observer ingest),
        // not just other foreground runs — see RunGate. Waiting is invisible (the gate holder's own
        // progress is what the UI shows), and cancellation ends the wait like it ends the run.
        guard await acquireRunGateWaiting() else { return }
        defer { Task { await runGate.release() } }
        isDeepAnalyzing = true
        // `defer` so a thrown/cancelled await can't strand the flag true, which would pin the UI on
        // "Analyzing…" for the rest of the session.
        defer { isDeepAnalyzing = false }
        // Keep the screen awake: auto-lock backgrounds the app within minutes, which would quietly
        // end every "indefinite" run. Restored on EVERY exit path by the defer.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        deepProgress = AnalysisProgress(phase: .scanning, note: "Starting…")
        let ingestor = ingestor
        let orchestrator = orchestrator
        await narrate(
            into: { [weak self] in self?.deepProgress = $0 },
            job: { reporter in
                // Load the model across the ingest below, not after it: on a first run that ingest
                // is minutes of model-free work, and `runDiscovery`'s own prewarm fires only once
                // it's done — so the first generation would pay a cold load at precisely the moment
                // reasoning starts.
                orchestrator.prewarm()
                // The incremental ingest DOES gate reasoning: pass one needs today's rollups.
                await ingestor.ingestAll(progress: reporter)
                // Deepening does NOT. It backfills OLDER history — minutes of pure I/O on a first
                // run — and reasoning can proceed over what already exists while it lands; the
                // deep run's next substrate refresh folds the recovered years in. Running it before
                // the first generation was the last multi-minute stretch of the app's own lifetime
                // with the Neural Engine deliberately idle.
                let deepening = Task { await ingestor.deepenHistory(progress: reporter) }
                await orchestrator.runDiscovery(exhaustive: true, progress: reporter)
                // Join before returning: the run holds the gate, and releasing it with a backfill
                // still writing would let the next run interleave with it. Cancellation is
                // forwarded, because `Task.value` ignores the awaiting task's own cancellation —
                // otherwise Stop would block on the very backfill it is trying to end.
                await withTaskCancellationHandler {
                    _ = await deepening.value
                } onCancel: {
                    deepening.cancel()
                }
            }
        )
        if Task.isCancelled {
            deepProgress.phase = .finished
            deepProgress.note = "Stopped — everything found so far is saved."
        }
        capability = LLMCapability.current
    }

    /// Live narration of the ASK tab's work — separate from `activeProgress` (the research
    /// program's), non-nil only while a question is in flight. A question costs two model passes
    /// plus a safety panel: too long to show a bare spinner in an app built on watching it reason.
    var askProgress: AnalysisProgress?

    /// Recent daily values for one metric — the data behind sparklines and correlation charts.
    func series(for metric: MetricKey, days: Int = 30) async -> [DailyPoint] {
        await (try? statsProvider.recentSeries(for: metric, days: days)) ?? []
    }

    func deleteAllInsights() async {
        do {
            try await writer.deleteAllInsights()
            try await writer.deleteAllCorrelations()
            // The research journal too — it IS "its memory of what it's already shown you", and its
            // rejections steer the fleet away from re-proposing anything it once dropped. Keeping it
            // would leave the user's clean slate haunted by the old one.
            try await writer.deleteJournal()
        } catch {
            Self.log.error("Delete-all failed")
        }
    }

    /// HealthKit observed new data while we were running: top up the background schedule.
    private func onObservedNewData() {
        scheduler.scheduleEnhancement()
    }
}
