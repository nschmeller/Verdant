import SwiftUI

/// One single-metric finding, as a card with a sparkline of the metric's recent trajectory.
struct InsightRow: View {
    let insight: InsightLog

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.brand)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 7) {
                Text(insight.oneTapTitle)
                    .font(.headline)
                Text(insight.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let metric = insight.metricKey {
                    // A volatility finding is about day-to-day spread, so its sparkline plots the swing,
                    // not the (possibly unchanged) level — the chart then shows what the card describes.
                    MetricSparkline(
                        metric: metric,
                        days: sparklineDays,
                        variability: FindingPresentation.of(insight.insightKind).plotsVariability
                    )
                    verifiedNumbers(metric)
                }
                HStack(spacing: 8) {
                    Text(insight.createdAt, format: .relative(presentation: .named))
                    if let metric = insight.metricKey {
                        Text(metric.displayName)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.brandSoft))
                            .foregroundStyle(Theme.brandDeep)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    /// Days the sparkline should span. A regime shift or milestone is *about* a change that may sit
    /// well outside a 30-day window — so the chart must reach back far enough to actually show it
    /// (the new level's full tenure, or the span the record stands over), plus a little context.
    /// `sampleCount` holds those calendar spans for those kinds. Capped so an old metric can't load
    /// an unbounded range. Other kinds keep the recent window.
    private var sparklineDays: Int {
        FindingPresentation.of(insight.insightKind).sparklineDays(sampleCount: insight.sampleCount)
    }

    /// The deterministic, auditable numbers behind the model's prose — so the finding can be
    /// checked, not just trusted. Trusted because they come straight from the verified statistic.
    ///
    /// The text itself is `FindingCardLine`, which is where each kind's reading of the shared
    /// `verified*`/`sampleCount` columns lives and is tested. It was inline here, inside a
    /// `some View`, and therefore unreachable by any test.
    private func verifiedNumbers(_ metric: MetricKey) -> some View {
        Text(FindingCardLine.text(for: insight, metric: metric))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

/// One cross-source correlation, as a card with a dual-line chart of the two normalized signals.
/// This is the app's signature finding: a subtle, non-obvious link between two different streams.
struct CorrelationRow: View {
    let correlation: CorrelationLog

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.brandDeep)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Cross-signal link", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.brandDeep)
                    Spacer()
                    StrengthBadge(coefficient: correlation.coefficient)
                }
                Text(correlation.oneTapTitle)
                    .font(.headline)
                Text(correlation.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let metricA = correlation.metricAKey, let metricB = correlation.metricBKey {
                    CorrelationChart(metricA: metricA, metricB: metricB, lag: correlation.lag)
                    HStack(spacing: 14) {
                        legend(metricA.displayName, Theme.brand)
                        legend(metricB.displayName, Direction.down.tint)
                        Spacer(minLength: 0)
                        Text("day-to-day change — illustrative").font(.caption2).foregroundStyle(.tertiary)
                    }
                    verifiedFacts(metricA, metricB)
                }
            }
        }
        .card()
    }

    /// Deterministic, auditable facts behind the link: direction, timing, breadth of data, and that
    /// it survived the activity control. These are trusted (from the verified statistic); the chart
    /// above is only an illustrative recent window of the full multi-year relationship.
    /// KNOWN LIMITATION (2026-08-02). These facts describe the WHOLE record. A finding about a
    /// relationship that CHANGED — one that ran strong for two years and stopped, which the
    /// changed-relationships lens now invites — is true here and incomplete: the badge and "Move
    /// together" state a coefficient the pair no longer has, beside prose saying it ended. Nothing
    /// shown is false, and the dual-line chart above does show the divergence, but the card cannot
    /// express the claim its own story is making.
    ///
    /// Deliberately not fixed here. A faithful card is a new finding type — its own copy, its own
    /// numbers, its own chart span — which is a product decision, not a refactor. The interim is a
    /// clause in the lens telling the investigator that this number sits beside its words, so the
    /// prose names the stretch it means. Recorded in ARCHITECTURE as an open item.
    private func verifiedFacts(_ metricA: MetricKey, _: MetricKey) -> some View {
        let direction = correlation.coefficient >= 0 ? "Move together" : "Move oppositely"
        let timing = correlation.lag == 0
            ? "same day"
            : "\(metricA.displayName) leads by ~\(correlation.lag)d"
        var parts = [direction, timing, "across ~\(correlation.sampleCount) days"]
        // Claim the activity control only when it actually happened (persisted at detection time):
        // a pair that already includes activity, or a user with no activity data to control with,
        // was never partialled — and we must not advertise a control we didn't run.
        if correlation.activityControlled {
            parts.append("not just activity")
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Persistent regulatory framing. Wellness/informational, non-diagnostic.
struct DisclaimerBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(Theme.brand)
            Text("Informational and wellness only — not medical advice or a diagnosis.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.bar)
    }
}

/// Surfaces the on-device model's runtime state. Hidden when the model is ready.
struct AvailabilityBanner: View {
    let capability: LLMCapability

    var body: some View {
        switch capability {
        case .available:
            EmptyView()
        case .downloading:
            banner(
                icon: "arrow.down.circle.fill",
                text: "Preparing on-device intelligence — your findings will appear once it's ready."
            )
        case .notEnabled:
            banner(
                icon: "wand.and.stars",
                text: "Verdant's findings are written by Apple Intelligence. Turn it on in "
                    + "Settings → Apple Intelligence & Siri, and they'll start appearing."
            )
        case .unavailableForever:
            banner(
                icon: "cpu.fill",
                text: "Verdant's findings are written by on-device intelligence, which this iPhone "
                    + "can't run. They'll appear on a device that supports Apple Intelligence."
            )
        }
    }

    private func banner(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.brand)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
