import SwiftData
import SwiftUI

/// The Trends dashboard — held to the same bar as the findings: no obvious per-metric readouts,
/// only the subtle structure the engine uncovers. It leads with a constellation map of the
/// discovered cross-source connections, then shows each connection in detail with its dual-line
/// chart. When there are no connections yet, it says so plainly rather than padding with filler.
struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<CorrelationLog> { $0.tombstoned == false })
    private var correlations: [CorrelationLog]

    /// Best connections first, by the app's own judgment of "best" — `quality`, which blends the
    /// agent's `worth` with the statistical `trustStrength`, and is what curation and the audit
    /// docket already sort by.
    ///
    /// This used to sort on `abs(coefficient)` alone. Signed order was never right (a weak positive
    /// link would outrank a strong inverse one like sleep ↔ resting heart rate), but magnitude alone
    /// was not either, and the comment justifying it claimed to match "how the engine and curation
    /// value a correlation" — curation sorts by `quality`, and the engine's internal `strength` is a
    /// lag-selection term, not a verdict on worth.
    ///
    /// The difference is the whole editorial premise. `SalienceSourceTests` spells it out for
    /// single-metric findings: a statistical magnitude measures BIGNESS, which usually means
    /// obviousness, so leading with it "would promote the loud, predictable changes this app exists
    /// to filter out". The feed ranks by the agent's judgment; this screen was ranking the same
    /// findings by the loudest number and putting a different one first.
    ///
    /// Magnitude survives as the tie-break, so two equally-judged links still order sensibly.
    private var byQuality: [CorrelationLog] {
        Self.ordered(correlations)
    }

    /// The comparison itself, `static` so it can be tested: this is a view, and the ordering is the
    /// only part of it with a decision in it.
    static func ordered(_ correlations: [CorrelationLog]) -> [CorrelationLog] {
        correlations.sorted {
            $0.quality == $1.quality
                ? abs($0.coefficient) > abs($1.coefficient)
                : $0.quality > $1.quality
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if correlations.isEmpty {
                        emptyState
                    } else {
                        mapSection
                        detailSection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Trends")
            .safeAreaInset(edge: .bottom) { DisclaimerBar() }
        }
        .tint(Theme.brand)
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Your connection map",
                systemImage: "point.3.connected.trianglepath.dotted",
                subtitle: "How your health signals move with one another"
            )
            ConnectionMap(correlations: byQuality)
        }
        .card()
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "What's moving together",
                systemImage: "chart.xyaxis.line",
                subtitle: "See how each pair tracks — or pulls against — the other over the years"
            )
            ForEach(byQuality) { correlation in
                NavigationLink {
                    FindingDetailView(finding: .correlation(correlation))
                } label: {
                    CorrelationRow(correlation: correlation)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No connections yet", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text(
                "Verdant maps only genuine, non-obvious links between your health signals — the kind "
                    + "that hold up even after accounting for how active you were — and none have "
                    + "cleared that bar yet. They'll appear as your history builds, or with a deep analysis."
            )
        }
        .padding(.top, 60)
    }

    private func sectionHeader(_ title: String, systemImage: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Theme.brandDeep)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
