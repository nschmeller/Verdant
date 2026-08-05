import Foundation
import Testing
@testable import Verdant

/// The scan count `AnalysisSubstrate`'s own documentation quotes.
///
/// That comment explains why every scan runs in its own detached task — "the N independent scans
/// occupy every CPU core instead of one" — and it said SIX while `precompute` started ten. Seasonality
/// and provenance were each added later, and neither addition had any reason to look at a sentence
/// three screens up.
///
/// Pinned because this is the shape that goes stale by ADDITION ELSEWHERE: nobody edits the wrong
/// line, so nobody notices it became wrong. It is also the number a reader uses to judge whether the
/// parallelism argument still holds.
struct SubstrateScanCountTests {
    private static let spelled = [
        6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve"
    ]

    @Test func `the documented scan count matches what precompute starts`() throws {
        let source = try #require(
            SourceScan.swiftSources().first { $0.path == "AnalysisSubstrate.swift" }
        )
        let code = SourceScan.code(source.text)
        // Every line in `precompute` that kicks off a memoized scan.
        let started = code.components(separatedBy: .newlines)
            .count(where: { $0.contains("_ = ") && $0.contains("Task()") })

        #expect(started >= 6, "found only \(started) scans — did the scan break?")

        let word = try #require(Self.spelled[started], "no spelling for \(started) — extend the table")
        #expect(
            source.text.contains("the \(word) independent scans"),
            Comment(rawValue: "precompute starts \(started) scans; the doc does not say “the \(word)”")
        )
        // And no OTHER count is claimed, so a corrected sentence cannot sit beside a stale one.
        for (value, other) in Self.spelled where value != started {
            #expect(
                !source.text.contains("the \(other) independent scans"),
                Comment(rawValue: "the doc also claims “the \(other) independent scans”")
            )
        }

        // ANY count of scans, however phrased. The check above pins one exact sentence, and a second
        // claim three-quarters of the way down the file said "leaves up to eight scans running to
        // completion" while precompute started ten — invisible here, because it did not use the
        // words being searched for. A guard that only recognises the phrasing it was written against
        // is a guard against one edit.
        for (value, other) in Self.spelled where value != started {
            for phrase in ["\(other) scans", "\(value) scans"] {
                #expect(
                    !source.text.lowercased().contains(phrase.lowercased()),
                    Comment(rawValue: "the file claims “\(phrase)” but precompute starts \(started)")
                )
            }
        }
        // Non-vacuity: the correct count IS stated somewhere, so the sweep is not passing on a file
        // that simply never mentions a number.
        #expect(
            source.text.lowercased().contains("\(word) scans")
                || source.text.lowercased().contains("the \(word) independent scans"),
            Comment(rawValue: "no sentence states the real count of \(started)")
        )
    }
}
