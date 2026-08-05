import Foundation
import Testing
@testable import Verdant

/// The replication analyst must receive the whole claim, and the steering it cannot work without.
///
/// Both were being truncated by clamps that predated the budgets they had to accommodate. Measured
/// 2026-08-03: a realistic claim ran 935 characters against a 400-character clamp — the analyst saw
/// 229 of a 763-character verified basis — and a realistic composed lens ran 350 against 240, which
/// deleted the available-metrics line outright and cut into the metric-key line.
///
/// These tests pin the RELATIONSHIP between the clamps and the budgets they must fit, rather than
/// the numbers themselves, so raising the basis budget without raising the claim clamp fails here
/// instead of quietly redacting the evidence again.
struct ReplicationBudgetTests {
    @Test func `the claim clamp fits a full summary and a full verified basis`() {
        let needed = FindingPhrasing.Phrasing.maxSummaryLength
            + BasisLengthTests.maxBasisCharacters
            + 18 // "\n\nVerified basis: "
        #expect(
            Subagents.maxReplicationClaim >= needed,
            Comment(rawValue: "clamp \(Subagents.maxReplicationClaim) cannot fit \(needed) characters "
                + "of claim — the analyst would re-test a redacted finding")
        )
    }

    /// The worst case built from the real generators, not a hand-typed string — the same discipline
    /// `BasisLengthTests` had to learn when its transcribed fixture drifted from the app.
    @Test func `a worst-case claim survives the clamp with its basis intact`() {
        let note = ProvenanceScan.noteForClaim(
            metric: .restingHeartRate, window: "the 59 days this level has held",
            since: Date(timeIntervalSince1970: 1_700_000_000),
            now: Date(timeIntervalSince1970: 1_700_000_000 + 59 * 86400),
            changes: [SourceChange(
                metric: .restingHeartRate, day: Date(timeIntervalSince1970: 1_700_000_000),
                before: ["Apple Watch Series 8"], after: ["Apple Watch Series 11", "iPhone 17 Pro"],
                daysBefore: 400, daysAfter: 59
            )]
        ) ?? ""
        let shift = RegimeShift(
            metric: .restingHeartRate, changeDay: Date(), preMean: 60, postMean: 56, score: 4.8,
            postDays: 58, medianStepSD: 0.3, maxSegmentTrendR: 0.7, maxPostGapDays: 30,
            suspectedDeviceSwap: true, coJumpingVitals: 4, sourceChangeNote: note
        )
        let summary = "Your resting heart rate stepped down about six weeks ago and has stayed at "
            + "the lower level since — it now sits near 56 bpm, against roughly 60 bpm before."
        let claim = "\(summary)\n\nVerified basis: \(shift.verifiedBasis)"
        let delivered = PromptText.clamped(claim, to: Subagents.maxReplicationClaim)
        // Non-vacuity: this fixture must really be a big claim, or the assertion proves nothing.
        #expect(
            claim.count > 900,
            Comment(rawValue: "fixture is too small to test the clamp: \(claim.count)")
        )
        #expect(
            delivered == claim,
            Comment(rawValue: "claim was cut at \(delivered.count) of \(claim.count)")
        )
        // The caveats are the part that used to be lost — they are at the END of the basis.
        #expect(delivered.contains("RECORDS"), "the provenance caveat did not reach the analyst")
        #expect(delivered.contains("unobserved stretch"), "the gap caveat did not reach the analyst")
    }

    @Test func `the lens clamp fits the model's re-test plus both code-generated lines`() {
        // 240 for the composed re-test (bounded by the caller), plus the worst case of each line the
        // orchestrator appends: 12 named metric keys, and the claim's own keys.
        let availableWorstCase = "This person has usable data for ONLY these metrics: "
            .count + Orchestrator.maxNamedAvailableMetrics * 26 + 45
        let namedWorstCase = 76 + 3 * 26
        #expect(Subagents.maxReplicationLens >= 240 + availableWorstCase + namedWorstCase + 2)
    }

    /// The ordering defect: the clamp is applied to the model-written part BEFORE the
    /// code-generated lines are joined on, so they can never be the casualty.
    @Test func `the orchestrator bounds the re-test, not the composed steering`() throws {
        let file = try #require(
            try SourceScan.swiftSources().first { $0.path == "Orchestrator+Replication.swift" }
        )
        let code = SourceScan.code(file.text)
        #expect(
            code.contains("[PromptText.clamped(lens, to: 240), named, available]"),
            "the composed steering is being clamped again — named/available cut from the end"
        )
    }
}
