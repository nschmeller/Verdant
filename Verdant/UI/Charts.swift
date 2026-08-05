import Charts
import SwiftUI

/// A compact sparkline of a single metric's recent daily values — the small chart shown inside an
/// insight card. Loads its own series from the model; renders nothing until there's enough data.
struct MetricSparkline: View {
    let metric: MetricKey
    var days = 30
    /// When true, plot the day-to-day SWING (the absolute change from the prior reading) rather than the
    /// level. A volatility finding is about spread, not the average — which may be unchanged — so a level
    /// line would look flat and contradict the card; the swing line shows the very thing the finding is
    /// about.
    var variability = false
    @Environment(AppModel.self) private var model
    @State private var points: [DailyPoint] = []

    /// The series actually charted: raw daily levels, or — for a volatility finding — the day-to-day swing.
    private var plotted: [DailyPoint] {
        variability ? Self.swingSeries(points) : points
    }

    /// |change from the previous reading|, per day.
    ///
    /// Pure and internal so it can be tested: the volatility card's whole argument is that a LEVEL
    /// line would look flat while the metric's spread was changing, so the picture has to show the
    /// spread instead. If this returned levels — or the flag were ignored — the card would claim a
    /// metric "grew markedly more erratic" above a line that visibly does not, and nothing would
    /// fail. A chart that contradicts its own caption is the same defect as a wrong number.
    static func swingSeries(_ points: [DailyPoint]) -> [DailyPoint] {
        let sorted = points.sorted { $0.day < $1.day }
        return zip(sorted.dropFirst(), sorted).map { later, earlier in
            DailyPoint(day: later.day, value: abs(later.value - earlier.value))
        }
    }

