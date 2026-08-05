import Foundation

/// Formatting of metric values — in two flavours, because the two readers want opposite things.
///
/// `formatted`/`number` are for the SCREEN and are locale-aware: a German user should see "8.400
/// Schritte". `canonical`/`canonicalNumber` are for the MODEL and are not: they never group
/// thousands and always use a POSIX decimal point.
///
/// That split is not tidiness. The grouping formatter follows `Locale.current`, so on a German
/// device `analyze` used to answer "= 8.400 steps" — which the model reads as 8.4, a thousandfold
/// error in the one place the app promises real numbers. `NumericFidelity` then reparses the same
/// string with `Double(...)`, which is POSIX, and would agree with the wrong reading. In French the
/// separator is a narrow no-break space, which splits "8 400" into two tokens instead. None of this
/// can appear in the test suite: CI runs in en_US, where the grouped form happens to be the one
/// everything downstream assumes.
nonisolated enum MetricFormatting {
    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// The bare display number (transform + precision applied), no unit label.
    static func number(_ value: Double, _ metric: MetricKey) -> String {
        let unit = metric.unitKind
        let shown = unit.display(value)
        if unit.fractionDigits == 0 {
            return grouping.string(from: NSNumber(value: shown.rounded())) ?? "\(Int(shown.rounded()))"
        }
        return String(format: "%.\(unit.fractionDigits)f", shown)
    }

    /// Display number with its unit label, e.g. "8,400 steps", "62 bpm", "97%", "7.3 h".
    static func formatted(_ value: Double, _ metric: MetricKey) -> String {
        let label = metric.unitLabel
        let num = number(value, metric)
        if label.isEmpty { return num }
        if label == "%" { return num + "%" }
        return num + " " + label
    }

    /// The bare display number for a MODEL: display transform and precision applied, but never a
    /// thousands separator, and always a POSIX decimal point. Unambiguous in every locale, which is
    /// the only property that matters when the reader is a language model quoting the figure back.
    static func canonicalNumber(_ value: Double, _ metric: MetricKey) -> String {
        let unit = metric.unitKind
        let shown = unit.display(value)
        // `String(format:)` takes no locale and is therefore POSIX — "7.3", never "7,3".
        return String(format: "%.\(unit.fractionDigits)f", shown)
    }

    /// Canonical number with its unit label — the agent-facing counterpart of `formatted`.
    static func canonical(_ value: Double, _ metric: MetricKey) -> String {
        let label = metric.unitLabel
        let num = canonicalNumber(value, metric)
        if label.isEmpty { return num }
        if label == "%" { return num + "%" }
        return num + " " + label
    }

    /// A signed percentage like `+18%` or `−12%`.
    static func signedPercent(_ pct: Double) -> String {
        let rounded = Int(pct.rounded())
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "±")
        return "\(sign)\(abs(rounded))%"
    }
}
