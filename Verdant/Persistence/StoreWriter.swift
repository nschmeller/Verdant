import Foundation
import SwiftData

/// The single writer for the entire store. Concentrating every mutation behind one
/// `@ModelActor` means writes never race, and the UI's main-context `@Query` and the
/// `MetricStatsProvider`'s read context only ever see committed data.
///
/// Ingest writes (anchors, rollups) live here; insight writes are added in the Memory module.
@ModelActor
actor StoreWriter {
    // MARK: HealthKit anchors

    func loadAnchor(for metric: MetricKey) throws -> Data? {
        let key = metric.rawValue
        let descriptor = FetchDescriptor<SyncAnchor>(predicate: #Predicate { $0.sampleType == key })
        return try modelContext.fetch(descriptor).first?.anchorData
    }

    func saveAnchor(for metric: MetricKey, data: Data, now: Date = .now) throws {
        let key = metric.rawValue
        let descriptor = FetchDescriptor<SyncAnchor>(predicate: #Predicate { $0.sampleType == key })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.anchorData = data
            existing.updatedAt = now
        } else {
            modelContext.insert(SyncAnchor(sampleType: key, anchorData: data, updatedAt: now))
        }
        try modelContext.save()
    }

    // MARK: Daily rollups

    /// Upsert recomputed days and delete days that no longer have data. Idempotent: re-ingesting
    /// the same day overwrites rather than duplicates (unique `key`).
    func applyRollups(upserts: [DayRollup], deletions: [DayDeletion]) throws {
        for rollup in upserts {
            let key = MetricRollup.makeKey(metric: rollup.metric, dayStart: rollup.dayStart)
            let descriptor = FetchDescriptor<MetricRollup>(predicate: #Predicate { $0.key == key })
            let values = rollup.values
            if let existing = try modelContext.fetch(descriptor).first {
                existing.mean = values.mean
                existing.sum = values.sum
                existing.count = values.count
                existing.sourceSignature = SourceSignature.joined(values.sources)
            } else {
                modelContext.insert(MetricRollup(
                    key: key,
                    metric: rollup.metric.rawValue,
                    dayStart: rollup.dayStart,
                    mean: values.mean,
                    count: values.count,
                    sum: values.sum,
                    sourceSignature: SourceSignature.joined(values.sources)
                ))
            }
        }
        for deletion in deletions {
            let key = MetricRollup.makeKey(metric: deletion.metric, dayStart: deletion.dayStart)
            let descriptor = FetchDescriptor<MetricRollup>(predicate: #Predicate { $0.key == key })
            for stale in try modelContext.fetch(descriptor) {
                modelContext.delete(stale)
            }
        }
        if !upserts.isEmpty || !deletions.isEmpty { try modelContext.save() }
    }

    /// Drop the entire derived ingest cache — every daily rollup and every HealthKit sync anchor — so
    /// the next ingest re-backfills the whole window from HealthKit. Used by the one-time civil-day
    /// migration: rollups written before the day boundary moved to UTC carry stale local-midnight keys
    /// that would otherwise coexist with the new UTC-keyed rows and double-count. Safe because rollups
    /// and anchors are a pure cache of HealthKit (the source of truth), rebuilt on the next pass.
    /// (History-deepening markers ride in `SyncAnchor` under sentinel keys, so they clear here too —
    /// a reset re-deepens automatically.)
    func resetIngestCache() throws {
        try modelContext.delete(model: MetricRollup.self)
        try modelContext.delete(model: SyncAnchor.self)
        try modelContext.save()
    }

    // MARK: History deepening

    /// Earliest day with a rollup for this metric — the deepening pass's cursor.
    func earliestRollupDay(for metric: MetricKey) throws -> Date? {
        let raw = metric.rawValue
        var descriptor = FetchDescriptor<MetricRollup>(
            predicate: #Predicate { $0.metric == raw },
            sortBy: [SortDescriptor(\.dayStart, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.dayStart
    }

    /// Deepening markers ride in `SyncAnchor` under a sentinel key (never a valid metric raw value)
    /// so they share the ingest cache's lifecycle EXACTLY: `resetIngestCache` clears them with the
    /// rollups they describe, and a post-reset re-deepen happens automatically. The key is
    /// VERSIONED by what "deepened" meant: `deepened#` marked the 1,825-day horizon; `deepenedAll#`
    /// marks all-time (back to the metric's earliest sample) — so installs marked under the old
    /// meaning re-deepen once to their true beginning, and the orphaned old rows are inert.
    private static func deepenMarkerKey(for metric: MetricKey) -> String {
        "deepenedAll#\(metric.rawValue)"
    }

    /// Whether this metric's history has already been deepened to the full analysis horizon.
    func hasDeepenedHistory(for metric: MetricKey) throws -> Bool {
        let key = Self.deepenMarkerKey(for: metric)
        let descriptor = FetchDescriptor<SyncAnchor>(predicate: #Predicate { $0.sampleType == key })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    func markHistoryDeepened(for metric: MetricKey, now: Date = .now) throws {
        guard try !hasDeepenedHistory(for: metric) else { return }
        modelContext.insert(SyncAnchor(
            sampleType: Self.deepenMarkerKey(for: metric), anchorData: Data(), updatedAt: now
        ))
        try modelContext.save()
    }
}

/// A day whose rollup should be removed (the day no longer has any samples).
nonisolated struct DayDeletion: Equatable {
    let metric: MetricKey
    let dayStart: Date
}
