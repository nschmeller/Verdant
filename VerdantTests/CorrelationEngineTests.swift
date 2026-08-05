import Foundation
import Testing
@testable import Verdant

/// Unit tests for the pure cross-source correlation statistics: Pearson, the Fisher-z p-value,
/// the Benjamini–Hochberg FDR guard, alignment/lag, redundancy flagging, and end-to-end discovery.
/// The scan's contract is "numbers inform, agents decide": every judged pair surfaces with its
/// evidence attached (significant-first ranking), and only computability guards drop anything.
struct CorrelationEngineTests {
    // MARK: Pearson

    @Test func `pearson is +1 for a perfect increasing line`() {
        let x = [1.0, 2, 3, 4, 5]
        let y = [2.0, 4, 6, 8, 10]
        #expect(abs((CorrelationEngine.pearson(x, y) ?? 0) - 1) < 1e-9)
    }

    @Test func `pearson is -1 for a perfect decreasing line`() {
        let x = [1.0, 2, 3, 4, 5]
        let y = [10.0, 8, 6, 4, 2]
        #expect(abs((CorrelationEngine.pearson(x, y) ?? 0) + 1) < 1e-9)
    }

    @Test func `pearson is nil when a series has no variance`() {
        #expect(CorrelationEngine.pearson([1, 1, 1, 1], [1, 2, 3, 4]) == nil)
    }

    @Test func `pearson is near zero for an orthogonal pattern`() {
        let x = [1.0, 2, 3, 4, 3, 2, 1, 2, 3, 4]
        let y = [1.0, -1, 1, -1, 1, -1, 1, -1, 1, -1]
        let r = CorrelationEngine.pearson(x, y) ?? 1
        #expect(abs(r) < 0.5)
    }

    // MARK: p-value

    @Test func `p-value shrinks as strength and sample size grow`() {
        let weakSmall = CorrelationEngine.pValue(r: 0.3, n: 10)
        let strongLarge = CorrelationEngine.pValue(r: 0.8, n: 60)
        #expect(strongLarge < weakSmall)
        #expect(strongLarge < 0.01)
        #expect(weakSmall > 0.05)
    }

    @Test func `normal CDF is calibrated at known points`() {
        #expect(abs(CorrelationEngine.normalCDF(0) - 0.5) < 1e-9)
        #expect(abs(CorrelationEngine.normalCDF(1.96) - 0.975) < 0.005)
    }

    // MARK: Benjamini–Hochberg

    @Test func `BH rejects only the strongest of a mixed family`() {
        // Two genuinely tiny p-values among mostly-null tests should survive; the nulls should not.
        let pValues = [0.001, 0.002, 0.2, 0.5, 0.7, 0.9]
        let flags = CorrelationEngine.benjaminiHochberg(pValues, alpha: 0.10)
        #expect(flags[0])
        #expect(flags[1])
        #expect(!flags[2])
        #expect(!flags[5])
    }

    @Test func `BH rejects nothing when all p-values are large`() {
        let flags = CorrelationEngine.benjaminiHochberg([0.4, 0.5, 0.6, 0.9], alpha: 0.10)
        #expect(flags.allSatisfy { !$0 })
    }

