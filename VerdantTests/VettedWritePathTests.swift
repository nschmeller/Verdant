import Foundation
import Testing
@testable import Verdant

/// **"Every surfaced finding still passes the agent safety panel and the adversarial skeptic
/// panel."** The Orchestrator's own doc says so, and until now nothing checked it.
///
/// It is the app's central promise and the one a user cannot verify: prose written by a small model
/// about their health reaches them only if a safety panel cleared it and a skeptic panel and a
/// replication panel held it up. Today that is true because there are exactly two calls that write a
/// finding, both in `Orchestrator+Persist.swift`, both downstream of those gates.
///
/// Nothing made it stay true. A third write path — an audit that re-surfaces a retired finding, a
/// migration that repairs a row, a new finding kind added in a hurry — would compile, pass every
/// existing test, and put unvetted model prose on the feed. The failure is silent by construction:
/// the finding looks exactly like a vetted one, because the vetting is what it is missing.
///
/// So this is a source scan, in the family of `ZeroCloudTests` and the sessions-in-one-file
/// invariant. It cannot prove the gates are GOOD — the measurements on `passesSafety` and
/// `scrutinyLenses` say plenty about that — only that nothing reaches the feed around them.
struct VettedWritePathTests {
    private let persistFile = "Orchestrator+Persist.swift"

    private func sources() throws -> [(path: String, text: String)] {
        try SourceScan.swiftSources()
    }

    /// The two writes that put a finding in front of a person live in one file, so one file is all
    /// the reviewer of a new feature has to read.
    @Test func `only the persist path writes a finding`() throws {
        for method in ["appendInsightIfNovel", "appendCorrelationIfNovel"] {
            let callers = try sources()
                .filter { $0.path != "StoreWriter.swift" && !$0.path.hasSuffix("Writer.swift") }
                .filter { SourceScan.code($0.text).contains("\(method)(") }
                .map(\.path)
                .sorted()
            #expect(
                callers == [persistFile],
                Comment(rawValue: "\(method) is called outside the vetted path: \(callers)")
            )
        }
    }

    /// And inside that file, every per-kind helper goes through the panels. `survives` is where the
    /// skeptic and replication panels run; a helper that skipped it would still persist, and its
    /// finding would carry a provenance line saying nothing about who checked it.
    @Test func `every per-kind persist helper goes through the panels`() throws {
        let file = try #require(try sources().first { $0.path == persistFile })
        let code = SourceScan.code(file.text)
        // Split on the helper declarations so each body is checked on its own.
        let helpers = code.components(separatedBy: "private func persist").dropFirst()
        #expect(helpers.count >= 5, "found \(helpers.count) per-kind helpers — the scan is not finding them")
        for helper in helpers {
            let name = helper.prefix { $0 != "(" }
            #expect(
                helper.contains("await survives("),
                Comment(rawValue: "persist\(name) persists without the skeptic and replication panels")
            )
        }
    }

    /// Safety is checked once, before the per-kind split, so it cannot be missed by adding a kind.
    @Test func `the safety panel gates the shared entry point`() throws {
        let file = try #require(try sources().first { $0.path == persistFile })
        let code = SourceScan.code(file.text)
        let entry = try #require(code.range(of: "func persistProposed"))
        let afterEntry = String(code[entry.lowerBound...])
        let firstHelper = afterEntry.range(of: "private func persist")
        let body = firstHelper.map { String(afterEntry[..<$0.lowerBound]) } ?? afterEntry
        // Any spelling of the same gate — `passesSafety` is the boolean, `safetyRefusal` returns the
        // reviewer's sentence, `safetyOutcome` adds the one rewrite. This has caught two renames in a
        // day, which is the scan working; the assertion is that the GATE runs, so it lists them all.
        #expect(
            ["safetyOutcome(", "safetyRefusal(", "passesSafety("].contains(where: body.contains),
            "persistProposed no longer runs the safety panel before the per-kind split"
        )
    }

    /// Non-vacuity: the scan is reading the file it thinks it is, and that file really does hold the
    /// gates being asserted. Without this the three tests above would all pass on a typo'd filename.
    @Test func `the scan is looking at the real persist path`() throws {
        let file = try #require(try sources().first { $0.path == persistFile })
        let code = SourceScan.code(file.text)
        #expect(code.contains("appendInsightIfNovel("))
        #expect(code.contains("appendCorrelationIfNovel("))
        #expect(code.contains("func survives("))
    }
}
