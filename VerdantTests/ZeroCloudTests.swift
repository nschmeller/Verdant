import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The app's headline promise — "reasons over your Apple Health data entirely on-device, zero
/// cloud" — is the one claim a user cannot verify for themselves and the one whose failure would
/// matter most. Yet it rested entirely on absences and a single parameter: `cloudKitDatabase:
/// .none` in one initializer, and the fact that nobody had imported a networking API. A refactor
/// could drop either silently, no test would fail, and health data would start leaving the device.
///
/// These scan the shipping SOURCE rather than behaviour, because the property IS the absence of
/// code. `docs/VERIFIED-CLAIMS.md` records why each item is load-bearing, straight from Apple's
/// documentation; this file is that document's enforcement.
struct ZeroCloudTests {
    /// Verdant only ever READS Apple Health. It never writes, and never asks to.
    ///
    /// A negative promise, and the kind that is easy to lose: `requestAuthorization(toShare:read:)`
    /// takes the write set as its FIRST argument, so adding one type there is a one-word edit. The
    /// user would then be shown a write-permission sheet by an app that only reads, and the app
    /// would hold the capability to modify their Health data. Nothing else in the suite would
    /// notice, because nothing exercises a permission dialog.
    ///
    /// Scanned rather than exercised, for the same reason as the networking check above: the
    /// property is the ABSENCE of code, and absences cannot be observed by running anything.
    @Test func `the app asks for read access only, and never writes to Health`() throws {
        var offenders: [String] = []
        var authorizationSites = 0
        for file in try SourceScan.swiftSources() {
            let code = SourceScan.code(file.text)
            // `callSites` skips the wrapper's own DECLARATION; `read:` then picks out HealthKit's
            // call rather than the zero-argument wrapper calls, which name neither argument. The
            // first version of this scan reported both of those as missing an argument they never
            // had.
            for call in SourceScan.callSites(of: "requestAuthorization", in: code)
                where call.contains("read:")
            {
                authorizationSites += 1
                if !call.contains("toShare: []") {
                    offenders.append("\(file.path): requestAuthorization without an empty toShare")
                }
            }
            // HealthKit's mutating APIs. `modelContext.save()` is SwiftData and unrelated, so the
            // scan names the HealthKit ones specifically rather than banning "save".
            let writes = ["deleteObjects(", "saveObjects(", "store.save(", "healthStore.save("]
            for write in writes where code.contains(write) {
                offenders.append("\(file.path): calls \(write) — Verdant does not write to Health")
            }
        }
        #expect(authorizationSites >= 1, "found no authorization call — the scan missed it")
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    /// The second guard on the same promise, made explicit.
    ///
    /// iOS refuses to launch an app that requests Health WRITE access without
    /// `NSHealthUpdateUsageDescription`. That is a real protection — but its failure mode is a crash
    /// on first launch, which is how it was discovered here: injecting a write scope into
    /// `requestAuthorization` did not fail the test above, it killed the test runner before any test
    /// ran. Anyone adding writes would hit that crash and the obvious fix is to add the key, at
    /// which point the only remaining guard is the scan above.
    ///
    /// So the key's ABSENCE is itself load-bearing, and stating it here means a diff that adds it
    /// has to argue with a test instead of quietly unlocking write access.
    @Test func `the app declares no Health write permission`() throws {
        let plist = try String(
            contentsOf: SourceScan.appRoot.appendingPathComponent("Resources/Info.plist"),
            encoding: .utf8
        )
        #expect(
            plist.contains("NSHealthShareUsageDescription"),
            "the READ description is missing — the scan is looking at the wrong file"
        )
        #expect(
            !plist.contains("NSHealthUpdateUsageDescription"),
            "the app declares Health WRITE permission; it only ever reads"
        )
    }

    /// Nothing in the app may reach the network. Every item here is a real path off-device that the
    /// architecture deliberately forgoes — not a stylistic ban.
    @Test func `the app links no path off the device`() throws {
        let forbidden = [
            // Any HTTP client at all: the whole promise is that health data never travels.
            "URLSession",
            "CKContainer",
            "CKDatabase",
            // The ONE Foundation Models path that leaves the device. Tempting precisely when the
            // on-device model struggles, which is exactly when the data is most sensitive.
            "PrivateCloudComputeLanguageModel",
            // Higher-quality embeddings, but they fetch model assets from Apple on first use. The
            // app deliberately uses classic NLEmbedding, which ships with the OS.
            "NLContextualEmbedding"
        ]
        let sources = try SourceScan.swiftSources()
        // POSITIVE CONTROL, before the ban. Every assertion below is a NEGATIVE — "this token is
        // absent" — and a matcher that had stopped working would satisfy all of them while reading
        // nothing, on the one guarantee this app cannot get wrong. So first prove the matcher finds
        // things that genuinely are there, in all the forms it claims to recognise.
        let present = sources.map { SourceScan.code($0.text) }
        #expect(
            present.contains { SourceScan.uses("HKHealthStore", in: $0) },
            "the matcher cannot find a type the app demonstrably uses — the ban below proves nothing"
        )
        #expect(
            present.contains { SourceScan.uses("FoundationModels", in: $0) },
            "the matcher cannot find an import — the ban below proves nothing"
        )

        for source in sources {
            let body = SourceScan.code(source.text)
            for token in forbidden {
                #expect(!SourceScan.uses(token, in: body), "\(source.path) uses \(token)")
            }
        }
    }

    /// The complement to the ban above: an ALLOWLIST of frameworks, so a path off the device that
    /// nobody thought to forbid still has to be noticed.
    ///
    /// `forbidden` is a denylist of five tokens, and a denylist can only refuse what someone
    /// anticipated. `import Network` and an `NWConnection`, `CFSocket`, a swift-package HTTP client
    /// — every one of them passes that test. For the app's single load-bearing promise, "no path off
    /// the device", that is the wrong shape of check to rely on alone.
    ///
    /// The app imports fourteen frameworks, all first-party and all stable, so the allowlist costs
    /// nothing to maintain and makes any fifteenth a deliberate decision. Adding one is fine — add it
    /// here in the same commit, which is the entire point.
    ///
    /// The two checks are complementary rather than redundant, and `Darwin` is why: it is on this
    /// list legitimately (`host_processor_info` for the per-core meter) and it also exposes BSD
    /// sockets. An allowlist cannot see inside a framework it permits; the denylist and the
    /// `URLSession` ban still do that work.
    @Test func `the app imports only frameworks that stay on the device`() throws {
        let allowed: Set = [
            "Foundation", "SwiftData", "FoundationModels", "SwiftUI", "OSLog", "HealthKit",
            "Synchronization", "Observation", "UIKit", "NaturalLanguage", "Dispatch", "Darwin",
            "Charts", "BackgroundTasks"
        ]
        var found: Set<String> = []
        for source in try SourceScan.swiftSources() {
            for line in SourceScan.code(source.text).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // `@preconcurrency import X`, `internal import X`, plain `import X`.
                guard let range = trimmed.range(of: "import "), trimmed.hasSuffix(
                    trimmed[range.upperBound...]
                ) else { continue }
                guard trimmed.hasPrefix("import") || trimmed.contains(" import ") else { continue }
                let name = trimmed[range.upperBound...]
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { found.insert(String(name)) }
            }
        }
        // Positive control, in the spirit of the one above: prove the scan reads imports at all
        // before trusting a set-difference that would be empty if it read nothing.
        #expect(found.contains("HealthKit"), "the import scan found nothing it should have")
        #expect(found.count >= 10, "found only \(found.count) imports — the scan is not working")

        let unexpected = found.subtracting(allowed).sorted()
        #expect(
            unexpected.isEmpty,
            Comment(rawValue: """
            new framework(s) imported: \(unexpected.joined(separator: ", ")). If they stay on the \
            device, add them to `allowed` in this test as part of the same change.
            """)
        )
    }

    /// SwiftData syncs to the user's private CloudKit database BY DEFAULT. Omitting this one
    /// argument silently ships every insight and every health rollup to iCloud — the single
    /// likeliest way this app breaks its promise, and invisible in review.
    @Test func `the persistent store opts out of CloudKit explicitly`() throws {
        let container = try #require(
            try SourceScan.swiftSources().first { $0.path == "AppContainer.swift" },
            "AppContainer.swift is where the store is configured"
        )
        // CODE, not raw text. As written this passed if `cloudKitDatabase: .none` appeared only in a
        // COMMENT — and this file's comments discuss the setting at length, which is the documented
        // reason `SourceScan.code` exists.
        let code = SourceScan.code(container.text)
        #expect(code.contains("cloudKitDatabase: .none"))
        #expect(!code.contains("cloudKitDatabase: .automatic"))
        #expect(!code.contains("cloudKitDatabase: .private"))
    }

    /// Settings tells the user, in as many words, that findings are "encrypted, never copied to
    /// iCloud or backups". The iCloud half is covered above; this is the rest of that sentence.
    /// Both protections are applied to the store AND its WAL/SHM sidecars — the sidecars matter
    /// because they are created lazily on first write, so an implementation that only protected the
    /// main file at container-init would leave real health-derived content unprotected.
    @Test func `the store is encrypted at rest and kept out of backups`() throws {
        let container = try #require(
            try SourceScan.swiftSources().first { $0.path == "AppContainer.swift" }
        )
        let body = SourceScan.code(container.text)
        #expect(body.contains("FileProtectionType.completeUnlessOpen"))
        #expect(body.contains("isExcludedFromBackup = true"))
        // Applied over the sidecar set, not just the one file.
        #expect(body.contains("storeFiles(for:"))
    }

    /// Entitlements are the other half: CloudKit needs one, so its absence is a hard backstop even
    /// if a `ModelConfiguration` somewhere were misconfigured.
    @Test func `the app claims no iCloud entitlement`() throws {
        let entitlements = SourceScan.appRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("Verdant.entitlements")
        let text = try String(contentsOf: entitlements, encoding: .utf8)
        #expect(!text.contains("com.apple.developer.icloud"))
        #expect(!text.contains("com.apple.developer.ubiquity"))
        // …while the two HealthKit entitlements it DOES need are present, so this isn't passing
        // because it read the wrong file.
        #expect(text.contains("com.apple.developer.healthkit"))
    }
}

