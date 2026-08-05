import Foundation
import Testing
@testable import Verdant

/// `Calendar.civil` is pinned to UTC so a physical day keys to exactly one rollup wherever the user
/// is. The consequence nobody had written down: the day boundary lands at a different LOCAL hour for
/// every user, and that decides whether a night of sleep is recorded against the day they fell
/// asleep, the day they woke, or is genuinely split.
///
/// The investigator's sleep lens used to assert the split case flatly, which is the least common of
/// the three, and made the fleet discount real one-day lead-lag links — on the app's premium finding
/// type. It now states the actual boundary for the device it is running on, so these are the sums
/// behind a sentence an agent reasons from.
struct CivilDayBoundaryTests {
    private func zone(hours: Int, minutes: Int = 0) throws -> TimeZone {
        try #require(TimeZone(secondsFromGMT: hours * 3600 + minutes * 60))
    }

    @Test func `at UTC the boundary is local midnight and a night is split`() throws {
        let text = try Calendar.civilDayBoundary(in: zone(hours: 0))
        #expect(text.contains("local midnight"))
        #expect(text.contains("split"))
    }

    /// The Americas. The boundary sits in the late afternoon, so a night begins after it and lands
    /// whole on the following civil day — the day the sleeper woke, which is the attribution a
    /// person would expect anyway.
    @Test func `west of UTC a night lands wholly on the wake day`() throws {
        for offset in [-8, -7, -5, -3] {
            let text = try Calendar.civilDayBoundary(in: zone(hours: offset))
            #expect(text.contains("WOKE"), "UTC\(offset): \(text)")
            #expect(!text.contains("split"), "UTC\(offset) should not claim a split")
        }
        #expect(try Calendar.civilDayBoundary(in: zone(hours: -8)).contains("16:00"))
        #expect(try Calendar.civilDayBoundary(in: zone(hours: -5)).contains("19:00"))
    }

    /// Europe through Asia. The boundary is in the morning, so a night completes before it and is
    /// recorded against the day the sleeper went to bed.
    @Test func `east of UTC a night lands wholly on the sleep-onset day`() throws {
        for offset in [1, 3, 5, 9] {
            let text = try Calendar.civilDayBoundary(in: zone(hours: offset))
            #expect(text.contains("FELL ASLEEP"), "UTC+\(offset): \(text)")
            #expect(!text.contains("split"), "UTC+\(offset) should not claim a split")
        }
        #expect(try Calendar.civilDayBoundary(in: zone(hours: 9)).contains("09:00"))
        #expect(try Calendar.civilDayBoundary(in: zone(hours: 1)).contains("01:00"))
    }

    /// Half- and quarter-hour zones are real (India, Nepal, Chatham Islands) and must not round to
    /// something the user would read as wrong.
    @Test func `offsets that are not whole hours keep their minutes`() throws {
        #expect(try Calendar.civilDayBoundary(in: zone(hours: 5, minutes: 30)).contains("05:30"))
        #expect(try Calendar.civilDayBoundary(in: zone(hours: 5, minutes: 45)).contains("05:45"))
        #expect(try Calendar.civilDayBoundary(in: zone(hours: -3, minutes: -30)).contains("20:30"))
    }

    /// Whatever the zone, the sentence must be usable: it always names a boundary and always says
    /// what that means for a night, because an agent that reads only half of it would be worse off
    /// than one told nothing.
    @Test func `every offset produces a complete, actionable sentence`() throws {
        for offset in stride(from: -12, through: 14, by: 1) {
            let text = try Calendar.civilDayBoundary(in: zone(hours: offset))
            #expect(!text.isEmpty)
            #expect(
                text.contains("WOKE") || text.contains("FELL ASLEEP") || text.contains("split"),
                "UTC\(offset) said nothing about where a night lands: \(text)"
            )
        }
    }

    /// A day key rendered for an agent must name the day the DATA is keyed to, in every time zone.
    /// `Date.formatted(date:time:)` renders in `TimeZone.current`, so a UTC-midnight key displayed as
    /// the previous date for every user west of UTC: a strange day stored as 2026-07-17 reached the
    /// agent — and the user — as "Jul 16, 2026" throughout the Americas.
    @Test func `an agent-facing day label names the civil day, not the local one`() throws {
        let day = try #require(
            Calendar.civil.date(from: DateComponents(year: 2026, month: 7, day: 17))
        )
        #expect(Calendar.civilDayLabel(day) == "2026-07-17")

        // The bug it replaces, demonstrated: the same instant rendered in a western zone.
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(day.formatted(style).contains("16"), "expected the old rendering to slip a day")

        // The label is stable whatever the device is set to, because it does not consult it.
        #expect(Calendar.civilDayLabel(day) == "2026-07-17")
    }

    /// Zero-padded and ISO-ordered, so it cannot be read as a different date in another convention
    /// and it sorts as text.
    @Test func `day labels are zero-padded and ISO-ordered`() throws {
        let day = try #require(
            Calendar.civil.date(from: DateComponents(year: 2026, month: 1, day: 5))
        )
        #expect(Calendar.civilDayLabel(day) == "2026-01-05")
    }

    /// The lens the fleet actually reads must carry the fact, not just the helper.
    @Test func `the sleep lens states the device's real boundary`() {
        let sleepLens = Instructions.investigationLenses.first { $0.contains("sleep") }
        let lens = sleepLens ?? ""
        #expect(!lens.isEmpty, "no sleep lens in the roster")
        #expect(
            lens.contains("WOKE") || lens.contains("FELL ASLEEP") || lens.contains("split"),
            "the sleep lens no longer states where a night lands: \(lens)"
        )
    }
}
