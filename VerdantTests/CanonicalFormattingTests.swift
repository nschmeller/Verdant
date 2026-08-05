import Foundation
import Testing
@testable import Verdant

/// Numbers are read by two audiences that want opposite things, and until now both got the screen's
/// version. `MetricFormatting.formatted` groups thousands through a `NumberFormatter` with no locale
/// set — so it follows the device. On a German device `analyze` answered "= 8.400 steps", which a
/// model reads as 8.4: a thousandfold error in the one place this app promises real numbers, in the
/// output of the tool agents lean on most.
///
/// The suite cannot see it. CI runs in en_US, where the grouped form is exactly what everything
/// downstream already assumes — the same blind spot as the UTC calendar. So these tests assert the
/// property directly (a canonical string carries no separator at all) and demonstrate the hazard the
/// way this codebase verifies its other locale claims: by building the foreign formatter and showing
/// what it really produces.
struct CanonicalFormattingTests {
    /// The property that matters: whatever the device, an agent-facing number survives being read
    /// back. `NumericFidelity` reparses these strings with `Double(...)`, which is POSIX.
    @Test func `an agent-facing number round-trips through the fidelity parser`() {
        let cases: [(Double, MetricKey)] = [
            (8400, .stepCount),
            (1_234_567, .stepCount),
            (62, .restingHeartRate),
            (7.3, .sleepDurationHours),
            (0.5, .sleepDurationHours)
        ]
        for (value, metric) in cases {
            let text = MetricFormatting.canonical(value, metric)
            let parsed = NumericFidelity.numbers(in: text)
            #expect(parsed.count == 1, "“\(text)” parsed as \(parsed.count) numbers, not one")
            let expected = metric.unitKind.display(value)
            #expect(
                abs((parsed.first?.value ?? .nan) - expected) < 0.05,
                "“\(text)” read back as \(parsed.first?.value ?? .nan), expected ~\(expected)"
            )
        }
    }

    @Test func `an agent-facing number never carries a thousands separator`() {
        for value in [1000.0, 8400, 99999, 1_234_567] {
            let text = MetricFormatting.canonicalNumber(value, .stepCount)
            #expect(!text.contains(","), "“\(text)” has a comma")
            #expect(!text.contains(" "), "“\(text)” has a space separator")
            #expect(!text.contains("\u{202F}"), "“\(text)” has a narrow no-break space")
            // A step count has no fraction digits, so there should be no decimal point either.
            #expect(!text.contains("."), "“\(text)” has a period")
        }
    }

    /// A fractional metric still uses a POSIX point, because `String(format:)` takes no locale.
    @Test func `a fractional agent-facing number uses a POSIX decimal point`() {
        let text = MetricFormatting.canonicalNumber(7.3, .sleepDurationHours)
        #expect(text.contains("."))
        #expect(!text.contains(","))
    }

    /// The hazard, demonstrated rather than asserted — the same technique `CivilCalendar` uses to
    /// show that `ar_SA` really does move the weekend. These are the strings the screen formatter
    /// would produce abroad, and the values the model would take from them.
    @Test func `the localized form really is ambiguous in other locales`() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0

        formatter.locale = Locale(identifier: "de_DE")
        let german = formatter.string(from: NSNumber(value: 8400)) ?? ""
        #expect(german == "8.400", "expected a period separator in de_DE, got “\(german)”")
        // Read back POSIX-style — which is exactly what `NumericFidelity` does — it becomes 8.4.
        #expect(NumericFidelity.numbers(in: german).first?.value == 8.4)

        formatter.locale = Locale(identifier: "fr_FR")
        let french = formatter.string(from: NSNumber(value: 8400)) ?? ""
        // French groups with a narrow no-break space, which splits the token in two instead.
        #expect(NumericFidelity.numbers(in: french).count == 2, "expected “\(french)” to split")

        // The canonical form is immune to both.
        let canonical = MetricFormatting.canonicalNumber(8400, .stepCount)
        #expect(canonical == "8400")
        #expect(NumericFidelity.numbers(in: canonical).first?.value == 8400)
    }

    /// The screen keeps its locale-aware formatting — this split exists so the user still reads
    /// their own conventions, not so everyone reads POSIX.
    @Test func `the user-facing formatter still groups thousands`() {
        // In the test environment (en_US) that means a comma; the point is that grouping happens.
        let shown = MetricFormatting.number(8400, .stepCount)
        #expect(shown != "8400", "the screen formatter should still group; got “\(shown)”")
    }
}
