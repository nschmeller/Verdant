import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            InsightFeedView()
                .tabItem { Label("Insights", systemImage: "sparkles") }
                .tag(RootTab.insights)
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(RootTab.trends)
            ChatView()
                .tabItem { Label("Ask", systemImage: "text.bubble") }
                .tag(RootTab.ask)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tint(Theme.brand)
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard model.didBootstrap else { return }
                Task(priority: .userInitiated) {
                    // Re-arm the permission sheet first: types left "not determined" (a dismissed
                    // sheet, or new registry rows on an existing install) fail every query until
                    // it's been shown, which would silently hollow out the run that follows.
                    await model.ensureHealthAccess()
                    if model.shouldAutoStartDeepAnalysis {
                        // The research program is the default: every return to active (re)starts it
                        // unless the user explicitly stopped it. It re-ingests first, so it covers
                        // the catch-up's job too.
                        model.startDeepAnalysis()
                    } else {
                        // The user stopped the program — keep the feed fresh with the bounded
                        // catch-up only, and hold their Stop until they start it again.
                        await model.runForegroundCatchUp()
                    }
                }
            case .background:
                // A suspended process can't reason; stop cleanly and arm the auto-resume. The
                // power-gated background task covers charging windows as before.
                model.pauseDeepAnalysisForBackground()
            default:
                break
            }
        }
    }
}
