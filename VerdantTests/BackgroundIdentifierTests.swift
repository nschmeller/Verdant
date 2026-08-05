import Foundation
import Testing
@testable import Verdant

/// The background-task identifiers, which exist twice: once in Swift (`Identifiers`) and once in
/// `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
///
/// `Identifiers`' own doc comment says it out loud — "that list can't reference Swift, so keep the
/// two in sync if you change them here" — which is the shape this codebase has been bitten by more
/// than any other: something transcribed rather than derived, kept honest by proofreading.
///
/// The consequence of drift is uniquely bad here. `BGTaskScheduler.register` fails for an identifier
/// the system has not been told to permit, and it fails at REGISTRATION, on a launch path nobody
/// watches, with no user-visible symptom whatsoever. The app keeps working in the foreground and
/// simply never wakes up again — and this app's stated purpose is the compute it does while nobody
/// is looking. Renaming the bundle id, adding a third task, or a typo in either place all produce
/// exactly the same silence.
///
/// It cannot be fixed by deriving one from the other: a plist cannot reference Swift, and reading the
/// plist at registration time would move the same risk to a different string. So it is pinned here.
struct BackgroundIdentifierTests {
    /// Read from the built app's own `Info.plist` — the file the system actually consults — rather
    /// than by parsing the source tree, so this measures what shipped.
    private func permittedIdentifiers() throws -> [String] {
        let bundle = Bundle(for: BundleMarker.self)
        // The tests run in their own bundle; the app's plist is what matters. `Bundle.main` under
        // xctest is the runner, so locate the host app explicitly.
        let host = Bundle.allBundles.first { $0.bundleIdentifier == Identifiers.bundle } ?? bundle
        let value = host.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
        return try #require(
            value as? [String],
            "BGTaskSchedulerPermittedIdentifiers is missing — every registration fails silently"
        )
    }

    @Test func `every registered background task is permitted by Info plist`() throws {
        let permitted = try Set(permittedIdentifiers())
        // The identifiers the app actually registers, read from the scheduler rather than retyped
        // here — a third copy in the test would be one more thing to keep in sync.
        for identifier in [
            BackgroundScheduler.refreshIdentifier, BackgroundScheduler.enhanceIdentifier
        ] {
            #expect(
                permitted.contains(identifier),
                Comment(rawValue: "\(identifier) is registered in Swift but absent from Info.plist")
            )
        }
    }

    /// And nothing is permitted that the app never registers. A stale entry is harmless to the OS
    /// but is the visible trace of a rename that updated one side only — the next reader trusts it.
    @Test func `the Info plist permits nothing the app does not register`() throws {
        let registered = Set([
            BackgroundScheduler.refreshIdentifier, BackgroundScheduler.enhanceIdentifier
        ])
        for identifier in try permittedIdentifiers() {
            #expect(
                registered.contains(identifier),
                Comment(rawValue: "Info.plist permits \(identifier), which nothing registers")
            )
        }
    }

    /// And the registration RESULT must be checked, not discarded.
    ///
    /// The plist checks above compare two lists of strings. They cannot see a registration that
    /// failed for any other reason — called after launch finished, or refused by the system — and
    /// `register(forTaskWithIdentifier:)` reports that only in a return value the code originally
    /// threw away. The app then kept running, kept scheduling, and never woke again, silently.
    @Test func `a failed background registration is not discarded`() throws {
        let scheduler = try #require(
            SourceScan.swiftSources().first { $0.path == "BackgroundScheduler.swift" }
        )
        let code = SourceScan.code(scheduler.text)
        // Every registration's result is bound to something.
        let calls = code.components(separatedBy: "BGTaskScheduler.shared.register").count - 1
        #expect(calls == 2, "expected two registrations, found \(calls)")
        let bound = code.components(separatedBy: "= BGTaskScheduler.shared.register").count - 1
        #expect(bound == calls, "\(calls - bound) registration result(s) discarded")
        // And a failure is reported rather than swallowed.
        #expect(
            code.contains("FAILED to register"),
            "nothing reports a background registration that did not take"
        )
    }

    /// The identifiers must also be namespaced under the bundle id — the system requires it, and a
    /// bundle-id rename that missed `Identifiers` would otherwise only surface on a device.
    @Test func `task identifiers sit under the bundle identifier`() {
        for identifier in [
            BackgroundScheduler.refreshIdentifier, BackgroundScheduler.enhanceIdentifier
        ] {
            #expect(
                identifier.hasPrefix(Identifiers.bundle + "."),
                Comment(rawValue: "\(identifier) is not namespaced under \(Identifiers.bundle)")
            )
        }
    }
}

/// Locates the test bundle for `Bundle(for:)`.
private final class BundleMarker {}
