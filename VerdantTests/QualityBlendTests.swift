import Foundation
import Testing
@testable import Verdant

/// `quality` decides what the user sees FIRST — feed order, which findings the audit re-examines,
/// and the `q85` the curator reads. It is a fixed blend of the agent's `worth` with an engine number,
/// so a fixed fraction of every finding's prominence is decided arithmetically rather than by an
/// agent. That is a product decision and is flagged rather than changed; this pins it so it cannot
/// drift silently, and prints what the per-kind scaling does.
struct QualityBlendTests {
    @Test func `the blend weights the agent and the engine as documented`() {
        // An agent that thinks a finding is excellent, an engine that finds it faint.
        #expect(Orchestrator.qualityScore(worth: 100, strength: 0, worthWeight: 0.6) == 60)
        // And the reverse: a faint claim the engine loves still cannot reach the top.
        #expect(Orchestrator.qualityScore(worth: 0, strength: 100, worthWeight: 0.6) == 40)
        #expect(Orchestrator.qualityScore(worth: 0, strength: 100, worthWeight: 0.55) == 45)
    }

    @Test func `the blend clamps rather than overflowing`() {
        #expect(Orchestrator.qualityScore(worth: 100, strength: 500, worthWeight: 0.6) == 100)
        #expect(Orchestrator.qualityScore(worth: -50, strength: -50, worthWeight: 0.6) == 0)
    }

    /// The per-kind multipliers, READ FROM SOURCE rather than transcribed — a hand-copied constant is
    /// how two budget tests in this repo came to measure a case the app no longer produced.
    ///
    /// They saturate at very different points, and that decides cross-kind feed order more than any
    /// agent does. Printed rather than asserted, because the right values are a product call.
    @Test func `report where each kind saturates`() throws {
        let source = try #require(
            try SourceScan.swiftSources().first { $0.path == "Orchestrator+Persist.swift" }
        ).text
        // (label, regex capturing the multiplier, the engine quantity it scales)
        //
        // Anchored on the ASSIGNMENT, not on the quantity. `milestone.relativeMargin * 100` also
        // appears in this file — in the verified-figures array, above the scaling — so an unanchored
        // `firstMatch` reads 100 and reports the milestone saturating at a 100% record margin instead
        // of 33%. Caught before this test ever ran, but only by reading the file it scans.
        struct Scaling {
            let kind: String
            /// Captures the multiplier in group 1.
            let pattern: String
            /// The engine quantity it scales, for the printed report.
            let quantity: String
        }
        let scalings = [
            Scaling(
                kind: "seasonal",
                pattern: #"magnitude = min\(100, swing\.amplitude \* (\d+) \* agreement\)"#,
                quantity: "amplitude x agreement"
            ),
            Scaling(
                kind: "volatility",
                pattern: #"magnitude = min\(100, abs\(Foundation\.log\(shift\.cvRatio\)\) \* (\d+)\)"#,
                quantity: "|ln(cvRatio)|"
            ),
            Scaling(
                kind: "milestone",
                pattern: #"strength = min\(100\.0, milestone\.relativeMargin \* (\d+)\)"#,
                quantity: "relativeMargin"
            ),
            Scaling(
                kind: "regimeShift",
                pattern: #"strength = min\(100\.0, shift\.score \* (\d+)\)"#,
                quantity: "score"
            )
        ]
        var report: [String] = []
        for scaling in scalings {
            let (kind, pattern, quantity) = (scaling.kind, scaling.pattern, scaling.quantity)
            let re = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            let match = try #require(
                re.firstMatch(in: source, range: range),
                Comment(rawValue: "\(kind) scaling not found — the blend was reshaped, revisit this")
            )
            let factor = try #require(Double((source as NSString).substring(with: match.range(at: 1))))
            // Where the term hits its 100 ceiling, i.e. stops distinguishing findings at all.
            let saturates = 100 / factor
            report
                .append(
                    "\(kind): x\(Int(factor)) → saturates at \(quantity) ≥ \(String(format: "%.2f", saturates))"
                )
        }
        print("QUALITY SCALING (worth 60% / engine 40%)")
        for line in report {
            print("  " + line)
        }
        #expect(report.count == scalings.count)
    }
}
