import Foundation

/// A live snapshot of a discovery run's progress. The exact same `runDiscovery` job powers the
/// background task and the user-triggered Deep Analysis; when a reporter is attached, EVERY real
/// step emits one of these — naming the specific work in flight (which pair is being tested, which
/// finding is being challenged, what was just kept or set aside) — plus a ~2-second heartbeat that
/// only advances the clock. There is deliberately NO rotating filler: `activity` always states what
/// is actually happening at that moment, and `activityLog` is the running feed of real events.
nonisolated struct AnalysisProgress: Equatable {
    enum Phase: String {
        case idle, scanning, correlating, enhancing, synthesizing, finished

        var label: String {
            switch self {
            case .idle: "Ready"
            case .scanning: "Reading your full history"
            case .correlating: "Linking signals across years"
            case .enhancing: "Reasoning about what matters"
            case .synthesizing: "Distilling the strongest findings"
            case .finished: "Analysis complete"
            }
        }
    }

    /// How many recent real events the live feed keeps.
    static let maxLogEntries = 8

    /// One real event in the live feed. The monotonic `id` gives each line a stable identity so the
    /// UI animates a clean insertion (new line in at the top, others slide down) instead of reflowing
    /// the whole list — and so repeated text (e.g. the same lens scanned across passes) never collides.
    struct LogLine: Equatable, Identifiable {
        let id: Int
        let text: String
    }

    var phase: Phase = .idle
    var note: String = ""
    /// The specific operation happening right now — set only from a real event, never cycled filler.
    var activity: String = ""
    /// Newest-first feed of the last `maxLogEntries` real events, for the live "what's happening" list.
    var activityLog: [LogLine] = []
    /// Wall-clock seconds since the run began (advanced by the heartbeat).
    var elapsedSeconds: Int = 0
    var newInsights = 0
    var candidatesTotal = 0
    var candidatesAnalyzed = 0
    var correlationsTested = 0
    var correlationsSurfaced = 0
    /// Exhaustive deep-analysis passes completed (the loop-until-dry counter).
    var passes = 0

    /// `m:ss` elapsed string for the UI.
    var elapsedText: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}
