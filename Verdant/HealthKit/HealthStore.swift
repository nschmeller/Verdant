import Foundation
import HealthKit
import OSLog

/// One day's aggregated value for a metric. Sendable so it can cross from HealthKit's
/// background callback queues into the store actors without dragging non-Sendable `HKSample`s.
nonisolated struct DayValues: Equatable {
    var mean: Double
    var sum: Double
    var count: Int
    /// Which HealthKit sources contributed to this day — "Apple Watch", "iPhone", "Withings".
    ///
    /// Carried because a change in WHO recorded a metric looks exactly like a change in the metric.
    /// A new Apple Watch re-calibrates resting heart rate; a new scale reads two pounds heavy; a
    /// phone upgrade changes which device counts steps on a desk. Each produces a genuine, sustained
    /// level shift in the numbers, `RegimeShiftScan` fires on it correctly, and the investigating
    /// agent — with no evidence that anything but the body changed — writes a finding about the
    /// user's health. The data cannot distinguish the two cases. Provenance can.
    ///
    /// Empty means "not recorded" (an older rollup, or a query that returned no source list), which
    /// is why `ProvenanceScan` reports only transitions BETWEEN known signatures and never treats
    /// the absence of provenance as a change.
    var sources: [String] = []
}

/// A computed daily rollup ready to persist.
nonisolated struct DayRollup: Equatable {
    let metric: MetricKey
    let dayStart: Date
    let values: DayValues
}

/// Result of an incremental anchored scan. All fields Sendable; raw samples never escape the
/// HealthKit callback.
nonisolated struct AnchoredScan {
    var newAnchor: Data?
    var affectedDays: [Date]
    var hadDeletions: Bool
    var addedCount: Int
}

