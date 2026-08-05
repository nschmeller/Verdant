import Foundation
import SwiftData

// SwiftData entities. Stored on a local-only, encrypted store (see `AppContainer`).
//
// Enum-typed domain concepts (metric, comparison, kind) are persisted as their stable raw
// `String` values so the schema never churns when display logic changes; typed accessors are
// provided as non-persisted computed properties.
//
// `@Model` classes are reference types and are NOT `Sendable`: only `PersistentIdentifier`
// crosses actor boundaries. Writes happen on the `@ModelActor` `StoreWriter`; the UI reads
// via `@Query` on the main context.
//
// `StoreWriter` is the ONLY writer, and the files named for what they write — `InsightWriter.swift`,
// `CorrelationWriter.swift`, `JournalWriter.swift`, `AuditWriter.swift` — are all extensions on it,
// not types. These two comments said `InsightWriter` for long enough to outlive the rename, which
// matters here more than in most stale prose: they are the two places that explain the concurrency
// model, so anyone checking the single-writer guarantee went looking for a type that does not exist.

/// Warm memory: one row per surfaced insight. Append-mostly — past insights are immutable
/// except for an LLM prose upgrade (`summary`), tombstoning, or explicit user deletion.
/// A finding that can be retired rather than deleted — the shared shape `pruneRetiredFindings`
/// needs, so both tables are pruned by one expression instead of two that drift apart.
nonisolated protocol RetirableFinding: PersistentModel {
    var tombstoned: Bool { get }
    var createdAt: Date { get }
}

@Model
final class InsightLog {
    @Attribute(.unique) var id: UUID
    var createdAt: Date

    // Identity of the finding.
    var kind: String
    var metric: String
    var comparison: String

    // The finding's shown prose — the final, safety-vetted LLM output (there is no template fallback).
    var summary: String
    var oneTapTitle: String
    var salience: Int

    // Verified numbers (the deterministic truth, never the model's claims) — kept as an audit trail.
    var verifiedRecent: Double
    var verifiedBaseline: Double
    var verifiedPctChange: Double
    var zScore: Double
    var sampleCount: Int
    var verificationPassed: Bool

    // Retrieval + lifecycle.
    @Attribute(.externalStorage) var embedding: Data?
    var embeddingModelID: String
    var tombstoned: Bool
    /// Promoted to the feed's "Worth your attention" section by the CURATOR agent — never by a
    /// score threshold. Defaults false, so a feed no agent has curated yet simply has no highlights
    /// rather than a rule inventing some.
    var highlighted = false
    /// How this finding came to be shown: which investigator lens proposed it, what the skeptic and
    /// replication panels tallied, and the most useful thing a panelist said. Empty until the
    /// panels have ruled. See `Orchestrator.provenanceLine`.
    var provenance = ""
    var jobRunID: UUID

    init(
        id: UUID = UUID(),
        createdAt: Date,
        kind: String,
        metric: String,
        comparison: String,
        summary: String,
        oneTapTitle: String,
        salience: Int,
        verifiedRecent: Double,
        verifiedBaseline: Double,
        verifiedPctChange: Double,
        zScore: Double,
        sampleCount: Int,
        verificationPassed: Bool,
        embedding: Data? = nil,
        embeddingModelID: String = "",
        tombstoned: Bool = false,
        jobRunID: UUID
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.metric = metric
        self.comparison = comparison
        self.summary = summary
        self.oneTapTitle = oneTapTitle
        self.salience = salience
        self.verifiedRecent = verifiedRecent
        self.verifiedBaseline = verifiedBaseline
        self.verifiedPctChange = verifiedPctChange
        self.zScore = zScore
        self.sampleCount = sampleCount
        self.verificationPassed = verificationPassed
        self.embedding = embedding
        self.embeddingModelID = embeddingModelID
        self.tombstoned = tombstoned
        self.jobRunID = jobRunID
    }
}

/// Warm memory: one row per surfaced cross-source correlation — the app's subtle, non-obvious
/// findings. A separate entity from `InsightLog` because a correlation links *two* metrics; the
/// coefficient/sample-count are the verified deterministic truth (the engine is the single source).
@Model
final class CorrelationLog {
    @Attribute(.unique) var id: UUID
    var createdAt: Date

    // Identity. `metricA` leads `metricB` by `lag` days (0 = same day). `pairKey` is the sorted
    // `"a|b"` raw-value key used for the order-independent novelty guard.
    var metricA: String
    var metricB: String
    var lag: Int
    var pairKey: String

