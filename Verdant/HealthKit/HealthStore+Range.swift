import Foundation
import HealthKit

// MARK: - Whole-range daily aggregation (one query per metric)

extension HealthStore {
    /// When this metric's HealthKit history BEGINS — the anchor for all-time backfill. One
    /// limit-1 ascending query; `nil` means the store has no samples for the type at all.
    func earliestSampleDate(for metric: MetricKey) async throws -> Date? {
        let type = HealthTypeMapping.sampleType(for: metric)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    if (error as? HKError)?.code == .errorNoData {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                cont.resume(returning: samples?.first?.startDate)
            }
            store.execute(query)
        }
    }

    /// Daily rollups for one metric across a whole date range in ONE HealthKit query — a statistics
    /// collection for quantity metrics, a chunked sample fetch grouped by civil day for interval
    /// metrics. This is what makes multi-year backfill affordable: one query per metric instead of
    /// one per metric-day (the old per-day loop cost `days × metrics` queries, which capped backfill
    /// at 730 of the 1,825 analyzable days). Days with no data simply produce no rollup.
    /// `end` is exclusive.
    ///
    /// INVARIANT: this API is **deletion-blind** — "empty day → no row" cannot remove a stale
    /// rollup the way the per-day path's `DayDeletion` does. It may only serve spans where no
    /// stale rollup can pre-exist: the first ingest (no rollups yet) and history deepening
    /// (strictly older than any rollup, or a metric with none). The `hadDeletions` window
    /// recompute must stay on the per-day path.
    func dailyValuesRange(for metric: MetricKey, from start: Date, to end: Date) async throws -> [DayRollup] {
        guard start < end else { return [] }
        switch metric.source {
        case .quantity:
            return try await quantityDailyRollups(metric: metric, from: start, to: end)
        case .sleepHours:
            // Hoisted: the include filter runs per SAMPLE, and a 5-year deepen can see 10⁵–10⁶
            // sleep-stage samples — rebuilding this Set inside the closure would allocate per call.
            let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
            let spec = IntervalSpec(
                metric: metric, identifier: .sleepAnalysis, divisor: 3600,
                include: { asleep.contains($0) }
            )
            return try await intervalDailyRollups(spec, from: start, to: end)
        case .mindfulMinutes:
            let spec = IntervalSpec(
                metric: metric, identifier: .mindfulSession, divisor: 60, include: { _ in true }
            )
            return try await intervalDailyRollups(spec, from: start, to: end)
        }
    }

    /// How one interval source (sleep, mindful) turns category samples into a daily value —
    /// mirrors the parameters of the per-day `categoryDurationValues`.
    /// Internal alongside `mergedDailyRollups`, which takes one — see that method's note.
    struct IntervalSpec {
        let metric: MetricKey
        let identifier: HKCategoryTypeIdentifier
        let divisor: Double
        let include: @Sendable (Int) -> Bool
    }

    private func quantityDailyRollups(
        metric: MetricKey,
        from start: Date,
        to end: Date
    ) async throws -> [DayRollup] {
        let (aligned, misalignedDays) = try await quantityCollection(
            metric: metric, from: start, to: end
        )
        guard !misalignedDays.isEmpty else { return aligned }
        // Belt-and-braces: any bucket that did NOT land exactly on the fixed-UTC civil-day grid is
        // recomputed through the proven per-day path (exact `dayStart ..< dayStart+86400` windows),
        // so a HealthKit calendar/DST surprise can degrade only performance, never the day grid —
        // a drifted key would double-count against the incremental path's correctly-keyed row.
        var rollups = aligned
        let calendar = Calendar.civil
        for day in Set(misalignedDays.map { calendar.startOfDay(for: $0) }).sorted() {
            try Task.checkCancellation()
            if let values = try await dailyValues(for: metric, dayStart: day) {
                rollups.append(DayRollup(metric: metric, dayStart: day, values: values))
            }
        }
        return rollups
    }

    /// One statistics-collection query; returns the civil-day-aligned rollups plus the start dates
    /// of any buckets that missed the grid (for per-day recompute by the caller).
    private func quantityCollection(
        metric: MetricKey,
        from start: Date,
        to end: Date
    ) async throws -> ([DayRollup], [Date]) {
        let type = HKQuantityType(HealthTypeMapping.quantityTypeIdentifier(for: metric)!)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let isSum = metric.aggregation.wantsCumulativeSum
        // `.separateBySource` populates each bucket's `sources` — see `quantityDailyValues`. The
        // backfill path needs it just as much as the incremental one: a device swap is most often
        // years back in the history this query is what loads.
        let aggregate: HKStatisticsOptions = isSum ? .cumulativeSum : .discreteAverage
        let options: HKStatisticsOptions = [aggregate, .separateBySource]
        // Fixed 24-HOUR intervals, deliberately not `day: 1`: `Calendar.civil` days are exactly
        // 86,400 s (fixed UTC), while day components make HealthKit slice at the device's LOCAL wall
        // clock — across a DST change that boundary drifts an hour off the rollup grid and a day's
        // samples split across two keys. Hour arithmetic is absolute-time arithmetic, so with a
        // civil-day anchor every returned `statistics.startDate` lands exactly on a civil day start
        // — and the caller verifies that, falling back to the per-day path for any bucket that
        // doesn't.
        let interval = DateComponents(hour: 24)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: start,
                intervalComponents: interval
            )
            // No `statisticsUpdateHandler`: the query completes after initial results. The whole
            // collection is reduced to Sendable values INSIDE the handler (HealthKit's background
            // queue), like every other wrapper in `HealthStore`.
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    // Same semantics as the per-day path: an empty span is a normal answer, not a
                    // failure (see `quantityDailyValues` — HealthKit reports "no data" as an error).
                    if (error as? HKError)?.code == .errorNoData {
                        cont.resume(returning: ([], []))
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let collection else { cont.resume(returning: ([], [])); return }
                let unit = HealthTypeMapping.unit(for: metric)
                var rollups: [DayRollup] = []
                var misaligned: [Date] = []
                collection.enumerateStatistics(from: start, to: end) { stats, _ in
                    guard stats.startDate < end else { return }
                    let value = isSum
                        ? stats.sumQuantity()?.doubleValue(for: unit)
                        : stats.averageQuantity()?.doubleValue(for: unit)
                    guard let value else { return }
                    let onGrid = stats.startDate.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: 86400) == 0
                    if onGrid {
                        rollups.append(DayRollup(
                            metric: metric,
                            dayStart: stats.startDate,
                            values: DayValues(
                                mean: value, sum: value, count: 1,
                                sources: SourceSignature.names(of: stats.sources)
                            )
                        ))
                    } else {
                        misaligned.append(stats.startDate)
                    }
                }
                cont.resume(returning: (rollups, misaligned))
            }
            store.execute(query)
        }
    }

    /// Interval sources (sleep, mindful): fetch samples in ~180-day chunks (Watch sleep-stage data
    /// runs 50–400 category samples a night, and deepening can run mid-deep-run with the 3B model
    /// resident — a single 5-year fetch could transiently materialize 10⁵–10⁶ `HKSample`s), bucket
    /// each sample onto the civil days it touches, and reuse the exact same merge as the per-day
    /// path (`SleepAggregation.mergedSeconds`). Only days inside `[start, end)` AND inside the
    /// current chunk are emitted, so a session crossing a chunk boundary — visible to both chunks'
    /// overlapping predicates — is still counted exactly once.
    private func intervalDailyRollups(
        _ spec: IntervalSpec,
        from start: Date,
        to end: Date
    ) async throws -> [DayRollup] {
        let calendar = Calendar.civil
        var out: [DayRollup] = []
        var cursor = start
        while cursor < end {
            // Cooperative per chunk: a Stop during a 5-year backfill shouldn't wait out ~11 more
            // fetches. Throwing is safe — a broken-off span replays idempotently.
            try Task.checkCancellation()
            let chunkEnd = min(calendar.date(byAdding: .day, value: 180, to: cursor) ?? end, end)
            let intervals = try await categoryIntervals(
                spec.identifier, from: cursor, to: chunkEnd, include: spec.include
            )
            out.append(contentsOf: Self.mergedDailyRollups(
                spec, intervals: intervals, from: cursor, to: chunkEnd, calendar: calendar
            ))
            cursor = chunkEnd
        }
        return out
    }

    /// One overlapping-predicate sample fetch, reduced to Sendable intervals inside the callback.
    private func categoryIntervals(
        _ identifier: HKCategoryTypeIdentifier,
        from start: Date,
        to end: Date,
        include: @escaping @Sendable (Int) -> Bool
    ) async throws -> [SleepAggregation.Interval] {
        let type = HKCategoryType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    if (error as? HKError)?.code == .errorNoData {
                        cont.resume(returning: [])
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                let intervals = (samples ?? [])
                    .compactMap { $0 as? HKCategorySample }
                    .filter { include($0.value) }
                    .map { SleepAggregation.Interval(
                        start: $0.startDate, end: $0.endDate,
                        source: $0.sourceRevision.source.name
                    ) }
                cont.resume(returning: intervals)
            }
            store.execute(query)
        }
    }

    /// Pure per-day merge over pre-fetched intervals — the same aggregation the per-day path runs,
    /// applied to every touched day in the window at once.
    ///
    /// Internal rather than private so it can be tested: it is where the interval path computes both
    /// a day's value and its provenance, and neither had any coverage — the wiring tests reach the
    /// store through `HealthReading`, which is upstream of this entirely.
    static func mergedDailyRollups(
        _ spec: IntervalSpec,
        intervals: [SleepAggregation.Interval],
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [DayRollup] {
        var byDay: [Date: [SleepAggregation.Interval]] = [:]
        for interval in intervals {
            for day in DayMath.daysTouched(start: interval.start, end: interval.end, calendar: calendar)
                where day >= start && day < end
            {
                byDay[day, default: []].append(interval)
            }
        }
        return byDay.sorted { $0.key < $1.key }.compactMap { dayStart, dayIntervals in
            guard let merged = SleepAggregation.mergedSeconds(
                intervals: dayIntervals, dayStart: dayStart, dayEnd: dayStart.addingTimeInterval(86400)
            ) else { return nil }
            let value = merged.seconds / spec.divisor
            return DayRollup(
                metric: spec.metric,
                dayStart: dayStart,
                values: DayValues(
                    mean: value, sum: value, count: merged.mergedCount,
                    // Every source that actually put TIME into this day. The merge collapses
                    // overlaps between sources, so two of them can produce one run — the day still
                    // had two, which is why membership is collected separately from the merge.
                    //
                    // "Touched" would be the wrong test and is what `daysTouched` gives: it is
                    // inclusive of the end day, so a session ending at exactly midnight is bucketed
                    // onto the following day while contributing nothing to it. That source would
                    // then join one day's signature and no other — a one-day flicker, manufactured
                    // by us at a midnight boundary, indistinguishable from a real brief change of
                    // device. Rare, but systematic, and precisely the noise provenance must not add.
                    sources: SourceSignature.canonical(
                        dayIntervals.filter { $0.seconds(within: dayStart) > 0 }.map(\.source)
                    )
                )
            )
        }
    }
}
