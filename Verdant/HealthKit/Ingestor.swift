import Foundation
import HealthKit
import OSLog

/// Coordinates one ingest pass: pull the saved anchor, scan HealthKit for new/deleted samples,
/// recompute the affected daily rollups authoritatively, and persist both rollups and the
/// advanced anchor. Deterministic and LLM-free, so it is safe to run in a brief observer wake.
nonisolated struct Ingestor {
    let healthStore: any HealthReading
    let writer: StoreWriter

    /// The trailing window we recompute rollups for on an INCREMENTAL pass (anchor already saved).
    static let activeWindowDays = 40

    private static let log = Logger(subsystem: Identifiers.loggerSubsystem, category: "Ingestor")

    // There is NO first-ingest backfill cap: a first ingest reaches back to the metric's EARLIEST
    // HealthKit sample (`earliestSampleDate`), so the analysis sees the user's entire recorded
    // history — HealthKit began in 2014, so "all of it" is bounded by reality, and the range API
    // makes it one query per metric. The old 730/1825-day constants are gone with the caps.

    /// Start of the trailing window an INCREMENTAL pass recomputes. Pure, so the windowing is
    /// unit-tested without HealthKit.
    static func recomputeWindowStart(today: Date, calendar: Calendar = .civil) -> Date {
        calendar.date(byAdding: .day, value: -(activeWindowDays - 1), to: today)!
    }

    /// The span a deepening pass must fetch for one metric: from its earliest HealthKit sample up
    /// to (exclusive) its earliest existing rollup — or the whole history when no rollup exists.
    /// `nil` means nothing to do (no samples at all, or the rollups already reach the beginning).
    /// Pure, so the branch logic is unit-tested without HealthKit.
    static func deepenSpan(
        earliestSample: Date?,
        earliestRollup: Date?,
        dayAfterToday: Date,
        calendar: Calendar = .civil
    ) -> (from: Date, to: Date)? {
        guard let earliestSample else { return nil }
        let from = calendar.startOfDay(for: earliestSample)
        let to = earliestRollup ?? dayAfterToday
        return from < to ? (from, to) : nil
    }

    /// Ingest one metric. Returns the number of newly added samples observed. `progress`, when
    /// attached (foreground catch-up), narrates the slow first-launch backfill so the user sees it.
    @discardableResult
    func ingest(metric: MetricKey, now: Date = .now, progress: ProgressReporter? = nil) async throws -> Int {
        let anchorData = try await writer.loadAnchor(for: metric)
        let scan = try await healthStore.anchoredScan(for: metric, anchor: anchorData)

        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        // First ingest (no anchor yet) backfills the user's ENTIRE recorded history so the analysis
        // is never recency-biased; later passes only recompute the recent window.
        let firstIngest = anchorData == nil

        if firstIngest {
            await progress?.log("Reading your \(metric.displayName) history…")
            // ONE range query from the metric's earliest sample (there are no stale rollups to
            // delete on a first ingest — days with no data simply produce no row). No samples at
            // all → nothing to backfill; the anchor still saves below so later passes take the
            // cheap incremental path.
            if let earliest = try await healthStore.earliestSampleDate(for: metric) {
                let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: today)!
                let upserts = try await healthStore.dailyValuesRange(
                    for: metric, from: calendar.startOfDay(for: earliest), to: dayAfterToday
                )
                try await writer.applyRollups(upserts: upserts, deletions: [])
            }
        } else {
            let windowStart = Self.recomputeWindowStart(today: today, calendar: calendar)
            // Deletions carry no date, so on any deletion we recompute the whole active window;
            // otherwise just the days new samples touched.
            let daysToRecompute: Set<Date> = if scan.hadDeletions {
                Set(Self.windowDays(from: windowStart, to: today, calendar: calendar))
            } else {
                Set(scan.affectedDays
                    .map { calendar.startOfDay(for: $0) }
                    .filter { $0 >= windowStart })
            }

            var upserts: [DayRollup] = []
            var deletions: [DayDeletion] = []
            for day in daysToRecompute {
                if let values = try await healthStore.dailyValues(for: metric, dayStart: day) {
                    upserts.append(DayRollup(metric: metric, dayStart: day, values: values))
                } else {
                    deletions.append(DayDeletion(metric: metric, dayStart: day))
                }
            }

            try await writer.applyRollups(upserts: upserts, deletions: deletions)
        }

        // Honor HealthKit deletions: if the user removed samples for this metric, findings derived from
        // it no longer hold, so tombstone them (recompute already happened above). Both single-metric
        // insights AND correlations involving the metric rest on the deleted data.
        //
        // NOT `try?`: the anchor below is the ONLY carrier of the deletion signal (the next scan won't
        // re-report an already-consumed deletion). If invalidation fails we must let the pass throw so
        // the anchor is NOT advanced and the deletion replays next time — otherwise a transient save
        // error would strand stale findings on deleted data forever. Rollups were recomputed
        // idempotently above, so replaying the pass is safe.
        //
        // KNOWN GAP, and larger than "the cached rollup row lags" (the phrasing on `deepenHistory`).
        // A deletion carries no date, so the recompute above covers only the trailing
        // `activeWindowDays`. Delete a sample OLDER than that — a mistyped weight, a phantom workout,
        // the ordinary reasons someone edits Health — and its rollup keeps the pre-deletion value
        // forever. Tombstoning clears the findings that rested on it, which is what this block is
        // for, but the ROW is what `UnusualDaysScan` reads: every data point is tested against its
        // metric's own baseline, so the day the user deleted goes on being reported as one of their
        // strangest, and future findings are still built on it.
        //
        // Not fixed here because it is not a one-liner. A full-range recompute is the right shape
        // (`dailyValuesRange` already does it for `deepenHistory`), but it returns rollups only for
        // days that still HAVE samples — so the days that lost their last sample, which are exactly
        // the ones at issue, need deleting explicitly by diffing the stored days in range against the
        // days the query returned. That is surgery on the one path where a mistake corrupts the day
        // grid, and it wants testing against a real store with real deletions.
        if scan.hadDeletions {
            try await writer.tombstoneInsights(for: metric)
            try await writer.tombstoneCorrelations(for: metric)
        }

        if let anchor = scan.newAnchor {
            try await writer.saveAnchor(for: metric, data: anchor)
        }
        return scan.addedCount
    }

    /// Ingest every tracked metric. Per-metric failures are logged (WITH the reason — "Authorization
    /// not determined" and a HealthKit hiccup need opposite responses) and skipped so one bad type
    /// never blocks the rest; the feed gets one aggregate line per failure KIND, because the two
    /// need opposite user responses: "awaiting permission" means finish the Health sheet (the app
    /// re-presents it on every foregrounding until it's been through), while a read failure means
    /// something actually broke.
    func ingestAll(now: Date = .now, progress: ProgressReporter? = nil) async -> Int {
        await progress?.log("Scanning \(MetricKey.allCases.count) health sources for new data…")
        var added = 0
        var sourcesWithNews = 0
        var failed: [String] = []
        var awaitingPermission: [String] = []
        for metric in MetricKey.allCases {
            // Cooperative: a deep run's Stop (or a BGTask expiration) must not wait out a
            // 72-metric scan — the anchor discipline makes a broken-off pass safely resumable.
            if Task.isCancelled { break }
            do {
                let newSamples = try await ingest(metric: metric, now: now, progress: progress)
                added += newSamples
                if newSamples > 0 {
                    sourcesWithNews += 1
                    await progress?.log("· \(newSamples) new \(metric.displayName) readings")
                }
            } catch {
                // "Not determined" = the type has never been through the permission sheet — every
                // query throws until it has. Routine for types the user hasn't answered yet (blood
                // pressure, on devices that never logged any), so it gets its own calm bucket; the
                // anchor didn't advance, so the history backfills in full the moment access lands.
                if (error as? HKError)?.code == .errorAuthorizationNotDetermined {
                    awaitingPermission.append(metric.displayName)
                } else {
                    failed.append(metric.displayName)
                }
                Self.log.error("""
                Ingest failed for \(metric.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
        if !awaitingPermission.isEmpty {
            let shown = awaitingPermission.prefix(3).joined(separator: ", ")
            let suffix = awaitingPermission.count > 3 ? " and \(awaitingPermission.count - 3) more" : ""
            await progress?.log(
                "· \(shown)\(suffix) still awaiting Health permission — approve them on the "
                    + "permission sheet, or in Settings → Privacy & Security → Health"
            )
        }
        if !failed.isEmpty {
            let shown = failed.prefix(3).joined(separator: ", ")
            let suffix = failed.count > 3 ? " and \(failed.count - 3) more" : ""
            await progress?.log("⚠︎ Couldn't read \(shown)\(suffix) — check Health access in Settings")
        }
        await progress?.log(Self.closingNote(
            added: added, sourcesWithNews: sourcesWithNews,
            unread: failed.count + awaitingPermission.count, stoppedEarly: Task.isCancelled
        ))
        return added
    }

    /// The one line a person reads when the scan finishes, and the three things that are NOT the
    /// same as "nothing new".
    ///
    /// It used to be one ternary on `added`: anything other than a positive count printed "everything
    /// already up to date". Zero new readings is what a wholesale permission failure looks like, what
    /// a HealthKit error on all 72 types looks like, and what pressing Stop three metrics in looks
    /// like — and each of those was reported to the user as a clean, complete, current library.
    ///
    /// The warning lines above do fire, so the feed read "⚠︎ Couldn't read Steps, Weight, Sleep and
    /// 40 more" and then, immediately below, "everything already up to date". Contradicting itself
    /// one line later is not better than saying nothing; the closing note is the line that stays on
    /// screen and the one a person takes away.
    ///
    /// This is the rule the run loop already holds one layer up — `llm` records each outcome so a
    /// pass that genuinely found nothing "must not share a closing note" with one where every call
    /// failed. Ingest is the same claim about a different resource.
    ///
    /// Pure, so all four branches are pinned by `IngestClosingNoteTests` rather than reachable only
    /// by revoking Health permissions on a device.
    @discardableResult
    static func closingNote(added: Int, sourcesWithNews: Int, unread: Int, stoppedEarly: Bool) -> String {
        let total = MetricKey.allCases.count
        if stoppedEarly {
            return added > 0
                ? "Ingest stopped early — \(added) new readings banked before it was interrupted"
                : "Ingest stopped early — no new readings were banked"
        }
        if added > 0 {
            let core = "Ingest done — \(added) new readings across \(sourcesWithNews) sources"
            return unread > 0 ? "\(core); \(unread) sources couldn't be read" : core
        }
        if unread >= total { return "Ingest done — but not one of the \(total) sources could be read" }
        if unread > 0 {
            return "Ingest done — nothing new in the \(total - unread) sources that could be read, "
                + "\(unread) unread"
        }
        return "Ingest done — everything already up to date"
    }

    /// Extend rollup history back to each metric's EARLIEST HealthKit sample — the data-collection
    /// arm of a deep run, and how installs that first-ingested under the old capped backfills (730,
    /// then 1,825 days) reach their true beginning. One earliest-sample probe + at most one range
    /// query per metric; each runs ONCE (a marker rides in the ingest cache and clears with it, so
    /// a cache reset re-deepens automatically). Anchors are untouched: this is pure backfill of
    /// days OLDER than any existing rollup, so the deletion signal and the incremental window are
    /// unaffected. Known trade-off (pre-existing): sample deletions land only as a recompute of the
    /// trailing `activeWindowDays`, so an old rollup can go stale after old samples are deleted —
    /// findings on the metric are still tombstoned (`ingest` handles that), so no wrong finding
    /// survives — but the stale ROW outlives them and `UnusualDaysScan` reads rows, so the deleted
    /// day keeps being reported as unusual and future findings are still built on it. See the fuller
    /// note beside the tombstone call in `ingest`. Returns the number of recovered days.
    @discardableResult
    func deepenHistory(now: Date = .now, progress: ProgressReporter? = nil) async -> Int {
        let calendar = Calendar.civil
        let today = calendar.startOfDay(for: now)
        let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: today)!
        var recovered = 0
        var sources = 0
        for metric in MetricKey.allCases {
            if Task.isCancelled { break }
            do {
                // First ingest owns fresh installs (no anchor yet); a marked metric is already done.
                guard try await writer.loadAnchor(for: metric) != nil,
                      try await !writer.hasDeepenedHistory(for: metric)
                else { continue }
                // Span: earliest HealthKit sample up to the earliest existing rollup (or the whole
                // history when a capped-era backfill found nothing). Safe for the deletion-blind
                // range API either way: the span is strictly older than any rollup, or the metric
                // has none, so no stale row can pre-exist.
                guard let span = try await Self.deepenSpan(
                    earliestSample: healthStore.earliestSampleDate(for: metric),
                    earliestRollup: writer.earliestRollupDay(for: metric),
                    dayAfterToday: dayAfterToday,
                    calendar: calendar
                ) else {
                    // Nothing older exists → mark it so steady-state runs skip the probe entirely.
                    try await writer.markHistoryDeepened(for: metric)
                    continue
                }
                let older = try await healthStore.dailyValuesRange(
                    for: metric, from: span.from, to: span.to
                )
                try await writer.applyRollups(upserts: older, deletions: [])
                try await writer.markHistoryDeepened(for: metric)
                if !older.isEmpty {
                    recovered += older.count
                    sources += 1
                    await progress?.log("· Recovered \(older.count) older \(metric.displayName) days")
                }
            } catch {
                Self.log.error("""
                History deepening failed for \(metric.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
        if recovered > 0 {
            await progress?.log(
                "History deepened — \(recovered) older days recovered across \(sources) sources"
            )
        }
        return recovered
    }

    private static func windowDays(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var cursor = start
        while cursor <= end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}