    // Verified statistics (never the model's claims).
    var coefficient: Double
    var sampleCount: Int
    var pValue: Double
    /// Whether same-day activity was actually partialled out (false for activity-involving pairs or a
    /// user with no activity data). The UI only claims "not just activity" / "even after accounting for
    /// how active you were" when this is true — never an activity control that didn't happen.
    var activityControlled: Bool

    // LLM-crafted, safety-vetted prose (correlations are never shown as a generic template).
    var summary: String
    var oneTapTitle: String
    /// Feed-quality score (0–100) used to curate the bounded findings budget.
    var quality: Int
    /// Embedding of the story, so curation can drop a correlation that semantically duplicates
    /// another finding (the feed must hold independent, non-overlapping insights).
    @Attribute(.externalStorage) var embedding: Data?

    var jobRunID: UUID
    var tombstoned: Bool
    /// Promoted to "Worth your attention" by the CURATOR agent — see `InsightLog.highlighted`.
    var highlighted = false
    /// How this finding came to be shown — see `InsightLog.provenance`.
    var provenance = ""

    init(
        id: UUID = UUID(),
        createdAt: Date,
        metricA: String,
        metricB: String,
        lag: Int,
        pairKey: String,
        coefficient: Double,
        sampleCount: Int,
        pValue: Double,
        activityControlled: Bool = false,
        summary: String,
        oneTapTitle: String,
        quality: Int,
        embedding: Data? = nil,
        jobRunID: UUID,
        tombstoned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.metricA = metricA
        self.metricB = metricB
        self.lag = lag
        self.pairKey = pairKey
        self.coefficient = coefficient
        self.sampleCount = sampleCount
        self.pValue = pValue
        self.activityControlled = activityControlled
        self.summary = summary
        self.oneTapTitle = oneTapTitle
        self.quality = quality
        self.embedding = embedding
        self.jobRunID = jobRunID
        self.tombstoned = tombstoned
    }
}

/// Deterministic daily aggregate for one metric. The substrate the stats provider reduces.
@Model
final class MetricRollup {
    /// `"<metric>#<dayStartEpoch>"` — unique so re-ingesting a day upserts rather than duplicates.
    @Attribute(.unique) var key: String
    var metric: String
    var dayStart: Date
    var mean: Double
    var count: Int
    var sum: Double
    /// Which HealthKit sources produced this day, canonicalised by `SourceSignature` — empty when
    /// unknown. See `DayValues.sources` for why a rollup records who wrote it.
    var sourceSignature: String = ""

    init(
        key: String,
        metric: String,
        dayStart: Date,
        mean: Double,
        count: Int,
        sum: Double,
        sourceSignature: String = ""
    ) {
        self.key = key
        self.metric = metric
        self.dayStart = dayStart
        self.mean = mean
        self.count = count
        self.sum = sum
        self.sourceSignature = sourceSignature
    }
}

/// Resumable HealthKit cursor: one archived `HKQueryAnchor` per sample type.
@Model
final class SyncAnchor {
    @Attribute(.unique) var sampleType: String
    @Attribute(.externalStorage) var anchorData: Data
    var updatedAt: Date

    init(sampleType: String, anchorData: Data, updatedAt: Date) {
        self.sampleType = sampleType
        self.anchorData = anchorData
        self.updatedAt = updatedAt
    }
}

// Note: insights record a `jobRunID` (UUID) to group those produced by one discovery run. Dedicated
// `JobRun`/`Schedule` audit entities from the original design are intentionally not persisted yet —
// runtime observability is via `os_log`; add them back (and wire them) when a feature reads them.

// MARK: - Typed accessors (non-persisted)

extension InsightLog {
    var metricKey: MetricKey? {
        MetricKey(rawValue: metric)
    }

    var comparisonKey: ComparisonKey? {
        ComparisonKey(rawValue: comparison)
    }

    var insightKind: InsightKind? {
        InsightKind(rawValue: kind)
    }
}

extension CorrelationLog {
    var metricAKey: MetricKey? {
        MetricKey(rawValue: metricA)
    }

    var metricBKey: MetricKey? {
        MetricKey(rawValue: metricB)
    }
}

extension MetricRollup {
    static func makeKey(metric: MetricKey, dayStart: Date) -> String {
        "\(metric.rawValue)#\(Int(dayStart.timeIntervalSince1970))"
    }

    /// The day's canonical value: the daily total for cumulative metrics, the daily mean for
    /// discrete ones.
    func dayValue(for metric: MetricKey) -> Double {
        metric.aggregation == .sum ? sum : mean
    }
}

extension InsightLog: RetirableFinding {}

extension CorrelationLog: RetirableFinding {}