    @Test func `winsorize clamps the extreme tails so outliers can't dominate a correlation`() throws {
        // Every correlation (and the detail chart) is computed on winsorized first-differences. A lone
        // spike must be pulled into the 2.5/97.5 percentile band, not left to drag the coefficient — yet
        // the bulk of ordinary days must pass through untouched.
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var map: [Date: Double] = [:]
        // 41 days: one extreme low, one extreme high, 39 ordinary values in 51...89.
        let values = [-1000.0] + (1...39).map { 50.0 + Double($0) } + [1000.0]
        for (i, v) in values.enumerated() {
            try map[#require(calendar.date(byAdding: .day, value: -i, to: today))] = v
        }
        let out = CorrelationEngine.winsorize(map)
        #expect(out.count == map.count) // every day kept
        #expect(try #require(out.values.min()) >= 51) // the −1000 spike pulled up to the low percentile
        #expect(try #require(out.values.max()) <= 89) // the +1000 spike pulled down to the high percentile
        #expect(!out.values.contains(-1000) && !out.values.contains(1000)) // outliers gone
        // An ordinary mid value is untouched.
        let midDay = try #require(calendar.date(byAdding: .day, value: -20, to: today))
        #expect(out[midDay] == map[midDay])
    }

    @Test func `winsorize leaves a tiny sample untouched`() throws {
        // Below 8 points the tail percentiles are meaningless, so the series passes through unchanged
        // rather than clamping on noise.
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var map: [Date: Double] = [:]
        for (i, v) in [1.0, 2, 3, 999].enumerated() {
            try map[#require(calendar.date(byAdding: .day, value: -i, to: today))] = v
        }
        #expect(CorrelationEngine.winsorize(map) == map) // 4 < 8 → unchanged, the 999 not clamped
    }

    @Test func `residuals strip the part of a signal the covariate explains`() {
        // The activity-controlled partial correlation = Pearson of each metric's residuals after
        // regressing it on activity. If a metric is perfectly explained by activity (v = 2·z + 3), its
        // residuals MUST be ~0 — otherwise the "holds even after accounting for how active you were"
        // trust claim shown to the user wouldn't actually hold.
        let z = [1.0, 2, 3, 4, 5, 6, 7, 8]
        let v = z.map { 2 * $0 + 3 } // perfectly linear in z
        let r = CorrelationEngine.residuals(v, on: z)
        #expect(r.allSatisfy { abs($0) < 1e-9 }) // fully explained ⇒ ~zero residuals
    }

    @Test func `residuals are mean-zero and pass through a constant covariate`() {
        let z = [1.0, 3, 2, 5, 4, 6, 8, 7]
        let v = [2.0, 1, 5, 3, 9, 4, 7, 6]
        let r = CorrelationEngine.residuals(v, on: z)
        #expect(abs(r.reduce(0, +)) < 1e-9) // OLS residuals always sum to zero
        // A constant covariate has no variance to regress on, so v is returned unchanged (not all-zero).
        #expect(CorrelationEngine.residuals(v, on: Array(repeating: 5.0, count: v.count)) == v)
    }

    @Test func `first differences key each change by the later day and skip gaps`() throws {
        // Correlations (and the chart) run on day-to-day changes, not levels. Each change is keyed by
        // the LATER day and only emitted where both adjacent days exist — a logging gap must NOT produce
        // a spurious multi-day "change" that would distort the coefficient.
        let calendar = Calendar.civil
        let base = calendar.startOfDay(for: Date())
        func day(_ offset: Int) throws -> Date {
            try #require(calendar.date(
                byAdding: .day,
                value: offset,
                to: base
            ))
        }
        let values: [Date: Double] = try [day(0): 10, day(1): 12, day(3): 20, day(4): 25] // day(2) missing
        let diffs = CorrelationEngine.firstDifferences(values)
        #expect(diffs.count == 2) // only the two consecutive pairs
        #expect(try diffs[day(1)] == 2) // 12 − 10, keyed by the later day
        #expect(try diffs[day(4)] == 5) // 25 − 20
        #expect(try diffs[day(3)] == nil) // day(2) missing → no change across the gap
        #expect(try diffs[day(0)] == nil) // no prior day
    }

    @Test func `ranks are tie-averaged`() {
        // Spearman is Pearson of ranks; tied values must share the average of the ranks they'd occupy,
        // or the rank/linear agreement check (which flags flimsy nonlinear pairs) would be wrong.
        #expect(CorrelationEngine.ranks([10, 20, 20, 30]) == [1, 2.5, 2.5, 4])
        #expect(CorrelationEngine.ranks([5, 1, 3]) == [3, 1, 2])
    }

    // MARK: End-to-end

    /// Build two series: A noisy random-ish walk, B a lagged + noisy copy of A, and C independent.
    private func makeSeries(now: Date) -> [DailySeries] {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        var a: [Date: Double] = [:]
        var b: [Date: Double] = [:]
        var c: [Date: Double] = [:]
        // 50 days. A = deterministic oscillation; B tracks A same-day with small offset; C alternates
        // on a different period so it is uncorrelated with A.
        for k in 0..<50 {
            let day = calendar.date(byAdding: .day, value: -k, to: today)!
            let av = 100 + 30 * sin(Double(k) / 3.0)
            a[day] = av
            b[day] = av * 1.5 + 5 // perfectly affine → r ≈ 1 same-day
            c[day] = 50 + 40 * sin(Double(k) / 1.7 + 1.0)
        }
        return [
            DailySeries(metric: .appleExerciseTime, values: a),
            DailySeries(metric: .sleepDurationHours, values: b),
            DailySeries(metric: .restingHeartRate, values: c)
        ]
    }