/// The device-only promise, checked on a real file rather than in the source.
///
/// Settings says "Findings stay on this device — encrypted, never copied to iCloud or backups". That
/// is the app's most consequential user-facing claim and the one a person cannot verify. It was
/// enforced by a source scan for `isExcludedFromBackup = true`, which passes whether or not anything
/// ever calls the function containing it.
struct StoreProtectionTests {
    @Test func `protections are really applied to the store and its sidecars`() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdant-protect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = dir.appendingPathComponent("Verdant.store")
        // The sidecars matter as much as the store: SQLite's WAL holds recently written rows, so a
        // backup that captured it would carry findings the main file has not absorbed yet.
        let sidecars = [
            store,
            dir.appendingPathComponent("Verdant.store-wal"),
            dir.appendingPathComponent("Verdant.store-shm")
        ]
        for url in sidecars {
            try Data("x".utf8).write(to: url)
        }

        AppContainer.applyProtections(to: store)

        for url in sidecars {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(
                values.isExcludedFromBackup == true,
                Comment(rawValue: "\(url.lastPathComponent) would be copied into a device backup")
            )
        }
    }

    /// Non-vacuity: the assertion above must be able to fail. A freshly written file is not excluded
    /// until something excludes it — without this, a bug that made `applyProtections` a no-op would
    /// only be caught if the default happened to be the wrong way round.
    @Test func `a file is not excluded from backup by default`() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdant-default-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(
            values.isExcludedFromBackup != true,
            "the default already excludes — the test above proves nothing"
        )
    }
}

/// The CloudKit opt-out read off a BUILT container, not grepped out of the source.
///
/// The scan version passed while a production path was misconfigured: `VerdantApp` falls back to an
/// in-memory store when the real one will not open, and that configuration carried the SwiftData
/// default (`_automatic: true`). Nothing synced, because CloudKit needs an entitlement the app does
/// not claim — but the entitlement is documented as the backstop for this mistake, not the defence.
struct CloudKitConfigurationTests {
    private func isOptedOut(_ container: ModelContainer) -> Bool {
        container.configurations.allSatisfy {
            String(describing: $0.cloudKitDatabase).contains("_none: true")
        }
    }

    @Test func `the in-memory fallback opts out of CloudKit`() throws {
        #expect(try isOptedOut(AppContainer.makeContainer(inMemory: true)))
    }

    /// Non-vacuity: the check must be able to see a container that did NOT opt out, or it would pass
    /// on any string at all.
    @Test func `the check can tell an opted-out container from a default one`() throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let defaulted = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        #expect(!isOptedOut(defaulted), "a default configuration reads as opted out — the check is blind")
    }
}
