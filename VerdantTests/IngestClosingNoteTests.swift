import Foundation
import Testing
@testable import Verdant

/// "Everything already up to date" is a claim about the user's whole Health library, and it was
/// printed whenever the scan added nothing — including when it read nothing.
///
/// Zero new readings is what a wholesale permission failure looks like, what a HealthKit error
/// across all 72 types looks like, and what pressing Stop three metrics in looks like. All three
/// told the person their library was current and complete.
///
/// The warning lines above the note do fire, so the feed genuinely read "⚠︎ Couldn't read Steps,
/// Weight, Sleep and 40 more" followed immediately by "everything already up to date". A note that
/// contradicts the line above it is not a smaller problem than a silent one — it is the last line
/// on screen and the one a person takes away.
///
/// Same rule the run loop holds one layer up, where `llm` records each outcome so a pass that
/// genuinely found nothing "must not share a closing note" with one where every call failed.
struct IngestClosingNoteTests {
    private let total = MetricKey.allCases.count

    private func note(added: Int = 0, sources: Int = 0, unread: Int = 0, stopped: Bool = false) -> String {
        Ingestor.closingNote(
            added: added, sourcesWithNews: sources, unread: unread, stoppedEarly: stopped
        )
    }

    /// The only case those words were ever true for.
    @Test func `a clean scan with nothing new says so`() {
        #expect(note() == "Ingest done — everything already up to date")
    }

    @Test func `a scan that read nothing does not claim the library is current`() {
        let text = note(unread: total)
        #expect(!text.contains("up to date"), Comment(rawValue: text))
        #expect(text.contains("not one of the \(total)"), Comment(rawValue: text))
    }

    /// The partial case, which is the common one: some types never went through the permission
    /// sheet. The note must scope its "nothing new" to what it could actually see.
    @Test func `a partial scan scopes its claim to the sources it could read`() {
        let text = note(unread: 12)
        #expect(!text.contains("up to date"), Comment(rawValue: text))
        #expect(text.contains("\(total - 12) sources that could be read"), Comment(rawValue: text))
        #expect(text.contains("12 unread"), Comment(rawValue: text))
    }

    /// New data AND unread sources — the success line must not imply completeness either.
    @Test func `new readings alongside unread sources says both`() {
        let text = note(added: 40, sources: 3, unread: 9)
        #expect(text.contains("40 new readings across 3 sources"), Comment(rawValue: text))
        #expect(text.contains("9 sources couldn't be read"), Comment(rawValue: text))
    }

    /// And a clean success stays clean — no dangling "0 sources couldn't be read".
    @Test func `a clean success says nothing about unread sources`() {
        let text = note(added: 40, sources: 3)
        #expect(text.contains("40 new readings across 3 sources"), Comment(rawValue: text))
        #expect(!text.contains("couldn't be read"), Comment(rawValue: text))
    }

    /// Cancellation is its own outcome. A user who pressed Stop after three metrics has not been
    /// told anything true by "everything already up to date", and the anchors mean the rest is
    /// merely deferred — worth saying, because the honest word is "stopped", not "done".
    @Test func `a cancelled scan says it stopped rather than finished`() {
        for added in [0, 40] {
            let text = note(added: added, sources: 3, stopped: true)
            #expect(text.contains("stopped early"), Comment(rawValue: text))
            #expect(!text.contains("Ingest done"), Comment(rawValue: text))
            #expect(!text.contains("up to date"), Comment(rawValue: text))
        }
        #expect(note(added: 40, sources: 3, stopped: true).contains("40 new readings banked"))
    }

    /// Every branch produces a distinct sentence — the defect was two outcomes sharing one.
    @Test func `the outcomes do not share a sentence`() {
        let notes = [
            note(),
            note(unread: total),
            note(unread: 12),
            note(added: 40, sources: 3),
            note(added: 40, sources: 3, unread: 9),
            note(stopped: true),
            note(added: 40, sources: 3, stopped: true)
        ]
        #expect(Set(notes).count == notes.count, "two outcomes read identically: \(notes)")
    }
}
