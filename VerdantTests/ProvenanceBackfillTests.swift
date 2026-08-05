import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The one-time re-backfill that makes provenance cover HISTORY.
///
/// `MetricRollup.sourceSignature` was added with a default of `""`, which is what makes it a
/// lightweight SwiftData migration: every existing row keeps the empty value. That is correct and
/// also useless. `ProvenanceScan` skips unknown days by design, so on any install that has already
/// ingested, the only days carrying provenance would be those arriving after the upgrade — and a
/// device swap is historical by nature, since the entire point is to explain a step from months ago.
/// The feature would be silently inert precisely where it matters, on exactly the installs that have
/// enough history to have swapped a device at all.
///
/// The fix is `resetIngestCache()`, because rollups are a pure cache of HealthKit. What these tests
/// pin is its SCOPE.
struct ProvenanceBackfillTests {
    private func seeded() async throws -> (ModelContainer, StoreWriter) {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        let now = Date()
        try await TestSupport.seed(writer, metric: .stepCount, value: 8000, daysAgo: 1...40, now: now)
        let fact = VerifiedFact(
            metric: .stepCount, comparison: .recentVsBaseline,
            recent: 12000, baseline: 8000, pctChange: 50, z: 6, n: 7,
            kind: .trend, direction: .up, magnitude: .large, salience: 60
        )
        _ = try await writer.appendInsightIfNovel(
            fact: fact, phrasing: FindingPhrasing.phrasing(for: fact), jobRunID: UUID(), now: now
        )
        try await writer.recordJournal(
            kind: .rejected, text: "a dead end", reason: "tested", jobRunID: UUID(), now: now
        )
        return (container, writer)
    }

    /// The distinction from the civil-day migration, which cleared findings, correlations AND the
    /// journal alongside the cache.
    ///
    /// That was right for that one: its rollups were WRONG, so everything derived from them was too.
    /// These rollups are right and merely lack a caveat they could have carried. Deleting a person's
    /// feed to re-derive findings that would mostly return identical is a destructive answer to a
    /// non-problem — and clearing the journal would additionally un-teach the fleet every dead end it
    /// has learned across runs.
    @Test func `the backfill drops rollups without touching what was learned from them`() async throws {
        let (container, writer) = try await seeded()
        let before = ModelContext(container)
        // Vacuity guard: the fixture must hold each thing the assertions claim survived.
        #expect(try before.fetchCount(FetchDescriptor<MetricRollup>()) > 0)
        #expect(try before.fetchCount(FetchDescriptor<InsightLog>()) == 1)
        #expect(try before.fetchCount(FetchDescriptor<ResearchJournalEntry>()) == 1)

        try await writer.resetIngestCache()

        let after = ModelContext(container)
        #expect(try after.fetchCount(FetchDescriptor<MetricRollup>()) == 0, "rollups were not rebuilt")
        #expect(try after.fetchCount(FetchDescriptor<SyncAnchor>()) == 0, "an anchor survived")
        #expect(try after.fetchCount(FetchDescriptor<InsightLog>()) == 1, "the feed was destroyed")
        #expect(
            try after.fetchCount(FetchDescriptor<ResearchJournalEntry>()) == 1,
            "cross-run memory was destroyed — the fleet would re-chase every known dead end"
        )
    }

    /// And the migration itself stays that narrow. It sits beside one that deletes three tables, in
    /// the same file, following the same shape — so the difference is a comment away from being
    /// "tidied" into a copy of its neighbour, and nothing about that edit would fail to compile.
    @Test func `the provenance migration resets the cache and deletes nothing else`() throws {
        // Searched across the whole target rather than in one named file: these migrations moved
        // into their own extension the moment `AppModel` hit the line limit, and an invariant that
        // names a file stops checking anything the next time that happens — silently.
        let body = try #require(
            SourceScan.swiftSources().compactMap { source in
                source.text.range(of: "func backfillProvenanceIfNeeded").map {
                    String(source.text[$0.lowerBound...].prefix(1200))
                }
            }.first,
            "backfillProvenanceIfNeeded is gone — was the backfill removed?"
        )
        #expect(body.contains("resetIngestCache"), "the backfill no longer rebuilds the rollups")
        for destructive in ["deleteAllInsights", "deleteAllCorrelations", "deleteJournal"] {
            #expect(
                !body.contains(destructive),
                Comment(rawValue: "the provenance backfill calls \(destructive)")
            )
        }
    }

    /// It must also actually run. It is one line in `bootstrap`, and a feature that only covers days
    /// arriving after the upgrade is the failure it exists to prevent.
    @Test func `the backfill is invoked during bootstrap`() throws {
        let sources = try SourceScan.swiftSources()
        #expect(
            sources.contains { $0.text.contains("await backfillProvenanceIfNeeded()") },
            "nothing calls the backfill — provenance would cover only days ingested from now on"
        )
    }
}

