import Foundation
import Testing
@testable import Verdant

/// What a finding's provenance line says when a panel produced nothing.
///
/// Split from `AgenticGovernanceTests` when that file passed the 500-line limit. The subject is
/// narrow and worth its own place: the app promises on every finding's detail screen that it was
/// "put through a panel of independent skeptics and analysts who re-tested it against your data",
/// and this is the code that has to make that true — or say plainly when it was not.
struct PanelSilenceTests {
    /// A finding that clears the panels and then fails to SAVE must say so.
    ///
    /// `appendXIfNovel` returns nil for "not novel", and `try?` made a thrown write return nil too —
    /// so a lost finding was indistinguishable from a duplicate and produced no line at all, on a feed
    /// whose rule is that it states what is happening. Every other outcome on that path narrates
    /// itself.
    @Test func `every persist route narrates a failed save`() throws {
        let persist = try #require(
            SourceScan.swiftSources().first { $0.path == "Orchestrator+Persist.swift" }
        )
        let code = SourceScan.code(persist.text)
        // Every append goes through the narrating helper, and none is left on a bare `try?`.
        let appends = code.components(separatedBy: "await writer.append").count - 1
        #expect(appends >= 6, "expected an append per finding kind, found \(appends)")
        let narrated = code.components(separatedBy: "await saved(").count - 1
        #expect(narrated == appends, "\(appends - narrated) append(s) still swallow a write failure")
        #expect(!code.contains("try? await writer.append"), "a bare try? append came back")
        #expect(code.contains("could not be saved"), "nothing reports a lost finding")
    }

    /// The panels must actually be convened on every production path.
    ///
    /// `survivesScrutiny` and `survivesReplication` both open with `guard ctx.adversarial`, and the
    /// flag defaults to true — it exists so tests can drive the persist path without the model. No
    /// caller passes false today. If one ever did, for a "fast" background pass, every finding it
    /// produced would carry copy promising two panels that never ran, and nothing else in the suite
    /// would notice: the flag is honoured correctly, the finding persists correctly, and the sentence
    /// is a string in a different file.
    @Test func `no production path turns the panels off`() throws {
        for source in try SourceScan.swiftSources() {
            let code = SourceScan.code(source.text)
            for line in code.components(separatedBy: .newlines)
                where line.contains("adversarial:") && line.contains("false")
            {
                Issue.record(
                    Comment(
                        rawValue: "\(source.path) disables the panels: \(line.trimmingCharacters(in: .whitespaces))"
                    )
                )
            }
        }
    }

    /// Non-vacuity: the scan must be reading files that mention the flag at all.
    @Test func `the sweep sees the adversarial flag`() throws {
        let mentions = try SourceScan.swiftSources()
            .count { SourceScan.code($0.text).contains("adversarial") }
        #expect(mentions >= 3, "only \(mentions) files mention the flag — did the scan break?")
    }

    /// A panel that RAN and heard nothing back must say so, not fall silent.
    ///
    /// Both panels fall open when no verdict renders — a wholly rate-limited run keeps its finding
    /// rather than losing it to infrastructure, which is the right trade. But the finding then
    /// reaches the feed beside copy promising it was "put through a panel of independent skeptics
    /// and analysts who re-tested it against your data", and an omitted clause was the only hint
    /// otherwise. A silence reads as a detail nobody recorded, when it is the one case where a person
    /// should trust the finding less.
    @Test func `a panel that rendered no verdicts says so rather than going quiet`() {
        let silent = PanelOutcome([])
        #expect(silent.passed, "the fall-open trade changed")
        let line = Orchestrator.provenanceLine(
            lens: "sleep and its downstream effects", skeptics: silent, replication: silent
        )
        #expect(line.contains("no skeptics could be reached"), Comment(rawValue: line))
        #expect(line.contains("no replication analysts could be reached"), Comment(rawValue: line))
    }

    /// And a panel that never convened still says nothing — there is no fact to report, and
    /// inventing one would be the same failure in the other direction.
    @Test func `a panel that never convened stays silent`() {
        let line = Orchestrator.provenanceLine(
            lens: "sleep", skeptics: .notConvened, replication: .notConvened
        )
        #expect(!line.contains("could be reached"), Comment(rawValue: line))
        #expect(!line.contains("skeptics"), Comment(rawValue: line))
    }
}
