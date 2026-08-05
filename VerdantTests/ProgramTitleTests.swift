import Foundation
import Testing
@testable import Verdant

/// The headline over the live card, and the moment it stopped being true.
///
/// `isWorking` covers the whole foreground job — the HealthKit catch-up AND the discovery run that
/// follows it — and the headline answered it with a flat "Catching up…". So a real run showed
/// "Catching up…" above a line reading "Investigator 3/13: VOLATILITY shifts", for minutes, while the
/// Neural Engine sat at 100%. Two statements about the same moment, one describing work that had
/// finished long before.
///
/// This was not found by reading the code. It was visible in a screenshot of the app running, which
/// is the only reason it was found at all — the string is correct, the flag is correct, and the two
/// are wrong together.
struct ProgramTitleTests {
    private func title(
        deep: Bool = false, working: Bool = false, awaiting: Bool = false,
        phase: AnalysisProgress.Phase? = nil
    ) -> String {
        InsightFeedView.programTitle(
            isDeepAnalyzing: deep, isWorking: working, isAwaitingModel: awaiting, phase: phase
        )
    }

    /// The defect itself: a narrating run must not be described as fetching data.
    @Test func `a working run reports the phase it is actually in`() {
        #expect(title(working: true, phase: .enhancing) == AnalysisProgress.Phase.enhancing.label)
        #expect(title(working: true, phase: .enhancing) != "Catching up…")
        #expect(title(working: true, phase: .synthesizing) == AnalysisProgress.Phase.synthesizing.label)
    }

    /// And "Catching up…" survives for exactly what it describes — the stretch before any phase has
    /// been reported, which is the real HealthKit catch-up.
    @Test func `work with no phase yet is still catching up`() {
        #expect(title(working: true, phase: nil) == "Catching up…")
        #expect(title(working: true, phase: .idle) == "Catching up…")
    }

    /// The deep run keeps its own headline: it is a different, user-started thing, and its card says
    /// so regardless of which phase it happens to be in.
    @Test func `the deep run outranks the phase`() {
        #expect(title(deep: true, working: true, phase: .scanning) == "Research program running")
    }

    /// The not-running states are unchanged, including the one that must not say "stopped".
    @Test func `an idle program distinguishes waiting from stopped`() {
        #expect(title(awaiting: true) == "Research program waiting")
        #expect(title() == "Research program stopped")
    }
}

/// What an empty feed tells someone, which for this app is the primary experience.
///
/// "Nothing stands out yet" is true for a new install and misleading for anyone else: a full run
/// measured on 2026-08-03 proposed eleven findings and the panels rejected all eleven. Telling that
/// person their data holds nothing notable is the same failure the run's own closing note was fixed
/// for — a clean bill claimed for a pass that was anything but.
struct NothingFoundCopyTests {
    private func copy(_ vetted: Int, running: Bool = false) -> String {
        InsightFeedView.nothingFoundCopy(isDeepAnalyzing: running, candidatesVetted: vetted)
    }

    /// The case the change exists for: candidates were examined and rejected, and the copy says so
    /// rather than implying the data was empty.
    @Test func `a pass that vetted candidates says how many`() {
        let text = copy(11)
        #expect(text.contains("examined 11 candidates"), Comment(rawValue: text))
        #expect(text.contains("none cleared the bar"), Comment(rawValue: text))
    }

    /// A first launch must not be told "0 candidates examined" — there was no pass, and a zero
    /// reads as a failure rather than an absence.
    @Test func `a first launch mentions no count`() {
        let text = copy(0)
        #expect(!text.contains("0"), Comment(rawValue: text))
        #expect(text.contains("none have cleared that bar yet"), Comment(rawValue: text))
    }

    @Test func `one candidate reads as singular`() {
        #expect(copy(1).contains("examined 1 candidate and"), Comment(rawValue: copy(1)))
    }

    /// While a run is going, the count is mid-flight and would change under the reader; the copy
    /// points at the run instead.
    @Test func `a running pass points at the run rather than a partial count`() {
        let text = copy(4, running: true)
        #expect(text.contains("digging now"), Comment(rawValue: text))
        #expect(!text.contains("4"), Comment(rawValue: text))
    }

    /// Every variant still states the bar, which is the part that makes an empty feed intelligible
    /// rather than looking like a broken app.
    @Test func `every variant states the bar`() {
        for text in [copy(0), copy(1), copy(11), copy(3, running: true)] {
            #expect(text.contains("only a handful of genuinely standout findings"), Comment(rawValue: text))
        }
    }
}
