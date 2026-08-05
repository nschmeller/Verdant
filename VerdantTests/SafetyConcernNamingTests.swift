import Foundation
import SwiftData
import Testing
@testable import Verdant

/// When a safety reviewer flags, the feed says WHICH concern.
///
/// The safety panel needs unanimity and fails closed, so one dissent among five kills a finding. That
/// is the right direction for a wellness app — but it means the panel is where good findings go to
/// die, and "· Safety reviewer 3/5: flagged" gave no way to learn which of the five fired or on what
/// grounds.
///
/// Observed, not imagined: running the whole pipeline against the real on-device model, the one
/// finding to reach this panel — "Weekend Energy Surge Tied to Resting Heart Rate Dip" — was cleared
/// by four reviewers, flagged by one, and dropped. Nothing recorded which concern had objected.
///
/// The first version of this named the LENS, on the reasoning that the lens IS the concern and is
/// already in hand — no schema field, no extra call. Measured against the real model on a
/// deliberately benign claim, that turned out to answer the wrong question: the flag read "Does it
/// overstate certainty — asserting cause and effect from what is…", which is the lens restated. It
/// says what the reviewer was ASKED, never what it found, and on prose asserting no cause at all
/// those are very different facts. Only one of them tells you whether the gate is working.
///
/// So `SafetyVerdict` gained a `why`, ordered first, exactly as `Verdict` has always done and for
/// the reason that type documents: the small model commits to its reasoning before its verdict.
/// This was the last verdict in the app without one, on the gate that runs FIRST and can end a
/// finding alone.
struct SafetyConcernNamingTests {
    private func orchestrator(_ container: ModelContainer, safe: Bool) -> Orchestrator {
        var fake = FakeSubagents()
        fake.safetyIsSafe = safe
        return Orchestrator(
            provider: MetricStatsProvider(modelContainer: container),
            writer: StoreWriter(modelContainer: container),
            embeddings: Embeddings(), subagents: fake, capability: { .available }
        )
    }

    @Test func `a flagged reviewer names the concern it was given`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let sink = ProgressSink()

        let passed = await orchestrator(container, safe: false)
            .passesSafety("Your resting heart rate dips at weekends.", progress: sink.reporter())

        #expect(!passed)
        let feed = (sink.last?.activityLog ?? []).map(\.text)
        let flagged = feed.filter { $0.contains("flagged") }
        #expect(!flagged.isEmpty, "no reviewer reported flagging")
        // Every flagged line carries the REVIEWER'S sentence, not the question it was asked.
        for line in flagged {
            #expect(
                line.contains("names a condition as the user's"),
                Comment(rawValue: "flagged without the reviewer's own reason: \(line)")
            )
            let recitesLens = Orchestrator.safetyLenses.contains { line.contains($0.prefix(30)) }
            #expect(!recitesLens, Comment(rawValue: "flagged line restates its lens: \(line)"))
        }
    }

    /// A clear reviewer stays terse — the concern is only interesting when it fired, and five lenses
    /// echoed on every safe finding would bury the feed.
    @Test func `a clear reviewer does not recite its concern`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let sink = ProgressSink()

        let passed = await orchestrator(container, safe: true)
            .passesSafety("Your steps rose this week.", progress: sink.reporter())

        #expect(passed)
        let feed = (sink.last?.activityLog ?? []).map(\.text)
        let clear = feed.filter { $0.contains(": clear") }
        #expect(!clear.isEmpty)
        for line in clear {
            #expect(line.count < 60, Comment(rawValue: "a clear line recites its lens: \(line)"))
        }
    }
}