/// Actor-isolated wrapper around `HKHealthStore`. All HealthKit access funnels through here;
/// every query wrapper aggregates inside the callback and resumes with Sendable value types, so
/// non-Sendable `HKSample`/`HKDeletedObject` instances never cross an isolation boundary.
actor HealthStore {
    /// Internal (not private) so the range-query extension (`HealthStore+Range`) can execute
    /// queries; actor isolation still confines every access to this actor.
    let store = HKHealthStore()
    /// Long-lived observer queries, retained so background delivery keeps firing.
    private var observerQueries: [HKObserverQuery] = []
    private static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "HealthStore")

    nonisolated static var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Request read access to every tracked type. Note: HealthKit deliberately does not reveal
    /// whether *read* access was granted, so we never branch on the result — we just query and
    /// treat "no data" uniformly.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: HealthTypeMapping.allReadableTypes)
    }

    /// Whether the permission sheet still NEEDS to be shown for any tracked type. HealthKit hides
    /// per-type *read* grants, but it does reveal this: `.shouldRequest` means at least one type has
    /// never been through the sheet — every query on it throws "Authorization not determined" until
    /// it has. New registry rows land in exactly that state on an existing install, so callers
    /// re-request whenever this is true (each foregrounding), not just once at first launch.
    func needsAuthorizationRequest() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            store.getRequestStatusForAuthorization(
                toShare: [], read: HealthTypeMapping.allReadableTypes
            ) { status, error in
                if let error {
                    Self.log.error("""
                    Authorization status check failed: \(error.localizedDescription, privacy: .public)
                    """)
                }
                cont.resume(returning: status == .shouldRequest)
            }
        }
    }

    /// Register an `HKObserverQuery` + background delivery for every tracked type. `onUpdate` is
    /// invoked (off-actor, on HealthKit's queue) when new data lands; the caller does brief
    /// deterministic work and then the observer's completion handler is called to release the
    /// background assertion. Re-registering on each launch is safe — duplicate observers coalesce.
    func startBackgroundObservers(onUpdate: @escaping @Sendable (MetricKey) async -> Void) async {
        for metric in MetricKey.allCases {
            let type = HealthTypeMapping.sampleType(for: metric)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if let error {
                    Self.log.error("""
                    Observer error for \(metric.rawValue, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                    completion()
                    return
                }
                // The completion handler is called AFTER the ingest, and that ordering carries a risk
                // worth stating rather than discovering. Apple's contract: "Call this handler as soon
                // as you're done processing the incoming data. Failing to call the completion handler
                // in a timely manner may cause the system to stop delivering updates." An incremental
                // ingest is milliseconds, so the normal case is comfortably inside that — and
                // `bootstrap` registers observers only AFTER the catch-up has saved every anchor,
                // precisely so an observer fire can never take the multi-minute first-ingest path.
                //
                // What is NOT covered is a launch where that ordering does not hold. Calling
                // `completion()` first would be safe by this app's own design — the doc on
                // `ObserverManager.handleObservedChange` explains that an interrupted ingest loses
                // nothing, because the delta sits at the saved anchor and the next gated ingest or
                // launch catch-up picks it up — and it would trade "iOS may quietly stop delivering
                // updates", which is silent and lasting, for "the app may be suspended mid-ingest",
                // which the anchor discipline already tolerates.
                //
                // Left alone because the failure is unobservable here: whether iOS actually throttles
                // this app, and whether any real launch reaches an observer before the catch-up, both
                // need a device. The trade is written down so it can be made on evidence.
                //
                // HealthKit's completion handler predates Sendable; box it to carry across the Task.
                let completionBox = UncheckedSendableBox(completion)
                Task {
                    await onUpdate(metric)
                    completionBox.value()
                }
            }
            store.execute(query)
            observerQueries.append(query)
            do {
                try await enableBackgroundDelivery(type: type)
            } catch {
                Self.log.error("enableBackgroundDelivery failed for \(metric.rawValue, privacy: .public)")
            }
        }
    }

    private func enableBackgroundDelivery(type: HKSampleType) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Incremental scan from a saved anchor: returns the days touched by new samples, whether any
    /// deletions occurred (deletions carry no date, so callers recompute the whole window), and a
    /// freshly archived anchor to persist as the resumable cursor.
    func anchoredScan(for metric: MetricKey, anchor anchorData: Data?) async throws -> AnchoredScan {
        let type = HealthTypeMapping.sampleType(for: metric)
        let anchor: HKQueryAnchor? = anchorData.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AnchoredScan, Error>) in
            let query = HKAnchoredObjectQuery(
                type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error); return }
                let calendar = Calendar.civil
                let isInterval = if case .sleepHours = metric.source { true } else { false }
                var days = Set<Date>()
                for sample in samples ?? [] {
                    if isInterval {
                        // Interval samples (sleep) can cross midnight, changing more than the start day.
                        days.formUnion(DayMath.daysTouched(
                            start: sample.startDate,
                            end: sample.endDate,
                            calendar: calendar
                        ))
                    } else {
                        days.insert(calendar.startOfDay(for: sample.startDate))
                    }
                }
                let archived = newAnchor.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                cont.resume(returning: AnchoredScan(
                    newAnchor: archived,
                    affectedDays: Array(days),
                    hadDeletions: !(deleted ?? []).isEmpty,
                    addedCount: (samples ?? []).count
                ))
            }
            store.execute(query)
        }
    }

    /// Authoritative aggregate for one metric on one day. Returns `nil` when the day has no data,
    /// which callers treat as a deletion of any stale rollup for that day.
    func dailyValues(for metric: MetricKey, dayStart: Date) async throws -> DayValues? {
        let dayEnd = dayStart.addingTimeInterval(86400)
        switch metric.source {
        case .quantity:
            return try await quantityDailyValues(metric: metric, dayStart: dayStart, dayEnd: dayEnd)
        case .sleepHours:
            // NOTE: sleep uses the same fixed-UTC midnight-to-midnight window as every other metric
            // (see Calendar.civil). For a user away from UTC that boundary falls at some local hour, so
            // a given night is attributed largely to ONE civil day (offset from the local-calendar
            // date) rather than split at local midnight. It is a CONSISTENT proxy — which is what
            // trends/correlations need — but not a true "sleep day". A noon-to-noon window attributing a
            // whole session to its wake date would be more accurate — deferred because it can only be
            // validated against real on-device sleep data.
            return try await categoryDurationValues(
                .sleepAnalysis, dayStart: dayStart, dayEnd: dayEnd, divisor: 3600,
                include: { Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)).contains($0) }
            )
        case .mindfulMinutes:
            return try await categoryDurationValues(
                .mindfulSession, dayStart: dayStart, dayEnd: dayEnd, divisor: 60, include: { _ in true }
            )
        }
    }

    private func quantityDailyValues(
        metric: MetricKey,
        dayStart: Date,
        dayEnd: Date
    ) async throws -> DayValues? {
        let type = HKQuantityType(HealthTypeMapping.quantityTypeIdentifier(for: metric)!)
        let predicate = HKQuery.predicateForSamples(
            withStart: dayStart,
            end: dayEnd,
            options: .strictStartDate
        )
        let isSum = metric.aggregation.wantsCumulativeSum
        // Only the per-day mean/sum is ever read downstream (MetricRollup.dayValue), so request just
        // that — no per-day min/max, which nothing consumes.
        //
        // `.separateBySource` is what populates `stats.sources`; without it that property is nil.
        // It does NOT change `sumQuantity()`/`averageQuantity()`, which stay the combined figure
        // across sources — it only makes the per-source breakdown additionally available. So the
        // stored numbers are untouched by asking, and we learn who recorded the day for free, inside
        // a query that was already running.
        let aggregate: HKStatisticsOptions = isSum ? .cumulativeSum : .discreteAverage
        let options: HKStatisticsOptions = [aggregate, .separateBySource]
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DayValues?, Error>) in
            let query = HKStatisticsQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: options
            ) { _, stats, error in
                if let error {
                    // HKStatisticsQuery reports an EMPTY day as an error ("No data available for
                    // the specified predicate", .errorNoData) — but an empty day is a normal
                    // answer here (callers treat nil as "remove any stale rollup"), not a failure.
                    // Throwing it aborted the metric's whole ingest pass, which also left the
                    // anchor unadvanced — so a deletion-triggered window recompute (deletions are
                    // routine for Watch metrics: Health merges/dedups heart-rate and energy
                    // samples constantly) re-failed on every pass, forever, in the field.
                    if (error as? HKError)?.code == .errorNoData {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let stats else { cont.resume(returning: nil); return }
                let unit = HealthTypeMapping.unit(for: metric)
                let sources = SourceSignature.names(of: stats.sources)
                if isSum {
                    guard let total = stats.sumQuantity()?.doubleValue(for: unit) else {
                        cont.resume(returning: nil); return
                    }
                    Self.noteMultiSourceSum(stats, total: total, unit: unit, metric: metric)
                    cont.resume(returning: DayValues(mean: total, sum: total, count: 1, sources: sources))
                } else {
                    guard let avg = stats.averageQuantity()?.doubleValue(for: unit) else {
                        cont.resume(returning: nil); return
                    }
                    cont.resume(returning: DayValues(mean: avg, sum: avg, count: 1, sources: sources))
                }
            }
            store.execute(query)
        }
    }

    /// Daily duration for a category type, summing non-overlapping sample durations (sleep, mindful).
    /// `include` filters category values (e.g. only "asleep" stages); `divisor` converts seconds to
    /// the stored unit (3600 → hours, 60 → minutes).
    private func categoryDurationValues(
        _ identifier: HKCategoryTypeIdentifier,
        dayStart: Date,
        dayEnd: Date,
        divisor: Double,
        include: @escaping @Sendable (Int) -> Bool
    ) async throws -> DayValues? {
        let type = HKCategoryType(identifier)
        // Overlapping predicate: intervals can cross midnight, so we clamp each to the day.
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: [])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DayValues?, Error>) in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                let contributing = (samples ?? [])
                    .compactMap { $0 as? HKCategorySample }
                    .filter { include($0.value) }
                let intervals = contributing
                    .map { SleepAggregation.Interval(start: $0.startDate, end: $0.endDate) }
                guard let result = SleepAggregation.mergedSeconds(
                    intervals: intervals, dayStart: dayStart, dayEnd: dayEnd
                ) else { cont.resume(returning: nil); return }
                let value = result.seconds / divisor
                // Only the samples that survived `include` — the ones whose durations were actually
                // summed. A sleep source whose every stage was filtered out did not contribute to
                // this number and must not appear as though it did.
                let sources = SourceSignature.canonical(
                    contributing.map(\.sourceRevision.source.name)
                )
                cont.resume(returning: DayValues(
                    mean: value, sum: value, count: result.mergedCount, sources: sources
                ))
            }
            store.execute(query)
        }
    }

    /// Settles, on the owner's own paired device, whether `cumulativeSum` double-counts a metric
    /// two devices both write.
    ///
    /// The open question (`docs/ARCHITECTURE.md`, and the roadmap note): iPhone and Watch both write
    /// `stepCount`; the Health app source-merges them and a raw sum does not. If this query is a raw
    /// sum, the headline metric is inflated for every Watch user and every finding built on it is
    /// wrong by that factor. It could not be settled here — a simulator fixture has one source per
    /// metric — and the fix depends on the answer, so nothing was changed.
    ///
    /// It no longer needs a special build to answer. `.separateBySource` is already requested (for
    /// provenance), so `sumQuantity(for:)` per source is in hand beside the combined figure. Their
    /// RATIO says which behaviour this is: 1.0 means the combined figure is the plain sum of the
    /// sources, so nothing is being merged; below 1.0 means HealthKit dropped overlap.
    ///
    /// Logs the ratio and never the values. A step total is health data; a dimensionless ratio is
    /// not, so this stays readable in Console without a logging profile and without putting a
    /// person's day on a log line. Fires only on days with two or more contributing sources, which
    /// is rare and is exactly the case in question.
    private static func noteMultiSourceSum(
        _ stats: HKStatistics,
        total: Double,
        unit: HKUnit,
        metric: MetricKey
    ) {
        guard let sources = stats.sources, sources.count > 1, total > 0 else { return }
        let perSource = sources.reduce(0.0) { running, source in
            running + (stats.sumQuantity(for: source)?.doubleValue(for: unit) ?? 0)
        }
        guard perSource > 0 else { return }
        let ratio = String(format: "%.4f", total / perSource)
        log.notice("""
        multi-source sum: \(metric.rawValue, privacy: .public) across \
        \(sources.count, privacy: .public) sources — combined/per-source ratio \
        \(ratio, privacy: .public) (1.0 = no merging, so the combined figure double-counts overlap)
        """)
    }
}
