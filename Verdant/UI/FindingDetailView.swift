import SwiftUI

/// The full-screen detail for one finding, reached by tapping its card. It re-shows the card (chart,
/// verified numbers, story) and then adds the context the compact feed omits: what this *kind* of
/// finding means and how to read it, and when it surfaced — so a tap always deepens understanding
/// rather than merely repeating the card.
struct FindingDetailView: View {
    enum Finding {
        case insight(InsightLog)
        case correlation(CorrelationLog)
    }

    let finding: Finding
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                card
                meaningSection
                methodologySection
                investigateSection
                surfacedRow
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { DisclaimerBar() }
    }

    // MARK: Dig deeper

    /// The finding as an investigation anchor — nil only if its metric key no longer resolves
    /// (e.g. a finding persisted before a registry change).
    private var investigationFocus: InvestigationFocus? {
        switch finding {
        case let .insight(insight):
            guard let metric = insight.metricKey else { return nil }
            return InvestigationFocus(metric: metric, secondaryMetric: nil, title: insight.oneTapTitle)
        case let .correlation(correlation):
            guard let metricA = correlation.metricAKey else { return nil }
            return InvestigationFocus(
                metric: metricA,
                secondaryMetric: correlation.metricBKey,
                title: correlation.oneTapTitle
            )
        }
    }

    private var askQuestion: String {
        switch finding {
        case let .insight(insight):
            let name = insight.metricKey?.displayName ?? insight.metric
            return "Tell me more about my \(name) — you surfaced “\(insight.oneTapTitle)”. "
                + "What sits behind it, and how has it moved over the long run?"
        case let .correlation(correlation):
            let nameA = correlation.metricAKey?.displayName ?? correlation.metricA
            let nameB = correlation.metricBKey?.displayName ?? correlation.metricB
            return "How do my \(nameA) and \(nameB) relate? You surfaced "
                + "“\(correlation.oneTapTitle)” — dig into that link for me."
        }
    }

    /// The finding as a launchpad: point the investigator fleet at it, or hand it to the Ask agent.
    private var investigateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dig deeper", systemImage: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brandDeep)
            if let focus = investigationFocus {
                Button {
                    // The drill-down outranks the always-on program: it interrupts it, runs the
                    // focused fleet, then the program resumes on its own. Pop back to the feed —
                    // that's where the live progress shows now.
                    Task { await model.investigateFurther(focus: focus) }
                    dismiss()
                } label: {
                    Label("Investigate this further", systemImage: "wand.and.stars")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.capability.isAvailable)
            }
            Button {
                model.pendingQuestion = askQuestion
                model.selectedTab = .ask
            } label: {
                Label("Ask about this", systemImage: "text.bubble")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(
                "“Investigate” points the whole agent fleet at this finding — what leads it, its "
                    + "multi-year arc, its day-of-week shape, and a deliberate attempt to knock it "
                    + "down; watch it live at the top of your Insights feed. “Ask” hands it to the "
                    + "chat agent for a conversational dig."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var navigationTitle: String {
        switch finding {
        case .correlation: "Connection"
        case let .insight(insight):
            FindingPresentation.of(insight.insightKind).title
        }
    }

    @ViewBuilder private var card: some View {
        switch finding {
        case let .insight(insight): InsightRow(insight: insight)
        case let .correlation(correlation): CorrelationRow(correlation: correlation)
        }
    }

    private var meaningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What this means", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brandDeep)
            Text(meaningText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// A plain-language explanation of the finding's *type* — what it captures and how to read it.
    private var meaningText: String {
        switch finding {
        case let .correlation(correlation):
            "These two signals "
                +
                (correlation
                    .coefficient >= 0 ? "tend to move together" : "tend to move in opposite directions")
                + " in your day-to-day changes"
                + (correlation.activityControlled
                    ? " — and the link held even after accounting for how active you were on a given day"
                    : "")
                + ". It's an association Verdant noticed across your history, not cause and effect, "
                + "and never a diagnosis."
        case let .insight(insight):
            FindingPresentation.of(insight.insightKind).whatThisIs
        }
    }

    private var methodologySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How Verdant found this", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brandDeep)
            Text(methodologyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // What actually happened to THIS finding, not the general description above: which
            // specialist proposed it, how each panel voted, and a panelist's own words. Absent for
            // findings persisted before provenance was recorded, and for any the panels never ran on.
            if !provenance.isEmpty {
                Divider().padding(.vertical, 2)
                Text(provenance)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var provenance: String {
        switch finding {
        case let .insight(insight): insight.provenance
        case let .correlation(correlation): correlation.provenance
        }
    }

    /// Plain-language transparency into the process behind the finding.
    ///
    /// Deliberately states no panel SIZES. It used to promise "six independent skeptics … and three
    /// analysts", which was exact when every finding faced identical panels — but the skeptic and
    /// replication panels are now sized to the claim (an agent adds challenges and re-tests only
    /// this finding needs), so those numbers became a floor quoted as a fact, and understated the
    /// scrutiny besides. The real tallies are right below this, in the finding's own provenance
    /// line, which reports what actually ran. Describing the process here and letting the record
    /// speak for the counts is both honest and more informative than either alone.
    private var methodologyText: String {
        switch finding {
        case let .correlation(correlation):
            "Verdant compared the day-to-day changes in these two signals across your history, "
                + (correlation.activityControlled
                    ? "kept only a link that held even after accounting for how active you were on each day, "
                    : "kept only a statistically robust link, ")
                + "and then put it through a panel of independent skeptics, a safety review, and "
                + "analysts who re-tested it against your data — keeping it only if it survived "
                + "them all."
        case let .insight(insight):
            FindingPresentation.of(insight.insightKind).method
        }
    }

    private var surfacedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.caption2)
            Text("Surfaced \(surfacedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var surfacedAt: Date {
        switch finding {
        case let .insight(insight): insight.createdAt
        case let .correlation(correlation): correlation.createdAt
        }
    }
}