    @Test func `engine surfaces a strong cross-domain correlation`() {
        let engine = CorrelationEngine()
        let scan = engine.scan(in: makeSeries(now: Date()))
        // Exercise↔sleep is affine → must surface as significant; and exactly once for that pair.
        let pair = scan.correlations.filter { $0.pairKey == [
            MetricKey.appleExerciseTime.rawValue, MetricKey.sleepDurationHours.rawValue
        ].sorted().joined(separator: "|") }
        #expect(pair.count == 1)
        #expect((pair.first?.strength ?? 0) > 0.9)
        #expect(pair.first?.significant == true)
        // Three metrics, no redundant pairs, all with ample data ⇒ all 3 pairs are tested (the breadth
        // number the Deep Analysis UI reports), even though only one is a significant finding.
        #expect(scan.pairsTested == 3)
    }

    @Test func `sub-threshold pairs surface flagged and rank below the significant ones`() {
        // Numbers inform, agents decide: the two weak pairs (exercise↔restingHR, sleep↔restingHR)
        // must NOT silently vanish — they surface carrying significant == false and their real
        // p-values, ranked below the proven exercise↔sleep link.
        let scan = CorrelationEngine().scan(in: makeSeries(now: Date()))
        #expect(scan.correlations.count == 3) // every judged pair is returned
        let first = scan.correlations.first
        #expect(first?.significant == true) // significant-first ranking
        #expect(first?.pairKey == [
            MetricKey.appleExerciseTime.rawValue, MetricKey.sleepDurationHours.rawValue
        ].sorted().joined(separator: "|"))
        let weak = scan.correlations.dropFirst()
        #expect(weak.allSatisfy { !$0.significant }) // flagged, not filtered
        #expect(weak.allSatisfy { $0.pValue > 0.1 }) // the evidence the agent judges by is real
    }

    @Test func `the size cap trims by ranking, not by worth`() {
        // `maxReturned` is a memory bound on the memoized scan, far above the tool ceiling. Shrunk
        // to 1 it must keep the head of the SAME ranking (the significant pair) — and the FDR
        // breadth count is unaffected by the cap.
        var config = CorrelationEngine.Config.default
        config.maxReturned = 1
        let scan = CorrelationEngine(config: config).scan(in: makeSeries(now: Date()))
        #expect(scan.correlations.count == 1)
        #expect(scan.correlations.first?.significant == true)
        #expect(scan.pairsTested == 3)
    }

    @Test func `engine detects a multi-day lead-lag relationship`() throws {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var lead: [Date: Double] = [:]
        var trail: [Date: Double] = [:]
        // `trail` today equals `lead` two days earlier → lead leads trail by 2 days.
        var byOffset: [Int: Double] = [:]
        for k in 0..<70 {
            byOffset[k] = 100 + 30 * sin(Double(k) / 3.0)
        }
        for k in 0..<70 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            lead[day] = try #require(byOffset[k])
            if let earlier = byOffset[k + 2] { trail[day] = earlier } // trail[d] = lead[d-2]
        }
        let series = [
            DailySeries(metric: .appleExerciseTime, values: lead),
            DailySeries(metric: .sleepDurationHours, values: trail)
        ]
        let found = CorrelationEngine().scan(in: series).correlations
        let pair = found.first { $0.pairKey == [
            MetricKey.appleExerciseTime.rawValue, MetricKey.sleepDurationHours.rawValue
        ].sorted().joined(separator: "|") }
        #expect(pair?.lag == 2)
        #expect(pair?.metricA == .appleExerciseTime) // the leading metric
    }

    @Test func `a mechanically redundant pair surfaces flagged, outside the FDR family`() throws {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var steps: [Date: Double] = [:]
        var distance: [Date: Double] = [:]
        for k in 0..<40 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            let v = 8000 + 2000 * sin(Double(k) / 4.0)
            steps[day] = v
            distance[day] = v * 0.7 // tautologically coupled
        }
        let series = [
            DailySeries(metric: .stepCount, values: steps),
            DailySeries(metric: .distanceWalkingRunning, values: distance)
        ]
        let scan = CorrelationEngine().scan(in: series)
        // The near-perfect correlation is physics, not discovery — but it must not silently vanish:
        // it surfaces FLAGGED (so the agent sees why the number is huge), is never marked
        // significant, and never counts in the FDR family ("relationships tested").
        #expect(scan.correlations.count == 1)
        let pair = try #require(scan.correlations.first)
        #expect(pair.mechanicallyRedundant)
        #expect(!pair.significant)
        #expect(pair.strength > 0.9)
        #expect(scan.pairsTested == 0)
    }

    @Test func `a one-stretch link surfaces with the thirds-consistency flag lowered`() throws {
        // B tracks A only in the OLDEST third of the record and is flat afterwards. The old engine
        // silently dropped such pairs; now the pair surfaces with consistentAcrossThirds == false —
        // the robustness evidence the judging agents (and the skeptic's basis) weigh.
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var a: [Date: Double] = [:]
        var b: [Date: Double] = [:]
        for k in 0..<45 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            let idx = Double(45 - k) // increases with calendar time
            let value = 100 + 25 * sin(idx / 2.0)
            a[day] = value
            b[day] = idx <= 15 ? value : 50 // tracks only the earliest stretch, then flat
        }
        let series = [
            DailySeries(metric: .appleExerciseTime, values: a),
            DailySeries(metric: .sleepDurationHours, values: b)
        ]
        let pair = try #require(CorrelationEngine().scan(in: series).correlations.first)
        #expect(!pair.consistentAcrossThirds)
        #expect(pair.lag == 0)
    }

    /// The minimum paired-day floor is a COMPUTABILITY guard (no trustworthy statistic exists below
    /// it), not a worth gate — it stays a hard drop even under the surface-everything contract.
    @Test func `engine respects the minimum paired-day floor`() throws {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var a: [Date: Double] = [:]
        var b: [Date: Double] = [:]
        for k in 0..<8 { // far below minPairs
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            a[day] = Double(k)
            b[day] = Double(k) * 2
        }
        let series = [
            DailySeries(metric: .appleExerciseTime, values: a),
            DailySeries(metric: .sleepDurationHours, values: b)
        ]
        #expect(CorrelationEngine().scan(in: series).correlations.isEmpty)
    }

    @Test func `redundancy catalog flags a known tautological pair and spares a cross-domain one`() {
        #expect(MetricCatalog.isMechanicallyRedundant(.stepCount, .distanceWalkingRunning))
        #expect(MetricCatalog.isMechanicallyRedundant(.bodyMass, .bodyMassIndex))
        #expect(!MetricCatalog.isMechanicallyRedundant(.sleepDurationHours, .restingHeartRate))
        #expect(!MetricCatalog.isMechanicallyRedundant(.appleExerciseTime, .heartRateVariabilitySDNN))
    }

    @Test func `daily heart rate vs activity is a physiological tautology and is excluded`() {
        // The exact triviality a user saw on-device ("active energy vs heart rate — obviously they
        // track"): daily-average HR is mechanically driven by that day's movement, and the engine
        // can't even partial activity out of a pair that CONTAINS activity. Excluded outright.
        #expect(MetricCatalog.isMechanicallyRedundant(.heartRate, .activeEnergyBurned))
        #expect(MetricCatalog.isMechanicallyRedundant(.heartRate, .stepCount))
        #expect(MetricCatalog.isMechanicallyRedundant(.heartRate, .appleExerciseTime))
        #expect(MetricCatalog.isMechanicallyRedundant(.walkingHeartRateAverage, .walkingSpeed))
        // Rest-measured recovery/fitness signals vs. activity remain ELIGIBLE — those are the genuine,
        // non-obvious links (e.g. training load ↔ next-day resting HR / HRV).
        #expect(!MetricCatalog.isMechanicallyRedundant(.restingHeartRate, .activeEnergyBurned))
        #expect(!MetricCatalog.isMechanicallyRedundant(.heartRateVariabilitySDNN, .stepCount))
        #expect(!MetricCatalog.isMechanicallyRedundant(.vo2Max, .appleExerciseTime))
    }

    private static let sleepHrPairKey = ["restingHeartRate", "sleepDurationHours"]
        .sorted().joined(separator: "|")

    /// Two metrics that share only a slow upward trend (different day-to-day oscillations) correlate
    /// near-perfectly on raw levels but must NOT read as a discovery — first-differencing removes the
    /// trend, so the pair surfaces only as a weak, non-significant candidate the agent can dismiss.
    @Test func `a shared trend alone surfaces only as a weak non-significant candidate`() throws {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var a: [Date: Double] = [:]
        var b: [Date: Double] = [:]
        for k in 0..<70 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            let idx = Double(70 - k) // increases with calendar time
            a[day] = 0.5 * idx + 12 * sin(idx / 2.5)
            b[day] = 0.5 * idx + 12 * sin(idx / 7.0 + 2.1) // same trend, unrelated wiggle
        }
        let series = [
            DailySeries(metric: .sleepDurationHours, values: a),
            DailySeries(metric: .restingHeartRate, values: b)
        ]
        let pair = try #require(CorrelationEngine().scan(in: series).correlations
            .first { $0.pairKey == Self.sleepHrPairKey })
        #expect(!pair.significant)
        #expect(pair.strength < 0.2) // the change-correlation itself is near zero
    }

    /// Two metrics that co-move only because both track activity: partialling out same-day active
    /// energy must collapse the controlled coefficient — the pair surfaces with a tiny `partialR`
    /// and no significance, so the agent sees the confound rather than a hidden hole in the list.
    @Test func `an activity-driven link collapses under partialling`() throws {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: Date())
        var z: [Date: Double] = [:]
        var a: [Date: Double] = [:]
        var b: [Date: Double] = [:]
        for k in 0..<70 {
            let day = try #require(calendar.date(byAdding: .day, value: -k, to: today))
            let idx = Double(70 - k)
            let activity = 100 + 40 * sin(idx / 3.0)
            z[day] = activity
            // Both track activity; their NON-activity residuals are orthogonal (sin vs cos, same
            // frequency, 90° apart), so nothing links them once activity is partialled out.
            a[day] = 2 * activity + 20 * sin(idx / 8.0)
            b[day] = 3 * activity + 20 * cos(idx / 8.0)
        }
        let series = [
            DailySeries(metric: .activeEnergyBurned, values: z),
            DailySeries(metric: .sleepDurationHours, values: a),
            DailySeries(metric: .restingHeartRate, values: b)
        ]
        // sleep↔restingHR co-move only through activity → the raw change-correlation is strong, but
        // the activity-controlled coefficient collapses and the pair is not significant.
        let pair = try #require(CorrelationEngine().scan(in: series).correlations
            .first { $0.pairKey == Self.sleepHrPairKey })
        #expect(pair.activityControlled)
        #expect(!pair.significant)
        #expect(abs(pair.r) > 0.9) // the raw co-movement is real…
        #expect(pair.strength < 0.1) // …but nothing survives the activity control
    }

    @Test func `effective sample size never exceeds n and corrects positive autocorrelation`() {
        // A smooth, highly autocorrelated series should yield far fewer effective than raw samples.
        let smooth = (0..<60).map { sin(Double($0) / 5.0) }
        let nEff = CorrelationEngine.effectiveSampleSize(smooth, smooth)
        #expect(nEff < 60)
        #expect(nEff >= 4)
    }

    @Test func `effective sample size is not deflated by anti-correlation`() {
        // Strongly anti-persistent (alternating) series: ρ ≈ −1, floored to 0 → no deflation.
        let alternating = (0..<60).map { $0 % 2 == 0 ? 1.0 : -1.0 }
        #expect(CorrelationEngine.effectiveSampleSize(alternating, alternating) >= 59)
    }

    @Test func `episode robustness rejects a link present in only one stretch`() {
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<30 {
            xs.append(Double(i))
            ys.append(i < 10 ? Double(i) : 0) // tracks only in the first third, flat thereafter
        }
        let overall = CorrelationEngine.pearson(xs, ys) ?? 0
        #expect(!CorrelationEngine.signHoldsAcrossThirds(xs, ys, overall: overall))
    }

    @Test func `episode robustness accepts a consistent link`() {
        let xs = (0..<30).map(Double.init)
        let ys = xs.map { $0 * 1.5 }
        #expect(CorrelationEngine.signHoldsAcrossThirds(xs, ys, overall: 1.0))
    }

    // MARK: Tool rows

    @Test func `tool rows expose the judgment fields and a readable lead direction`() {
        // The agent judges each row by its evidence: the p-value (rounded at the tool boundary),
        // the FDR verdict, thirds-consistency, and the redundancy flag — and for lagged pairs the
        // row states WHICH metric leads (the raw lag sign is unreadable in the transcript).
        let lagged = MetricCorrelation(
            metricA: .appleExerciseTime, metricB: .heartRateVariabilitySDNN, lag: 2,
            r: 0.5, partialR: 0.42, spearman: 0.4, n: 60, nEff: 38.6, pValue: 0.0123456,
            significant: true, activityControlled: true, consistentAcrossThirds: true
        )
        let row = DiscoveredCorrelation(lagged)
        #expect(row.leads == "appleExerciseTime leads by 2d")
        #expect(row.lagDays == 2)
        #expect(row.pValue == 0.01235) // toolRounded: 4 significant digits
        #expect(row.significant)
        #expect(row.consistentAcrossThirds)
        #expect(!row.redundant)
        #expect(row.effectiveDays == 39)
        #expect(row.activityControlled)

        let flagged = DiscoveredCorrelation(MetricCorrelation(
            metricA: .stepCount, metricB: .distanceWalkingRunning, lag: 0,
            r: 0.99, partialR: 0.99, spearman: 0.99, n: 40, nEff: 30, pValue: 0.001,
            significant: false, consistentAcrossThirds: false, mechanicallyRedundant: true
        ))
        #expect(flagged.leads == "same-day")
        #expect(!flagged.significant)
        #expect(!flagged.consistentAcrossThirds)
        #expect(flagged.redundant)
    }
}
