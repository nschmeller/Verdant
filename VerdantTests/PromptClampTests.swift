import Foundation
import Testing
@testable import Verdant

/// Every lens, provenance line and challenge handed to an agent is assembled from strings a *model*
/// wrote — scout hypotheses, director angles, composed challenges, panel headlines, finding titles.
/// None of those has a schema-side length bound: a `@Guide` says "a single sentence" or "a 3-6 word
/// headline", and that shapes generation without promising anything about what comes back. A small
/// model that loops or rambles returns a long string, and the string is then interpolated into a
/// prompt for a 4,096-token window.
///
/// The failure mode is the one ARCHITECTURE records from the field — a context overflow, not a wrong
/// number — and it is nastier than a bad statistic because the session dies mid-exploration and the
/// pass just quietly produces less. The codebase already clamps at nearly every such site; this is
/// the net that keeps that discipline from eroding, and it caught the one site that had no clamp at
/// all (`focusedLenses`, on the user-triggered drill-down path).
struct PromptClampTests {
    /// What a runaway on-device generation looks like: far longer than any guide asked for, in the
    /// shape models actually produce when they loop.
    private let runaway = String(repeating: "resting heart rate and sleep duration ", count: 300)

    /// Lens strings ride into an investigator's session one per agent, so each must be bounded on its
    /// own. The bound is generous — the point is that a 11,000-character input cannot reach a prompt,
    /// not that the template is a particular size.
    private let perLensBound = 500

    @Test func `a runaway finding title cannot reach the focused fleet's prompts`() {
        let focus = InvestigationFocus(
            metric: .restingHeartRate, secondaryMetric: .sleepDurationHours, title: runaway
        )
        #expect(focus.title.count <= InvestigationFocus.maxTitleLength)

        let lenses = Orchestrator.focusedLenses(focus)
        #expect(!lenses.isEmpty)
        for lens in lenses {
            #expect(lens.count <= perLensBound, "focused lens ran to \(lens.count) characters")
        }
    }

    /// The finding's SUMMARY is the model-written `story`, and it was the last unbounded model
    /// string reaching a prompt — the doc on `InvestigationFocus.maxTitleLength` enumerated five
    /// clamps and claimed every other such string was bounded, and this one was not.
    ///
    /// It is the expensive one to miss. `persistProposed` builds the vetting claim as summary +
    /// verified basis and hands it to the skeptic panel, the replication analysts and the safety
    /// panel, so a runaway is paid three times over — and the failure is a session killed by the
    /// 4,096-token window, which looks exactly like a rate limit from the outside.
    @Test func `a runaway story cannot reach the vetting panels`() {
        let phrasing = FindingPhrasing.Phrasing(summary: runaway, oneTapTitle: "A finding")
        #expect(phrasing.summary.count <= FindingPhrasing.Phrasing.maxSummaryLength)
        // The claim the panels actually read is summary + basis, and it must stay inside a size a
        // 4k session can hold alongside its prefix, prompt and tool results.
        let claim = "\(phrasing.summary)\n\nVerified basis: \(String(repeating: "x", count: 900))"
        #expect(claim.count < 1600, "the vetting claim ran to \(claim.count) characters")
    }

    /// Ordinary prose must pass through untouched — this clamp is the only one in the app whose
    /// output a person reads, so quietly reshaping a normal summary would be a worse bug than the
    /// one it fixes.
    @Test func `an ordinary summary is not reshaped`() {
        let ordinary = "Your resting heart rate stepped down about a month ago and has stayed there."
        #expect(
            FindingPhrasing.Phrasing(summary: ordinary, oneTapTitle: "t").summary == ordinary
        )
    }

    /// And when it does cut, it cuts on a word — a summary ending mid-word reads as corruption to
    /// the person looking at it, not as a length limit.
    @Test func `a clamped summary ends on a whole word`() {
        let clamped = FindingPhrasing.Phrasing(summary: runaway, oneTapTitle: "t").summary
        #expect(clamped.hasSuffix("…"))
        let body = clamped.dropLast()
        #expect(body.last?.isWhitespace == false, "cut left trailing whitespace: “\(clamped.suffix(20))”")
        // `runaway` repeats whole words, so any prefix ending mid-word would leave a partial one.
        #expect(runaway.hasPrefix(body), "the clamp altered the text it kept")
    }

    /// The clamp lives in the initializer precisely so it cannot be bypassed — the four call sites
    /// (two in the UI, two in `activeInvestigationFoci`) all pass a stored `oneTapTitle` straight
    /// through.
    @Test func `the clamp is on the type, not on any one caller`() {
        #expect(InvestigationFocus(metric: .bodyMass, secondaryMetric: nil, title: runaway)
            .title.count <= InvestigationFocus.maxTitleLength)
        // And a normal title is untouched — clamping must not quietly reshape ordinary output.
        let ordinary = "Sleep debt tracks Monday strain"
        #expect(InvestigationFocus(metric: .bodyMass, secondaryMetric: nil, title: ordinary)
            .title == ordinary)
    }

    @Test func `runaway scout leads and director angles cannot reach an investigator`() {
        let lead = ProposedLead(hypothesis: runaway, metric: runaway, secondaryMetric: runaway)
        for lens in Orchestrator.leadLenses([lead]) {
            #expect(lens.count <= perLensBound, "lead lens ran to \(lens.count) characters")
        }
        for lens in Orchestrator.directorLenses([runaway, runaway]) {
            #expect(lens.count <= perLensBound, "director lens ran to \(lens.count) characters")
        }
        for challenge in Orchestrator.composedChallenges([runaway]) {
            #expect(challenge.count <= perLensBound, "challenge ran to \(challenge.count) characters")
        }
    }

    /// The provenance line is assembled from a lens AND a panel headline — two independently
    /// model-written strings — and unlike the lenses it is also PERSISTED, so an unbounded one would
    /// be re-read on every later pass that quotes the finding.
    @Test func `a runaway lens and panel headline cannot inflate the provenance line`() {
        // Built through the real path — the headline is whichever panelist's `why` decided it, and
        // `why` is model-written free text.
        let panel = PanelOutcome([Verdict(why: runaway, couldTest: true, holdsUp: true)])
        let line = Orchestrator.provenanceLine(lens: runaway, skeptics: panel, replication: panel)
        #expect(line.count <= perLensBound, "provenance line ran to \(line.count) characters")
        #expect(!line.isEmpty)
    }

    /// Clamping must never produce an EMPTY lens: an empty string spends a whole agent session on no
    /// question, which on this device costs the same as a real one.
    @Test func `clamping never empties a lens that had content`() {
        let lead = ProposedLead(
            hypothesis: "sleep leads strain",
            metric: "sleepDurationHours",
            secondaryMetric: "sleepDurationHours"
        )
        #expect(Orchestrator.leadLenses([lead]).allSatisfy { !$0.isEmpty })
        #expect(Orchestrator.directorLenses(["weekday structure"]).allSatisfy { !$0.isEmpty })
        #expect(Orchestrator.composedChallenges(["is the mean driving this?"])
            .allSatisfy { !$0.isEmpty })
        #expect(Orchestrator.focusedLenses(
            InvestigationFocus(metric: .bodyMass, secondaryMetric: nil, title: "Slow drift upward")
        ).allSatisfy { !$0.isEmpty })
    }
}
