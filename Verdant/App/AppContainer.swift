import Foundation
import OSLog
import SwiftData

/// Builds the one local-only, encrypted `ModelContainer` shared by the UI (main context) and
/// the background `StoreWriter` (`@ModelActor`).
///
/// Zero-cloud is enforced here with `cloudKitDatabase: .none` — SwiftData otherwise defaults to
/// CloudKit sync. At-rest protection defaults to `.completeUnlessOpen` (HealthKit's own model):
/// the derived-insight DB is unreadable while the device is locked after first unlock, which
/// scopes heavy background work to unlocked windows — an acceptable cost given that the foreground
/// catch-up (which runs the full reasoning pass on launch) is the primary correctness guarantee.
/// (See ARCHITECTURE.md §8.)
nonisolated enum AppContainer {
    static let storeFileName = "Verdant.store"
    private static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "AppContainer")

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)

        if inMemory {
            // `.none` here too, not just on the on-disk path. This is a PRODUCTION path — `VerdantApp`
            // falls back to an in-memory store when the real one will not open — and it was the one
            // configuration in the app whose `cloudKitDatabase` read `.automatic`. Harmless in fact,
            // because CloudKit needs an entitlement the app does not claim, but that entitlement is
            // documented as the backstop for exactly this mistake rather than the primary defence.
            //
            // Found by reading the setting off a built container instead of grepping the source for
            // the string, which is what the scan asserting this opt-out had been doing.
            let config = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
            )
            return try ModelContainer(
                for: schema,
                migrationPlan: VerdantMigrationPlan.self,
                configurations: config
            )
        }

        let url = try storeURL()
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try makeOrRecreate(schema: schema, config: config, url: url)
        applyProtections(to: url)
        return container
    }

    /// Open the store, and if that fails (an incompatible/failed schema migration), delete the store
    /// and rebuild it once. This is safe BECAUSE the store is a derived cache: every rollup, insight,
    /// and correlation is recomputed from HealthKit (the source of truth) on the next ingest/analysis.
    /// Trading a stale cache for a guaranteed launch is the right call here — a hard crash on a
    /// migration we can always regenerate would not be. A second failure is real and rethrows.
    private static func makeOrRecreate(
        schema: Schema,
        config: ModelConfiguration,
        url: URL
    ) throws -> ModelContainer {
        do {
            return try ModelContainer(
                for: schema, migrationPlan: VerdantMigrationPlan.self, configurations: config
            )
        } catch {
            guard shouldRebuild(storeIsReadable: isReadable(url)) else {
                log.error("""
                Store open failed and the file cannot be read — the device is locked, not the store \
                corrupt. Keeping it; this session runs in memory and the next unlocked launch opens \
                it intact.
                """)
                throw error
            }
            log
                .error(
                    "Store open failed (\(String(describing: error), privacy: .public)); rebuilding the derived cache"
                )
            destroyStore(at: url)
            return try ModelContainer(
                for: schema, migrationPlan: VerdantMigrationPlan.self, configurations: config
            )
        }
    }

    /// The store file and its SQLite journal sidecars. SwiftData/SQLite name the WAL and SHM files
    /// with a HYPHEN suffix — "Verdant.store-wal"/"-shm", NOT a dotted ".wal" path extension. Using
    /// `appendingPathExtension` silently targets files that never exist, so the real journals get
    /// neither deleted on rebuild nor protected at rest (the WAL holds recent, not-yet-checkpointed
    /// derived-health writes), defeating the device-only/encrypted-at-rest commitment.
    private static func storeFiles(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return ["", "-wal", "-shm"].map { directory.appending(path: name + $0) }
    }

    /// Remove the store and its WAL/SHM sidecars so a fresh container can be created.
    /// Whether a failed store open should DELETE the store and start over.
    ///
    /// It always did, and that is safe for the rollups — they are derived and the launch catch-up
    /// rebuilds them from HealthKit. It is not safe for the findings. An `InsightLog` is the product
    /// of hours of agent reasoning over a person's history and exists nowhere else; deleting the
    /// file throws away everything the app has ever concluded about them.
    ///
    /// The failure this guards is not corruption. The store is `FileProtectionType
    /// .completeUnlessOpen`, so a NEW open while the device is locked fails — and a background task
    /// can launch the app in exactly that state, after a reboot with no unlock. Left as it was, one
    /// locked background launch silently destroyed the user's entire history of findings, behind a
    /// single log line, and the app came back looking new.
    ///
    /// Reading the file separates the two cleanly: if it cannot be opened at all, it is locked and
    /// nothing is known about whether it is intact. Refusing to rebuild
    /// then costs one session in memory (`VerdantApp` falls back, `storeIsEphemeral` keeps the
    /// background run from spending model time on a throwaway store) and the next unlocked launch
    /// opens the real one. Nothing is bricked either: a genuinely corrupt store still gets rebuilt
    /// the first time it is opened unlocked.
    static func shouldRebuild(storeIsReadable: Bool) -> Bool {
        storeIsReadable
    }

    /// Can the store file be read AT THIS MOMENT? Asked by opening a handle rather than by consulting
    /// `UIApplication.isProtectedDataAvailable`, which is UIKit and main-actor-bound while this runs
    /// wherever a container is built. Opening the file is also the more direct question: it tests the
    /// exact operation that just failed.
    ///
    /// A missing file is "readable" — there is nothing to protect and nothing to lose, so a first
    /// launch takes the normal path.
    static func isReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    private static func destroyStore(at url: URL) {
        for file in storeFiles(for: url) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func storeURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: storeFileName)
    }

    /// Re-apply at-rest protections to the store and its sidecars. The WAL/SHM files are created
    /// lazily on first write and won't exist at container-init time, so callers run this again after
    /// the first write (see `AppModel.bootstrap`).
    static func reapplyProtections() {
        guard let url = try? storeURL() else { return }
        applyProtections(to: url)
    }

    /// Apply `.completeUnlessOpen` and exclude-from-backup to the store file and its WAL/SHM
    /// sidecars (best effort — missing files are skipped, not an error).
    ///
    /// Internal rather than private so a test can call it against a real file and read the
    /// attributes back. Settings tells the user "Findings stay on this device — encrypted, never
    /// copied to iCloud or backups", and until now the only thing standing behind that sentence was
    /// a source scan asserting `isExcludedFromBackup = true` appears in this file. A scan for a
    /// string cannot tell a wired-up call from an orphaned one, which is exactly how a feature ends
    /// up implemented, tested and inert.
    static func applyProtections(to storeURL: URL) {
        for url in storeFiles(for: storeURL) where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: url.path
                )
                try excludeFromBackup(url)
            } catch {
                log.error("Could not protect \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// Keep the derived-insight store off iCloud/iTunes device backups, honoring the device-only
    /// commitment (its contents are encrypted at rest regardless).
    private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
