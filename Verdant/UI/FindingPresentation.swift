import Foundation

/// Everything the feed and detail screens say about ONE kind of finding, decided in one place by an
/// EXHAUSTIVE switch.
///
/// This exists because of a bug that shipped. Four separate `switch insight.insightKind` sites — the
/// navigation title, the "what this is" explanation, the "how Verdant found this" method, and the
/// sparkline span — each ended in `default`, and a `default` over a closed domain enum is not
/// neutral: here it was the ANOMALY treatment. When `seasonal` was added, an annual rhythm silently
/// inherited the title "Insight", the explanation "a change that stood out from its usual
/// day-to-day range", the anomaly methodology, and a 30-day chart — four user-facing statements,
/// every one false for a claim about January, and not one of them a test failure or a compiler
/// warning.
///
/// Exhaustive switches over `InsightKind` turn the next such omission into a build error. That is
/// the only mechanism that actually works for "someone will add a case later", because the failure
/// mode is *unwritten code*, which no test can see.
nonisolated struct FindingPresentation {
    /// Detail-screen navigation title.
    let title: String
    /// Plain-language "what this is", written for someone who did not ask for statistics.
    let whatThisIs: String
    /// "How Verdant found this" — the honest method, including the panels.
    let method: String
    /// Whether the sparkline should plot day-to-day SWING rather than level.
    let plotsVariability: Bool

    /// Days the sparkline should span. A regime shift, milestone or annual rhythm is *about* a
    /// change that may sit well outside a 30-day window, so the chart has to reach far enough to
    /// actually show it. `sampleCount` holds the relevant span for those kinds. Capped so an old
    /// metric cannot load an unbounded range.
    func sparklineDays(sampleCount: Int) -> Int {
        switch span {
        case .recent: 30
        case let .plusDays(extra, cap): min(cap, sampleCount + extra)
        case let .years(cap): min(cap, max(2, sampleCount) * 365)
        }
    }

    private let span: Span

    private enum Span {
        case recent
        case plusDays(extra: Int, cap: Int)
        case years(cap: Int)
    }

    // MARK: The one exhaustive mapping

    static func of(_ kind: InsightKind) -> FindingPresentation {
        switch kind {
        case .volatility:
            FindingPresentation(
                title: "Volatility",
                whatThisIs: "This is about how *steady* the metric has been — its day-to-day swing — "
                    + "rather than its average, which may be unchanged.",
                method: "Verdant compared how much this metric swings day to day now against its "
                    + "longer baseline, then put the shift through a panel of independent skeptics "
                    + "and analysts who re-tested it against your data.",
                plotsVariability: true,
                span: .recent
            )
        case .milestone:
            FindingPresentation(
                title: "Milestone",
                whatThisIs: "This marks a record stretch: the most extreme run for this metric in a "
                    + "long while. A record can be a real shift or a temporary peak that reverts — "
                    + "the chart's reach back over the record's span shows which.",
                method: "Verdant checked every recent stretch of this metric against your history to "
                    + "confirm it's a genuine record, then put it through a panel of independent "
                    + "skeptics and analysts who re-tested it against your data.",
                plotsVariability: false,
                span: .plusDays(extra: 14, cap: 400)
            )
        case .regimeShift:
            FindingPresentation(
                title: "Shift",
                whatThisIs: "This is a baseline that moved and then stayed moved — a lasting step to "
                    + "a new level, not a one-off blip.",
                method: "Verdant found the day this metric stepped to a new level, confirmed it has "
                    + "held since rather than being a blip, then put it through a panel of "
                    + "independent skeptics and analysts who re-tested it against your data.",
                plotsVariability: false,
                span: .plusDays(extra: 30, cap: 400)
            )
        case .seasonal:
            FindingPresentation(
                title: "Yearly rhythm",
                whatThisIs: "This is a pattern that comes back every year — particular months running "
                    + "high or low against the rest of that same year, rather than a one-off change. "
                    + "It says nothing about where the metric is heading overall.",
                method: "Verdant compared each month against its own year — removing any long-run "
                    + "drift, so a steady climb can't masquerade as a season — checked that the "
                    + "pattern repeated across years, then put it through a panel of independent "
                    + "skeptics and analysts who re-tested it against your data.",
                plotsVariability: false,
                span: .years(cap: 1200)
            )
        // The level-change kinds share one presentation. Listed explicitly rather than defaulted:
        // that is the entire point of this type. `redFlag` is a reserved raw value the app no longer
        // produces, and `correlation` findings never reach here (they render as their own card), but
        // both must still be named or the switch is not exhaustive — which is the protection.
        case .trend, .anomaly, .correlation, .redFlag, .none:
            FindingPresentation(
                title: "Insight",
                whatThisIs: "A change in this metric that stood out from its usual day-to-day range — "
                    + "surfaced because it's unlikely to be noise.",
                method: "Verdant compared your recent reading against its usual range, confirmed the "
                    + "change with the numbers behind it, then put it through a panel of independent "
                    + "skeptics and analysts who re-tested it against your data.",
                plotsVariability: false,
                span: .recent
            )
        }
    }

    /// A row whose stored `kind` no longer resolves (a vocabulary change) gets the neutral
    /// presentation rather than crashing or claiming something specific.
    static func of(_ kind: InsightKind?) -> FindingPresentation {
        of(kind ?? .trend)
    }
}
