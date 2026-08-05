import Foundation
import Synchronization
@testable import Verdant

/// Captures the last progress snapshot, so the line a person actually reads is asserted rather than
/// assumed.
///
/// A reference type because `Mutex` is noncopyable and this is captured by the reporter's escaping
/// closure — the same shape as `SubagentCallRecorder`. Shared rather than private to one suite: it
/// was, and the second suite that needed it would have copied it, which is the duplication this
/// codebase spends most of its defects on.
final class ProgressSink: Sendable {
    /// `nonisolated` throughout: the reporter emits from the run's own (off-main) task.
    private let state = Mutex<AnalysisProgress?>(nil)

    nonisolated var last: AnalysisProgress? {
        state.withLock { $0 }
    }

    nonisolated func reporter() -> ProgressReporter {
        ProgressReporter { snapshot in self.record(snapshot) }
    }

    /// Every line the run ever narrated, oldest first.
    ///
    /// `last` alone cannot answer "what happened during the run": `AnalysisProgress.activityLog`
    /// keeps only the newest `maxLogEntries` (8), which is right for a live feed and useless for a
    /// post-mortem. A seven-minute discovery run narrates dozens of lines and a test reading `last`
    /// sees the final eight — enough to know a run finished, not enough to know why it found
    /// nothing. Each `LogLine` carries a monotonic id precisely so they can be reassembled.
    private let seen = Mutex<[Int: String]>([:])

    nonisolated var everyLine: [String] {
        seen.withLock { $0.sorted { $0.key < $1.key }.map(\.value) }
    }

    private nonisolated func record(_ snapshot: AnalysisProgress) {
        state.withLock { $0 = snapshot }
        seen.withLock { store in
            for line in snapshot.activityLog {
                store[line.id] = line.text
            }
        }
    }
}