    var body: some View {
        Group {
            if plotted.count >= 4 {
                Chart(plotted) { point in
                    AreaMark(
                        x: .value("Day", point.day),
                        y: .value(metric.displayName, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.brand.opacity(0.28), Theme.brand.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value(metric.displayName, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.brand)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    variability
                        ? "Day-to-day swing in \(metric.displayName), last \(days) days"
                        : "\(metric.displayName), last \(days) days"
                )
                .accessibilityValue(trajectory)
            }
        }
        .task(id: "\(metric.rawValue)|\(days)") { points = await model.series(for: metric, days: days) }
    }

    /// Speaks the same shape a sighted user reads off the line so a VoiceOver user isn't left with an
    /// unlabeled chart: the swing's range for a variability sparkline, else the level's start/end/range.
    private var trajectory: String {
        let values = plotted.map(\.value)
        guard let first = values.first, let last = values.last,
              let low = values.min(), let high = values.max() else { return "" }
        if variability {
            return "Day-to-day swing ranged \(MetricFormatting.formatted(low, metric)) to "
                + "\(MetricFormatting.formatted(high, metric))."
        }
        return "From \(MetricFormatting.formatted(first, metric)) to "
            + "\(MetricFormatting.formatted(last, metric)); ranged "
            + "\(MetricFormatting.formatted(low, metric)) to \(MetricFormatting.formatted(high, metric))."
    }
}

/// A single normalized series point used by the dual-line correlation chart.
struct NormalizedPoint: Identifiable {
    let day: Date
    let value: Double
    let series: String

    var id: String {
        "\(series)-\(day.timeIntervalSince1970)"
    }
}

/// A dual-line chart showing two metrics' day-to-day *changes*, each z-normalized so their shapes
/// are comparable on one axis. It plots changes — not levels — because that's exactly what the
/// correlation coefficient is computed on; charting levels would let two co-trending lines imply a
/// link the coefficient never measured (or visually contradict one it did). Loads both series itself.
struct CorrelationChart: View {
    let metricA: MetricKey
    let metricB: MetricKey
    /// Days `metricA` leads `metricB`; the trailing series is shifted back by this so co-moving days
    /// overlay (matching how the coefficient pairs them), instead of contradicting the claim.
    var lag = 0
    var days = 60
    @Environment(AppModel.self) private var model
    @State private var points: [NormalizedPoint] = []

    var body: some View {
        Group {
            if points.count >= 8 {
                Chart(points) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Normalized", point.value),
                        series: .value("Metric", point.series)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Metric", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                .chartForegroundStyleScale([
                    metricA.displayName: Theme.brand,
                    metricB.displayName: Direction.down.tint
                ])
                .chartLegend(.hidden)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(.quaternary)
                    }
                }
                .frame(height: 96)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Chart of the day-to-day changes in \(metricA.displayName) and "
                        + "\(metricB.displayName), overlaid so their shapes can be compared. "
                        + "The connection itself is described above."
                )
            }
        }
        .task(id: "\(metricA.rawValue)|\(metricB.rawValue)|\(lag)") { points = await load() }
    }

    private func load() async -> [NormalizedPoint] {
        async let aSeries = model.series(for: metricA, days: days)
        async let bSeries = model.series(for: metricB, days: days)
        let changesA = await Self.changeSeries(aSeries)
        let changesB = await Self.changeSeries(bSeries)
        let normalizedA = Self.normalize(changesA, name: metricA.displayName, shiftDays: 0)
        // Shift the trailing metric back by the lead/lag so co-moving days line up on the axis.
        let normalizedB = Self.normalize(changesB, name: metricB.displayName, shiftDays: -lag)
        return normalizedA + normalizedB
    }

    /// Day-to-day changes (first differences), winsorized exactly as the engine does before
    /// correlating, returned as sorted points — so the chart shows the same signal the coefficient
    /// was computed on rather than the raw levels.
    ///
    /// Internal rather than private so `CorrelationChartTests` can check it against the engine: these
    /// two must agree, and "agrees with `CorrelationEngine`" is not a property a view can assert
    /// about itself.
    static func changeSeries(_ series: [DailyPoint]) -> [DailyPoint] {
        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        let changes = CorrelationEngine.winsorize(CorrelationEngine.firstDifferences(byDay))
        return changes.map { DailyPoint(day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
    }

    /// z-normalize a change series so two metrics on different scales share one axis, optionally
    /// shifting each point's day by `shiftDays` to align a lead/lag relationship.
    ///
    /// The SIGN of that shift is the load-bearing part and the reason this is testable: the engine
    /// pairs lead-day `d` with trail-day `d + lag`, so the trail series must move BACK by `lag` for
    /// co-moving days to land on the same x. Flip it and the chart is misaligned by twice the lag —
    /// two lines that visibly fail to move together, under a card saying they do.
    static func normalize(_ series: [DailyPoint], name: String, shiftDays: Int) -> [NormalizedPoint] {
        let values = series.map(\.value)
        let mean = MetricStatsProvider.mean(values)
        let sd = MetricStatsProvider.sampleStandardDeviation(values)
        guard sd > 0 else { return [] }
        let calendar = Calendar.civil
        return series.map { point in
            let day = shiftDays == 0
                ? point.day
                : calendar.startOfDay(for: calendar.date(byAdding: .day, value: shiftDays, to: point.day)!)
            return NormalizedPoint(day: day, value: (point.value - mean) / sd, series: name)
        }
    }
}

/// A small badge encoding a correlation's sign and strength (e.g. a green up-chevron for a positive
/// association). Reads at a glance without exposing the raw coefficient as the headline.
struct StrengthBadge: View {
    let coefficient: Double

    private var positive: Bool {
        coefficient >= 0
    }

    private var strengthWord: String {
        CorrelationStrength.word(absoluteCoefficient: abs(coefficient))
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
            Text(strengthWord)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(positive ? Theme.brand : Direction.down.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((positive ? Theme.brand : Direction.down.tint).opacity(0.14))
        )
        // The chevron carries the sign; spell it out so VoiceOver doesn't read a bare "slight".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(strengthWord) \(positive ? "positive" : "negative") association")
    }
}
