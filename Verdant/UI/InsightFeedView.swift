import SwiftData
import SwiftUI

/// The insight feed. Reads the store directly via `@Query`; the deterministic engine + LLM
/// enhancement write to it on the background `StoreWriter`, and the UI refreshes as rows land.
struct InsightFeedView: View {
    @Environment(AppModel.self) private var model
    @Query(
        filter: #Predicate<InsightLog> { $0.tombstoned == false },
        sort: \InsightLog.createdAt,
        order: .reverse
    )
    private var insights: [InsightLog]
    @Query(
        filter: #Predicate<CorrelationLog> { $0.tombstoned == false },
        sort: \CorrelationLog.createdAt,
        order: .reverse
    )
    private var correlations: [CorrelationLog]

    /// A finding in the unified feed — either a single-metric insight or a cross-source correlation.
    private enum FeedItem: Identifiable {
        case insight(InsightLog)
        case correlation(CorrelationLog)

        var id: String {
            switch self {
            case let .insight(insight): "i-\(insight.id)"
            case let .correlation(correlation): "c-\(correlation.id)"
            }
        }

        var createdAt: Date {
            switch self {
            case let .insight(insight): insight.createdAt
            case let .correlation(correlation): correlation.createdAt
            }
        }

        var quality: Int {
            switch self {
            case let .insight(insight): insight.salience
            case let .correlation(correlation): correlation.quality
            }
        }

        /// Promoted by the curator agent — see `InsightFeedView.pinned`.
        var highlighted: Bool {
            switch self {
            case let .insight(insight): insight.highlighted
            case let .correlation(correlation): correlation.highlighted
            }
        }

        var detail: FindingDetailView.Finding {
            switch self {
            case let .insight(insight): .insight(insight)
            case let .correlation(correlation): .correlation(correlation)
            }
        }
    }

