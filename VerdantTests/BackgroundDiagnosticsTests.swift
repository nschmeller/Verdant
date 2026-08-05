import Foundation
import Testing
@testable import Verdant

/// The breadcrumbs Settings uses to tell the user whether the OS really granted each background
/// window. They are two lines of `UserDefaults`, but they are the only evidence a person has that
/// on-power background compute is happening at all — and this app's whole purpose is measured in how
/// much of it happens.
///
/// The failure worth guarding is a copy-paste one: two stamps sharing a key. A cheap power-independent
/// REFRESH would then light up the enhance row, and Settings would report that the full agent pass
/// ran overnight when it never did. That is the same class as the duty-cycle meter claiming "last
/// minute" before it had one — a small lie on the screen whose job is honest measurement.
struct BackgroundDiagnosticsTests {
    @Test func `the two windows are recorded independently`() {
        let refreshAt = Date(timeIntervalSince1970: 1_000_000)
        let enhanceAt = Date(timeIntervalSince1970: 2_000_000)

        BackgroundRunDiagnostics.stampRefresh(now: refreshAt)
        BackgroundRunDiagnostics.stampEnhance(now: enhanceAt)
        #expect(BackgroundRunDiagnostics.lastRefresh == refreshAt)
        #expect(BackgroundRunDiagnostics.lastEnhance == enhanceAt)

        // A later refresh must not touch the enhance breadcrumb — the shared-key bug.
        let laterRefresh = Date(timeIntervalSince1970: 3_000_000)
        BackgroundRunDiagnostics.stampRefresh(now: laterRefresh)
        #expect(BackgroundRunDiagnostics.lastRefresh == laterRefresh)
        #expect(
            BackgroundRunDiagnostics.lastEnhance == enhanceAt,
            "a refresh overwrote the on-power breadcrumb — Settings would claim a pass that never ran"
        )

        // And the reverse.
        let laterEnhance = Date(timeIntervalSince1970: 4_000_000)
        BackgroundRunDiagnostics.stampEnhance(now: laterEnhance)
        #expect(BackgroundRunDiagnostics.lastRefresh == laterRefresh)
        #expect(BackgroundRunDiagnostics.lastEnhance == laterEnhance)
    }

    /// Each stamp records the moment it was given, not the moment it is read — otherwise "last run"
    /// would drift forward every time the user opened Settings.
    @Test func `a stamp records the time it was given`() {
        let when = Date(timeIntervalSince1970: 5_000_000)
        BackgroundRunDiagnostics.stampEnhance(now: when)
        #expect(BackgroundRunDiagnostics.lastEnhance == when)
        #expect(BackgroundRunDiagnostics.lastEnhance == when, "the value moved between reads")
    }
}