/// A one-time migration must not tick its own box on behalf of a store that is about to vanish.
///
/// Both bootstrap migrations record completion in `UserDefaults`, which outlives the session, while
/// the store they operate on may be the in-memory stand-in `VerdantApp` falls back to when the real
/// one will not open. Run against that, every step succeeds trivially — there is nothing to reset or
/// delete — the flag is set, and the REAL store skips the migration permanently, keeping the stale
/// rows and the findings built on them, with the novelty guard blocking the corrected versions the
/// migration exists to regenerate.
///
/// `runCatchUp` and `runEnhancement` have always been guarded this way. Bootstrap's migrations were
/// not, and the gap became easier to hit once `AppContainer` stopped destroying a store it merely
/// could not read: a locked launch now lands in memory rather than rebuilding.
struct EphemeralMigrationGuardTests {
    private func source() throws -> String {
        let file = try #require(
            SourceScan.swiftSources().first { $0.path == "AppModel+Migrations.swift" }
        )
        return SourceScan.code(file.text)
    }

    @Test func `both bootstrap migrations refuse to run on an ephemeral store`() throws {
        let code = try source()
        for migration in ["migrateToCivilDayBoundariesIfNeeded", "backfillProvenanceIfNeeded"] {
            let start = try #require(
                code.range(of: "func \(migration)"),
                "\(migration) is gone — was the migration removed?"
            )
            // The guard must come before any work: look only at the opening of the body.
            let opening = String(code[start.lowerBound...].prefix(400))
            #expect(
                opening.contains("guard !storeIsEphemeral else { return }"),
                Comment(rawValue: "\(migration) can mark itself done against a throwaway store")
            )
        }
    }

    /// Non-vacuity: the pattern being searched for is the one the rest of the app uses, so this is
    /// not matching a string that happens to appear anywhere.
    @Test func `the guard matches the one the run paths already use`() throws {
        let model = try #require(SourceScan.swiftSources().first { $0.path == "AppModel.swift" })
        #expect(SourceScan.code(model.text).contains("guard !storeIsEphemeral else { return }"))
    }
}

/// The app knows its findings are throwaway; the person looking at them should too.
///
/// `VerdantApp` falls back to an in-memory store when the real one will not open — most often a
/// device locked at launch, since the file is `completeUnlessOpen`. The fallback is deliberate: in
/// the foreground someone is watching, and findings for this session beat an empty screen. But
/// `storeIsEphemeral` reached the two background guards and nothing else, so the app worked visibly
/// for minutes, filled the feed, and came back next launch with nothing — which reads as lost data.
struct EphemeralNoticeTests {
    private func feedSource() throws -> String {
        let file = try #require(
            SourceScan.swiftSources().first { $0.path == "InsightFeedView.swift" }
        )
        return SourceScan.code(file.text)
    }

    @Test func `the feed surfaces the ephemeral store to the user`() throws {
        let code = try feedSource()
        #expect(
            code.contains("model.storeIsEphemeral"),
            "the feed never checks whether this session will be saved"
        )
        #expect(code.contains("ephemeralStoreNotice"), "the notice is not rendered")
    }

    /// It must say the two things a person needs: that nothing is being kept, and what to do about
    /// it. A warning that only alarms is worse than none.
    @Test func `the notice says both what happened and what to do`() throws {
        let code = try feedSource()
        #expect(code.contains("won't be saved"), "the notice does not say findings are not kept")
        #expect(code.contains("unlocked"), "the notice does not say how to fix it")
    }

    /// And it is conditional — a normal session must not carry a warning about a store that opened
    /// perfectly well.
    @Test func `the notice is shown only when the store is ephemeral`() throws {
        let code = try feedSource()
        #expect(code.contains("if model.storeIsEphemeral { ephemeralStoreNotice }"))
    }
}