    private var feed: [FeedItem] {
        (insights.map(FeedItem.insight) + correlations.map(FeedItem.correlation))
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The findings the CURATOR agent promoted, so the best insight is never buried by something
    /// newer-but-weaker. This used to be `quality >= 60`, a top-3 slice, and a "only once there are
    /// 5 findings" rule — three deterministic worth-judgments living in the view. Worth is the
    /// agent's call everywhere else in the app; it is here too now. An uncurated feed (or a curator
    /// that found nothing standout) simply has no highlights.
    private var pinned: [FeedItem] {
        feed.filter(\.highlighted)
    }

    private var stream: [FeedItem] {
        let pinnedIDs = Set(pinned.map(\.id))
        return feed.filter { !pinnedIDs.contains($0.id) } // feed is already recency-sorted
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    AvailabilityBanner(capability: model.capability)
                    // The research program's live status lives HERE — analysis is the app's default
                    // state (auto-started, indefinite), so the feed carries everything: status,
                    // counts, compute, and the live activity below. No separate screen, no manual
                    // trigger. Hidden only when the model can't run at all (the banner explains).
                    if model.capability.isAvailable, model.healthDataAvailable {
                        programCard
                        if programRunning {
                            statsRow
                            ResourceMeterView().card()
                        }
                    }
                    if model.storeIsEphemeral { ephemeralStoreNotice }
                    if let live = model.activeProgress, !live.activityLog.isEmpty, !feed.isEmpty {
                        LiveActivityFeed(entries: live.activityLog)
                            .animation(.smooth, value: live)
                    }
                    if feed.isEmpty {
                        emptyState
                    } else {
                        if !pinned.isEmpty {
                            sectionHeader("Worth your attention", systemImage: "star.fill")
                            ForEach(pinned) { row($0) }
                            // Only head a section that has something in it. The old
                            // `feed.count >= 5` gate made this unreachable by accident; with
                            // highlighting now a curator decision, a feed of three findings the
                            // curator promotes in full leaves nothing below — and a dangling
                            // "More findings" header reads like the app lost them.
                            if !stream.isEmpty {
                                sectionHeader("More findings", systemImage: "clock")
                            }
                        }
                        ForEach(stream) { row($0) }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Insights")
            .safeAreaInset(edge: .bottom) { DisclaimerBar() }
        }
        .tint(Theme.brand)
    }

    // MARK: The research program (always-on)

    private var programRunning: Bool {
        model.isDeepAnalyzing || model.isWorking
    }

    /// Whichever run is narrating right now, else the last deep run's record — the card never goes
    /// blank the moment a run ends.
    private var programProgress: AnalysisProgress {
        model.activeProgress ?? model.deepProgress
    }

    private var programTitle: String {
        Self.programTitle(
            isDeepAnalyzing: model.isDeepAnalyzing,
            isWorking: model.isWorking,
            isAwaitingModel: model.isAwaitingModel,
            phase: model.activeProgress?.phase
        )
    }

    /// The headline over the live card, as a pure function so it can be tested.
    ///
    /// It used to answer `isWorking` with a flat "Catching up…". That flag covers the whole
    /// foreground job — the HealthKit catch-up AND the discovery run that follows it — so the
    /// headline kept saying "Catching up…" for minutes while the line directly beneath it read
    /// "Investigator 3/13: VOLATILITY shifts". Two statements about the same moment, one of them
    /// describing work that finished long before. Seen on a real run, not reasoned about: the app
    /// was reasoning at 100% duty cycle under a banner saying it was still fetching data.
    ///
    /// `AnalysisProgress.Phase` already carries the honest label, so the headline now defers to it
    /// whenever a run is narrating. "Catching up…" survives for exactly what it describes: the
    /// stretch before any phase has been reported.
    /// What an empty feed says, and why it says how many candidates were examined.
    ///
    /// "Nothing stands out yet" is accurate for a new install with little data, and for someone with
    /// years backfilled it reads as "your health data is unremarkable". Those are very different
    /// facts and the app knows which one it is looking at: a full run measured on 2026-08-03 proposed
    /// eleven findings and its own panels rejected every one. Telling that person their data holds
    /// nothing notable, when eleven candidates were found and argued over, is the same failure this
    /// codebase corrects everywhere else — a clean bill claimed for a pass that was anything but.
    ///
    /// The count comes from the last run's snapshot (`deepProgress` outlives the run), and is
    /// mentioned only when it is non-zero, so a first launch is not told "0 candidates examined".
    static func nothingFoundCopy(isDeepAnalyzing: Bool, candidatesVetted: Int) -> String {
        let bar = "Verdant shows only a handful of genuinely standout findings"
        if isDeepAnalyzing {
            return "\(bar). The research program is digging now — anything that clears the bar "
                + "appears here."
        }
        guard candidatesVetted > 0 else {
            return "\(bar), and none have cleared that bar yet. The research program keeps digging "
                + "automatically whenever Verdant is open."
        }
        let candidates = candidatesVetted == 1 ? "1 candidate" : "\(candidatesVetted) candidates"
        return "\(bar). The last pass examined \(candidates) and none cleared the bar. The research "
            + "program keeps digging automatically whenever Verdant is open."
    }

    static func programTitle(
        isDeepAnalyzing: Bool,
        isWorking: Bool,
        isAwaitingModel: Bool,
        phase: AnalysisProgress.Phase?
    ) -> String {
        if isDeepAnalyzing { return "Research program running" }
        if isWorking {
            guard let phase, phase != .idle else { return "Catching up…" }
            return phase.label
        }
        // Alive but waiting on the model is NOT stopped — it restarts itself, and saying "stopped"
        // would invite the user to tap Start on something already running.
        if isAwaitingModel { return "Research program waiting" }
        return "Research program stopped"
    }

    /// The flowing line: the real operation in flight while running; the closing note (or the
    /// standing promise) when stopped.
    private var programStatusLine: String {
        if programRunning {
            let progress = programProgress
            return progress.activity.isEmpty ? progress.phase.label : progress.activity
        }
        let note = programProgress.note
        return note.isEmpty
            ? "Runs automatically while Verdant is open — entirely on your device."
            : note
    }

    private var programCard: some View {
        let progress = programProgress
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 44, height: 44)
                if programRunning {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "infinity")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(programTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(programStatusLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                if programRunning {
                    Text("\(progress.elapsedText) elapsed"
                        + (progress.passes > 0 ? " · pass \(progress.passes)" : ""))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
            // Stop holds until the user starts it again; Start also queues politely behind a
            // catch-up (the run gate), so the button is never a silent no-op.
            Button {
                if model.isProgramActive {
                    model.stopDeepAnalysis()
                } else {
                    model.startDeepAnalysis()
                }
            } label: {
                Image(systemName: model.isProgramActive ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isProgramActive ? "Stop analysis" : "Start analysis")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.gradient,
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .animation(.smooth, value: progress)
        .padding(.top, 4)
    }

    private var statsRow: some View {
        let progress = programProgress
        return HStack(spacing: 10) {
            StatChip(value: "\(progress.newInsights)", label: "New findings", emphasized: true)
            StatChip(value: "\(progress.correlationsSurfaced)", label: "Cross-signal links")
            StatChip(value: "\(progress.correlationsTested)", label: "Relationships tested")
        }
    }

    private func row(_ item: FeedItem) -> some View {
        // Tap a card to open its full detail. `.plain` keeps the card's look (no tint/chevron); the
        // whole card is the tap target.
        NavigationLink {
            FindingDetailView(finding: item.detail)
        } label: {
            rowCard(item)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowCard(_ item: FeedItem) -> some View {
        switch item {
        case let .insight(insight): InsightRow(insight: insight)
        case let .correlation(correlation): CorrelationRow(correlation: correlation)
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.brandDeep)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    /// Says out loud that this session's findings will not survive it.
    ///
    /// `VerdantApp` falls back to an in-memory store when the real one will not open — most often
    /// because the device was locked at launch, since the file is `completeUnlessOpen`. The fallback
    /// is deliberate and right: in the foreground the person is looking at the app, and findings for
    /// this session beat an empty screen. What was missing is that they were never told.
    ///
    /// Without this, the app works visibly for minutes, fills the feed, and comes back next launch
    /// with nothing — which reads as lost data rather than a store that could not be opened. The app
    /// knew the whole time; `storeIsEphemeral` reached the two background guards and nothing else.
    private var ephemeralStoreNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("This session won't be saved")
                    .font(.footnote.weight(.semibold))
                Text(
                    "Verdant couldn't open its store — usually because the iPhone was locked when it "
                        + "started. Anything it finds now is shown but not kept. Reopen Verdant once "
                        + "the phone is unlocked and it will pick up where it left off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    @ViewBuilder
    private var emptyState: some View {
        // Covers the catch-up AND a deep analysis: whichever is narrating, an empty feed shows its
        // live activity instead of a bare spinner.
        if let live = model.activeProgress {
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("Analyzing your health data", systemImage: "sparkles")
                } description: {
                    // Phase-accurate: "Reading your full history" during the (slow) backfill, then
                    // "Linking signals across years", etc. — never "Reasoning…" before reasoning starts.
                    Text(live.phase.label)
                }
                // The first launch backfills years of history and reasons over it — a multi-minute
                // wait — so show the same live event feed as Deep Analysis rather than a bare spinner.
                if !live.activityLog.isEmpty {
                    LiveActivityFeed(entries: live.activityLog)
                        .animation(.smooth, value: live)
                }
            }
            .padding(.top, 40)
        } else if !model.healthDataAvailable {
            ContentUnavailableView(
                "Health data unavailable",
                systemImage: "heart.slash",
                description: Text("This device doesn't provide Health data.")
            )
            .padding(.top, 40)
        } else {
            capabilityEmptyState
                .padding(.top, 40)
        }
    }

    /// Exhaustive over `LLMCapability`, not an equality chain ending in `else`.
    ///
    /// Each state gets copy written for it, and `.available` is named rather than inherited: with a
    /// trailing `else`, a capability case added later would silently show "Nothing stands out yet" —
    /// telling someone whose model is, say, mid-update that their data is unremarkable. The compiler
    /// now makes that impossible, the same way `FindingPresentation` does for finding kinds.
    @ViewBuilder
    private var capabilityEmptyState: some View {
        switch model.capability {
        case .notEnabled:
            ContentUnavailableView(
                "Turn on Apple Intelligence",
                systemImage: "wand.and.stars",
                description: Text(
                    "Verdant's insights are written by Apple Intelligence on your device. "
                        + "Turn it on in Settings → Apple Intelligence & Siri to unlock them."
                )
            )
        case .unavailableForever:
            ContentUnavailableView(
                "On-device intelligence required",
                systemImage: "cpu",
                description: Text(
                    "Verdant's insights are written by Apple Intelligence on your device, which "
                        + "this iPhone can't run. They'll appear on a device that supports it."
                )
            )
        case .downloading:
            ContentUnavailableView {
                Label("Preparing on-device intelligence", systemImage: "arrow.down.circle")
            } description: {
                Text("Insights will appear once the on-device model finishes downloading.")
            }
        case .available:
            ContentUnavailableView {
                Label("Nothing stands out yet", systemImage: "leaf.fill")
            } description: {
                Text(Self.nothingFoundCopy(
                    isDeepAnalyzing: model.isDeepAnalyzing,
                    candidatesVetted: programProgress.candidatesAnalyzed
                ))
            }
        }
    }
}
