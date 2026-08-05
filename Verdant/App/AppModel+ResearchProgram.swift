import Foundation

// MARK: - The research program's state machine

/// Extracted from `AppModel` so the decision that keeps the Neural Engine working — the app's whole
/// purpose — is a pure function with no HealthKit, no model container, and no real
/// `SystemLanguageModel` behind it. `ResearchProgramSupervisorTests` pins every branch.
extension AppModel {
    /// What the supervisor does on one tick.
    enum ProgramStep: Equatable {
        /// Reason now — the model is usable.
        case run
        /// Nothing to do yet, but it will resolve itself: keep the program alive and re-check.
        case waitForModel
        /// Stop supervising for good — the user said so, or no amount of waiting will help.
        case end
    }

    /// The supervisor's whole decision, as a pure function. Extracted so the state machine that
    /// keeps the Neural Engine working — the app's entire purpose — is pinned by tests without
    /// standing up HealthKit, a model container, and a real `SystemLanguageModel`. The distinction
    /// that matters and is easy to get wrong: `downloading` and `notEnabled` RESOLVE (so wait,
    /// which is the bug this supervisor exists to fix), while `unavailableForever` never will (so
    /// stop, rather than poll this device forever).
    static func nextProgramStep(
        capability: LLMCapability,
        userStopped: Bool,
        healthDataAvailable: Bool
    ) -> ProgramStep {
        guard !userStopped, healthDataAvailable else { return .end }
        if capability.isAvailable { return .run }
        return capability == .unavailableForever ? .end : .waitForModel
    }

    /// A user-requested drill-down on one finding ("investigate this further"): the same agentic
    /// machinery as a deep analysis, but every investigator lens is anchored on the tapped finding's
    /// metric(s). The drill-down OUTRANKS the always-on research program — it interrupts it, digs,
    /// and the program then resumes on its own. Narrates into `deepProgress`, so the Insights
    /// feed's program card and live activity show it exactly like any other run.
    func investigateFurther(focus: InvestigationFocus) async {
        let resumeProgramAfter = deepRunTask != nil
        deepRunTask?.cancel()
        guard await acquireRunGateWaiting() else { return }
        defer { Task { await runGate.release() } }
        defer { if resumeProgramAfter, !Task.isCancelled { startDeepAnalysis() } }
        isDeepAnalyzing = true
        defer { isDeepAnalyzing = false }
        deepProgress = AnalysisProgress(phase: .scanning, note: "Digging into “\(focus.title)”…")
        let orchestrator = orchestrator
        await narrate(
            into: { [weak self] in self?.deepProgress = $0 },
            job: { reporter in
                await orchestrator.runFocusedDiscovery(focus: focus, progress: reporter)
            }
        )
    }

    /// Run one narrated job with ordered progress delivery and STRUCTURED cancellation: the
    /// caller's task cancellation reaches the job's awaits directly, and this returns only after
    /// the job has genuinely stopped. That last property is what lets Stop / backgrounding end an
    /// indefinite run safely — the run gate is released only when the work is truly done, so a
    /// catch-up can never overlap a still-winding-down deep run. (The old AsyncStream version
    /// released the gate as soon as the *consumer* was cancelled, while the detached work task was
    /// still running.) Delivery order is preserved by the single serial stream between the reporter
    /// and the main-actor consumer.
    func narrate<Result>(
        into apply: @escaping @MainActor (AnalysisProgress) -> Void,
        job: (ProgressReporter) async -> Result
    ) async -> Result {
        let (stream, continuation) = AsyncStream.makeStream(of: AnalysisProgress.self)
        let reporter = ProgressReporter { continuation.yield($0) }
        // Unstructured on purpose: the consumer must keep draining (and deliver the final
        // "finished/stopped" snapshot) even after the surrounding task is cancelled.
        let consumer = Task { for await snapshot in stream {
            apply(snapshot)
        } }
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await reporter.tick()
            }
        }
        defer { heartbeat.cancel() }
        let result = await job(reporter)
        continuation.finish()
        await consumer.value
        return result
    }

    /// `history` is the Ask screen's earlier exchanges, so a follow-up has something to refer to.
    func ask(_ question: String, history: [ConversationTurn] = []) async -> String {
        let orchestrator = orchestrator
        askProgress = AnalysisProgress(phase: .scanning)
        defer { askProgress = nil }
        return await narrate(
            into: { [weak self] in self?.askProgress = $0 },
            job: { reporter in
                await orchestrator.answer(
                    question: question, history: history, progress: reporter
                )
            }
        )
    }
}
