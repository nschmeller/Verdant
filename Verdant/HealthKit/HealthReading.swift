import Foundation

/// The four HealthKit reads `Ingestor` performs, behind a protocol.
///
/// Extracted so the ingest path can be tested at all. It is where wrong data ENTERS — a stale
/// rollup, a mis-advanced anchor or a missed deletion is upstream of every statistic, every finding
/// and every card, and no downstream safeguard can detect it. Yet it was the least testable code in
/// the app, because `Ingestor` held a concrete `HealthStore` and HealthKit cannot be faked.
///
/// In particular, `dailyValuesRange` is DELETION-BLIND (see its own doc): "empty day → no row"
/// cannot remove a stale rollup the way the per-day path does, so it may only serve spans where no
/// stale rollup can pre-exist. That invariant was enforceable only as a tripwire on its call sites
/// until this seam existed; now the consequence itself can be tested.
nonisolated protocol HealthReading: Sendable {
    /// New and deleted samples since `anchorData`, with the advanced anchor.
    func anchoredScan(for metric: MetricKey, anchor anchorData: Data?) async throws -> AnchoredScan
    /// The authoritative aggregate for one metric on one day — `nil` when the day has no data,
    /// which callers treat as a deletion of any stale rollup for that day.
    func dailyValues(for metric: MetricKey, dayStart: Date) async throws -> DayValues?
    /// A whole range in one query. Deletion-blind: see the type doc.
    func dailyValuesRange(for metric: MetricKey, from start: Date, to end: Date) async throws -> [DayRollup]
    /// The earliest sample the store holds for this metric, or `nil` if it holds none.
    func earliestSampleDate(for metric: MetricKey) async throws -> Date?
}

extension HealthStore: HealthReading {}
