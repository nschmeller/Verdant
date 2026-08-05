import Foundation
import OSLog

// MARK: - One-time store migrations

/// Migrations that run once at bootstrap, before the schedule and the first catch-up.
///
/// Split out of `AppModel` when it outgrew the 500-line limit, and they are the right seam: each is
/// a self-contained "has this install been fixed up yet?" check keyed on a `UserDefaults` flag, and
/// each shares the same discipline — mark complete ONLY on success, so a transient failure on a
/// just-launched (possibly still-locked) store replays next launch instead of stranding the store in
/// a half-migrated state forever.
///
/// They are `internal` rather than `private` because `bootstrap` lives in the main file, and
/// `private` is file-scoped.
extension AppModel {
    /// One-time migration for the day-boundary move from the device's local zone to a fixed UTC civil
    /// day. Rollups written under the old local-midnight keys would otherwise coexist with the new
    /// UTC-keyed rows and double-count, so clear the derived ingest cache once; the catch-up that runs
    /// next re-backfills it cleanly on the new boundaries. A fresh install no-ops (empty cache).
    func migrateToCivilDayBoundariesIfNeeded() async {
        // An ephemeral store must never mark this done. The completion flag lives in `UserDefaults`,
        // which outlives the session, while the store it just "migrated" was an empty in-memory
        // stand-in — so a single locked launch would set the flag against nothing and the REAL store
        // would skip this migration permanently, keeping its stale rows and the findings built on
        // them, with the novelty guard blocking the corrected versions this exists to regenerate.
        //
        // `runCatchUp` and `runEnhancement` have carried this guard all along; bootstrap's migrations
        // did not, and the gap got more reachable when `AppContainer` stopped destroying a store it
        // merely could not read — a locked launch now lands in memory rather than rebuilding.
        guard !storeIsEphemeral else { return }
        let key = "verdant.migration.civilDayBoundaries.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            // Mark complete ONLY on success: if any step throws (a transient SwiftData/save error on the
            // just-launched, possibly-still-locked store), leaving the flag unset makes bootstrap retry
            // next launch. Setting it regardless would permanently strand stale local-midnight rows.
            try await writer.resetIngestCache()
            // The findings built on the OLD local-midnight rollups now carry slightly-wrong numbers AND
            // would block (via the novelty guard) the corrected versions from regenerating. Clear them
            // too, so the next analysis repopulates the feed cleanly on the new boundaries. (Each step is
            // its own committed save; a failure before the flag is set just replays — every step is a
            // safe no-op once already applied.)
            try await writer.deleteAllInsights()
            try await writer.deleteAllCorrelations()
            // And the journal: its rejections steer the fleet away from re-proposing, so leaving it
            // would suppress exactly the corrected findings this migration exists to regenerate.
            try await writer.deleteJournal()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            Self.log.error("Civil-day migration reset failed; will retry next launch")
        }
    }

    /// One-time re-backfill so provenance covers HISTORY, not just days ingested from now on.
    ///
    /// `MetricRollup.sourceSignature` was added with a default of `""`, which is what makes it a
    /// lightweight SwiftData migration — every existing row simply keeps the empty value. That is
    /// correct and also useless: `ProvenanceScan` skips unknown days by design, so on any install
    /// that has already ingested, the only days with provenance would be the ones arriving after the
    /// upgrade. Device swaps are historical by nature — the whole point is to explain a step that
    /// happened months ago — so the feature would be silently inert exactly where it matters.
    ///
    /// Rollups are a pure cache of HealthKit, so dropping them is safe and the next catch-up rebuilds
    /// the full window with `.separateBySource` populated throughout.
    ///
    /// Unlike the civil-day migration this does NOT clear findings, correlations or the journal. That
    /// one had to: its rollups were WRONG, so everything built on them was too. These rollups are
    /// right and merely lack a caveat they could have carried. Deleting a user's feed to re-derive
    /// findings that would mostly come back identical is a destructive answer to a non-problem, and
    /// the standing-finding audit re-examines what is already there with the new evidence in hand.
    func backfillProvenanceIfNeeded() async {
        // Same reasoning as the migration above: a flag in `UserDefaults` must not be set on behalf
        // of a store that will not exist in a moment.
        guard !storeIsEphemeral else { return }
        let key = "verdant.migration.provenanceBackfill.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            // Same "mark only on success" discipline as above: a transient failure on a
            // just-launched store replays next launch rather than stranding the history blank.
            try await writer.resetIngestCache()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            Self.log.error("Provenance backfill reset failed; will retry next launch")
        }
    }
}
