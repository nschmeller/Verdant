import Foundation
import Testing
@testable import Verdant

/// Each finding kind reads the SAME four stored columns to mean different things, and the card
/// prints what it read.
///
/// `verifiedRecent` is a new baseline for a regime shift, a record-setting 7-day mean for a
/// milestone, a standard deviation for a volatility shift and a month effect in SDs for an annual
/// rhythm. `sampleCount` is days held, days a record leads, days measured, or YEARS observed. The
/// type system says none of this; the contract is a comment beside `InsightWriter` and a matching
/// comment beside the card, in different files.
///
/// A kind that misreads its own columns prints real, verified numbers under a false label. That is
/// worse than a wrong number — the figures are auditable and correct, so the sentence around them is
/// the only thing lying, and it is the sentence a person reads to decide whether to trust the app.
///
/// Until this suite the whole switch lived in a `private func -> some View`, so nothing could reach
/// it. These tests pin one kind at a time against the values `InsightWriter` actually stores.
struct FindingCardLineTests {
    private func line(
        _ kind: InsightKind,
        metric: MetricKey = .restingHeartRate,
        recent: Double = 54,
        baseline: Double = 63,
        pct: Double = -14.3,
        sampleCount: Int = 30,
        comparison: ComparisonKey? = .recentVsBaseline
    ) -> String {
        FindingCardLine.text(
            kind: kind, metric: metric,
            columns: FindingCardLine.Columns(
                verifiedRecent: recent, verifiedBaseline: baseline, verifiedPctChange: pct,
                sampleCount: sampleCount, comparison: comparison
            )
        )
    }

    /// `sampleCount` is `shift.postDays` — how long the new level has held.
    @Test func `a regime shift reads its columns as a held new baseline`() {
        let text = line(.regimeShift, sampleCount: 45)
        #expect(text.contains("New baseline"))
        #expect(text.contains("held 45 days"))
        #expect(text.contains("was ~"), "the prior level is not shown")
    }

    /// `sampleCount` is `milestone.spanDays` — the span the record leads, not days of data.
    @Test func `a milestone reads its columns as a record over a span`() {
        let text = line(.milestone, sampleCount: 400)
        #expect(text.contains("a record over the past ~400 days"))
        // The baseline column is not meaningful for a record, and must not be presented as one.
        #expect(!text.contains("was ~"), "a milestone printed a prior-level comparison")
    }

    /// `verifiedRecent`/`Baseline` are standard deviations here, so the line must say SWING, not
    /// level — the whole appeal of a volatility finding is that the level may be unchanged.
    @Test func `a volatility shift reads its columns as day-to-day swing`() {
        let text = line(.volatility, recent: 4, baseline: 2, pct: 100, sampleCount: 30)
        #expect(text.contains("Day-to-day swing"))
        #expect(text.contains("±"), "the SDs are not marked as a spread")
        #expect(text.contains("variability"))
    }

    /// The one that most needs pinning. `verifiedRecent`/`Baseline` hold month effects in SDs, and
    /// putting those through `MetricFormatting` would print "+1.2 bpm" for a standardised score —
    /// a real number under a false unit. The figure a person can judge is `verifiedPctChange`, which
    /// holds the swing in the metric's own units.
    @Test func `an annual rhythm shows the swing in real units, never the SD effects`() {
        let text = line(.seasonal, recent: 1.2, baseline: -0.9, pct: 5, sampleCount: 3)
        #expect(text.contains("Repeats yearly"))
        #expect(text.contains("across 3 years"), "years were rendered as days")
        // 5 bpm is the swing; 1.2 and -0.9 are SDs and must not appear as bpm.
        #expect(text.contains(MetricFormatting.formatted(5, .restingHeartRate)))
        #expect(!text.contains("1.2"), "a standardised effect was printed as a real-unit value")
        #expect(!text.contains("0.9"), "a standardised effect was printed as a real-unit value")
    }

    /// The level-change kinds. `displayName` is a suffix ("vs. your recent norm"), so using it as a
    /// connective produced a garbled double-"vs" — the labels are the fix, and they must stay.
    @Test func `a trend reads its columns as recent against baseline`() {
        let text = line(.trend)
        #expect(text.contains(ComparisonKey.recentVsBaseline.recentLabel))
        #expect(text.contains(ComparisonKey.recentVsBaseline.baselineLabel))
        #expect(!text.contains("vs vs"))
        #expect(!text.lowercased().contains("vs. your recent norm vs"))
    }

    /// A row whose comparison no longer resolves still has to read as English.
    @Test func `an unresolvable comparison falls back to plain words`() {
        let text = line(.trend, comparison: nil)
        #expect(text.contains("(recently)"))
        #expect(text.contains("(usual)"))
    }

    /// Every kind must produce a distinct sentence. This is the actual regression to fear: a new
    /// case added to `InsightKind` and folded into the level-change branch would give an annual
    /// rhythm a trend's line, which is precisely the bug `FindingPresentation` documents shipping.
    @Test func `no two kinds print the same line`() {
        let kinds: [InsightKind] = [.regimeShift, .milestone, .volatility, .seasonal, .trend]
        let lines = kinds.map { line($0) }
        #expect(Set(lines).count == kinds.count, "two kinds render identically: \(lines)")
    }

    /// And the switch stays exhaustive over the whole enum, not just the kinds above — a case with
    /// no branch is a build error, but a case quietly folded into the level-change branch is not.
    /// This at least guarantees every case produces something a person can read.
    @Test func `every kind in the vocabulary produces a line`() {
        for kind in InsightKind.allCases {
            let text = line(kind)
            #expect(!text.isEmpty, Comment(rawValue: "\(kind.rawValue) rendered nothing"))
            #expect(text.contains("·"), Comment(rawValue: "\(kind.rawValue) lost its separator"))
        }
    }
}
