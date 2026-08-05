import Foundation
import SwiftData
import Testing
@testable import Verdant

/// What the live feed says about reading the user's history.
///
/// Every run loaded its data with `(try? provider.dailySeries()) ?? []`, which collapses a FAILED
/// fetch and an empty store into the same value, and then reported "Read 0 metrics across your
/// logged history" — blaming the user's history for a read that may never have succeeded.
///
/// This app's rule for that feed is stated plainly elsewhere: no rotating filler, every line is
/// literally what is happening. It is also the practical difference that matters to a person. An
/// empty store fills itself on the next ingest and needs nothing from anybody; a store that cannot be
/// read does not, and is the one case worth noticing.
struct SeriesLoadHonestyTests {
    private var now: Date {
        Calendar.civil.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    @Test func `a populated store reports what was read`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 1...30, now: now)
        let loaded = await Orchestrator.loadSeries(
            MetricStatsProvider(modelContainer: container), now: now
        )
        #expect(loaded.series.count == 1)
        #expect(loaded.note.contains("Read 1 metrics"))
    }

    /// An empty store is a normal, self-correcting state and must not read as a fault.
    @Test func `an empty store says there is nothing yet, not that a read failed`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let loaded = await Orchestrator.loadSeries(
            MetricStatsProvider(modelContainer: container), now: now
        )
        #expect(loaded.series.isEmpty)
        #expect(loaded.note.contains("No logged history yet"))
        #expect(!loaded.note.lowercased().contains("couldn't"), "an empty store was reported as a failure")
    }

    /// And the two messages are genuinely different text, since the whole change is that a person can
    /// tell the cases apart.
    @Test func `the empty and failed messages are not the same sentence`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let empty = await Orchestrator.loadSeries(
            MetricStatsProvider(modelContainer: container), now: now
        )
        // The failure branch's wording, asserted from source so this test names the real string
        // rather than a copy of it that could drift.
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator.swift" }
        )
        #expect(source.text.contains("Couldn't read your stored history"))
        #expect(!empty.note.contains("Couldn't read your stored history"))
    }

    /// The feed may only claim a reason the app actually has.
    ///
    /// "Breadth exhausted for now" was announced on every drill pass. True when a dry streak was the
    /// only route to one; false since the strategy became the director's decision, which may drill on
    /// pass two with nothing dry behind it. A user watching the feed was told why, and the why was
    /// left over from an architecture that had been replaced.
    @Test func `the drill line claims breadth is exhausted only when it is`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator+DeepRun.swift" }
        )
        // Behavioural, not a source scan. The first version of this test WAS a source scan and was
        // vacuous: replacing the conditional with the unconditional claim left the parameter present
        // and the phrase appearing exactly once, so every assertion still held. A scan can see that a
        // string exists; it cannot see what guards it.
        #expect(
            Orchestrator.drillNote(title: "A finding", breadthExhausted: true)
                .contains("Breadth exhausted")
        )
        #expect(
            !Orchestrator.drillNote(title: "A finding", breadthExhausted: false)
                .contains("Breadth exhausted"),
            "the feed claims breadth is exhausted when the director simply chose to drill"
        )
        // Both still name the finding, or the line stops being useful.
        #expect(Orchestrator.drillNote(title: "A finding", breadthExhausted: false).contains("A finding"))
        // And the caller passes the flag rather than a constant.
        let code = SourceScan.code(source.text)
        let call = try #require(
            SourceScan.callSites(of: "drillIntoOwnFindings", in: code)
                .first { !$0.contains("DiscoveryContext") },
            "nothing calls the drill path"
        )
        #expect(
            call.contains("breadthExhausted: directed == nil"),
            Comment(rawValue: "the drill flag is not derived from the director's plan: \(call)")
        )
    }

    /// The wiring: both run entry points must use the loader, or the old collapsed message survives
    /// on whichever path was missed.
    /// Swept across the whole target, not the two files that happened to have the pattern.
    ///
    /// A NEGATIVE assertion scoped to named files protects those files and nothing else: a third run
    /// path added elsewhere with the collapsing expression passes in silence, which is precisely the
    /// defect this test exists to prevent returning. The earlier version named
    /// `Orchestrator.swift` and `Orchestrator+Focus.swift` because those were the two that had it.
    @Test func `no run collapses a failed read into an empty one`() throws {
        var seen = 0
        for source in try SourceScan.swiftSources() {
            let code = SourceScan.code(source.text)
            if code.contains("dailySeries") { seen += 1 }
            for line in code.components(separatedBy: .newlines)
                where line.contains("try? provider.dailySeries") || line
                .contains("try? self.provider.dailySeries")
            {
                Issue.record(
                    Comment(
                        rawValue: "\(source.path) collapses a failed read: \(line.trimmingCharacters(in: .whitespaces))"
                    )
                )
            }
        }
        // Non-vacuity: a sweep that matched no file mentioning the call would certify nothing.
        #expect(seen >= 2, "only \(seen) files mention dailySeries — did the scan break?")
    }
}
