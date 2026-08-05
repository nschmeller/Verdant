import Foundation
import Testing
@testable import Verdant

/// When a store will not open, deleting it is only safe if it is actually broken.
///
/// The rebuild always fired. That is right for the rollups — derived, and the launch catch-up
/// rebuilds them from HealthKit — and wrong for the findings, which are the product of hours of
/// agent reasoning over someone's history and exist nowhere else.
///
/// The failure it needed to distinguish is not corruption. The store is
/// `FileProtectionType.completeUnlessOpen`, so a NEW open while the device is locked fails, and a
/// background task can launch the app in exactly that state after a reboot with no unlock. One
/// locked background launch destroyed every finding the app had ever produced, behind a single log
/// line, and the app came back looking new.
struct StoreRebuildGuardTests {
    @Test func `an unreadable store is never rebuilt`() {
        #expect(!AppContainer.shouldRebuild(storeIsReadable: false))
    }

    /// A store that opens fine but fails to load IS corrupt, and must still be rebuilt — otherwise
    /// a genuinely broken file bricks the app forever rather than costing one rebuild.
    @Test func `a readable store still rebuilds on failure`() {
        #expect(AppContainer.shouldRebuild(storeIsReadable: true))
    }

    /// A missing file counts as readable: there is nothing to protect and nothing to lose, so a
    /// first launch takes the ordinary path rather than being treated as locked.
    @Test func `a store that does not exist yet is treated as readable`() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "verdant-not-here-\(UUID().uuidString).store")
        #expect(AppContainer.isReadable(missing))
    }

    /// And a real, readable file reads as readable — otherwise the guard would refuse every rebuild
    /// and the corruption path would be dead.
    @Test func `an existing readable file reads as readable`() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "verdant-probe-\(UUID().uuidString).store")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AppContainer.isReadable(url))
    }

    /// A file that exists and cannot be opened is the locked case, simulated with permissions since
    /// a simulator has no data protection. This is what a locked device looks like to `isReadable`.
    @Test func `an existing unreadable file reads as unreadable`() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "verdant-locked-\(UUID().uuidString).store")
        try Data("x".utf8).write(to: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(!AppContainer.isReadable(url))
    }
}
