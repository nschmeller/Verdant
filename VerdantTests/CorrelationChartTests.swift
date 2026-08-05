import Foundation
import Testing
@testable import Verdant

/// The dual-line correlation chart is the only place a user can SEE a finding rather than read it,
/// and it makes two claims that nothing checked: that it plots the same signal the coefficient was
/// computed on (day-to-day changes, winsorized — not raw levels), and that a lead/lag finding's two
/// lines are aligned so co-moving days share an x position.
///
/// Both fail quietly. Plot levels instead of changes and two metrics whose CHANGES track can look
/// unrelated; flip the shift's sign and the lines are misaligned by twice the lag. Either way the
/// card's caption still says they move together, and the picture argues against the number beside it.
struct CorrelationChartTests {
    private let calendar = Calendar.civil

    private var anchor: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17))!
    }

    private func points(_ values: [Double]) throws -> [DailyPoint] {
        try values.enumerated().map { index, value in
            try DailyPoint(
                day: #require(calendar.date(byAdding: .day, value: index, to: anchor)),
                value: value
            )
        }
    }

    /// The chart's change series must be exactly what the engine correlates — same first differences,
    /// same winsorization — not a lookalike computed a second way.
    @Test func `the chart plots the engine's own change series`() throws {
        let levels = [10.0, 14, 11, 30, 12, 13, 9, 40, 11, 12]
        let series = try points(levels)
        let charted = CorrelationChart.changeSeries(series)

        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        let engine = CorrelationEngine.winsorize(CorrelationEngine.firstDifferences(byDay))

        #expect(!charted.isEmpty)
        #expect(charted.count == engine.count, "chart plots \(charted.count), engine uses \(engine.count)")
        for point in charted {
            #expect(engine[point.day] == point.value, "chart and engine disagree on \(point.day)")
        }
        // First differences, so one fewer point than levels — a chart of raw levels would have all 10.
        #expect(charted.count == levels.count - 1)
    }

    @Test func `normalizing puts both metrics on one axis`() throws {
        let normalized = try CorrelationChart.normalize(
            points([1, 2, 3, 4, 5, 6, 7, 8]), name: "A", shiftDays: 0
        )
        let values = normalized.map(\.value)
        #expect(abs(MetricStatsProvider.mean(values)) < 0.0001)
        #expect(abs(MetricStatsProvider.sampleStandardDeviation(values) - 1) < 0.0001)
    }

    /// The alignment, checked against the engine's own convention rather than against itself.
    ///
    /// Honest limitation: this pins the HELPER's behaviour for a given `shiftDays`, not that `load()`
    /// passes `-lag` rather than `+lag`. `load()` is private, async and bound to the view's model, so
    /// the call site is out of reach here — the same mechanism-versus-wiring split that let the
    /// barren-angle feature nearly ship inert. The sign is stated in the helper's own documentation
    /// and asserted below as a direction, which is as close as this seam allows.
    ///
    /// The engine pairs lead-day `d` with trail-day `d + lag`. So a trail point recorded on day
    /// `d + lag` must be DRAWN at `d` — shifted back by the lag — for the two lines to overlay.
    @Test func `a lagging metric is shifted back so co-moving days share an x`() throws {
        let lag = 2
        let trail = try points([1, 2, 3, 4, 5, 6, 7, 8])
        let drawn = CorrelationChart.normalize(trail, name: "B", shiftDays: -lag)

        #expect(drawn.count == trail.count)
        for (original, shown) in zip(trail, drawn) {
            let expected = try #require(
                calendar.date(byAdding: .day, value: -lag, to: original.day)
            )
            #expect(shown.day == expected, "trail point drawn at \(shown.day), expected \(expected)")
        }
        // The direction matters, not just the magnitude: shifting FORWARD would double the error.
        let firstDrawn = try #require(drawn.first).day
        let firstOriginal = try #require(trail.first).day
        #expect(firstDrawn < firstOriginal, "the trailing metric was shifted the wrong way")
    }

    /// A flat series has no shape to normalize, and dividing by a zero SD would produce NaNs on a
    /// chart axis. It must draw nothing instead.
    @Test func `a flat series is dropped rather than drawn as NaN`() throws {
        #expect(try CorrelationChart.normalize(
            points([5, 5, 5, 5]), name: "A", shiftDays: 0
        ).isEmpty)
    }
}

/// The volatility card's sparkline plots day-to-day SWING, not level — and that choice is the card's
/// entire argument. A volatility finding says the metric grew more erratic *while its average held*,
/// so a level line would look flat and quietly contradict the sentence above it.
struct SwingSparklineTests {
    private let calendar = Calendar.civil

    private func points(_ values: [Double]) throws -> [DailyPoint] {
        let anchor = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        return try values.enumerated().map { index, value in
            try DailyPoint(
                day: #require(calendar.date(byAdding: .day, value: index, to: anchor)),
                value: value
            )
        }
    }

    /// The case the card is FOR: an unchanged average with a widening swing. The level line says
    /// nothing; the swing line has to show it.
    @Test func `a steady average with a widening swing shows up in the swing line`() throws {
        // Oscillates around 100 the whole time, but by ±1 early and ±12 late.
        let levels = (0..<20).map { index -> Double in
            let amplitude = index < 10 ? 1.0 : 12.0
            return 100 + (index.isMultiple(of: 2) ? amplitude : -amplitude)
        }
        let series = try points(levels)

        // The level line really is flat in the sense that matters: the two halves share a mean.
        let firstHalf = MetricStatsProvider.mean(Array(levels.prefix(10)))
        let secondHalf = MetricStatsProvider.mean(Array(levels.suffix(10)))
        #expect(abs(firstHalf - secondHalf) < 0.001, "the fixture's average moved — wrong test")

        let swing = MetricSparkline.swingSeries(series)
        #expect(swing.count == levels.count - 1)
        let earlySwing = MetricStatsProvider.mean(swing.prefix(8).map(\.value))
        let lateSwing = MetricStatsProvider.mean(swing.suffix(8).map(\.value))
        #expect(
            lateSwing > earlySwing * 3,
            "swing line did not show the widening: \(earlySwing) → \(lateSwing)"
        )
    }

    @Test func `the swing of a perfectly steady metric is zero`() throws {
        let swing = try MetricSparkline.swingSeries(points([70, 70, 70, 70]))
        #expect(!swing.isEmpty)
        #expect(swing.allSatisfy { $0.value == 0 })
    }

    /// Direction-free: a drop is as much a swing as a rise, or a metric that fell sharply would look
    /// calm on a card about how erratic it has become.
    @Test func `a fall counts as much as a rise`() throws {
        let swing = try MetricSparkline.swingSeries(points([100, 90, 100]))
        #expect(swing.map(\.value) == [10, 10])
    }
}
