import Foundation
import SwiftData

/// A Sendable projection of an insight for semantic search (the embedding plus the fields the
/// Answerer needs). `PersistentIdentifier` is Sendable, so this crosses actor boundaries safely.
/// The projection of an insight that semantic Q&A retrieval needs — its story, the metric it's about,
/// and the embedding to score relevance. (No createdAt/salience: retrieval ranks purely by cosine.)
nonisolated struct InsightSnapshot: Identifiable {
    let id: PersistentIdentifier
    let summary: String
    let metric: String
    let embedding: Data?
}

/// Insight-specific writes and reads on the single `StoreWriter`. Kept here (Memory module) for
/// cohesion, but they run on the same actor as ingest writes so everything is serialized.
extension StoreWriter {
    /// Novelty guard: has a non-tombstoned insight for this metric+comparison already surfaced within
    /// `days`? Keeps the feed from repeating the same trend before the window lapses.
    func hasRecentInsight(
        metric: MetricKey,
        comparison: ComparisonKey,
        within days: Int,
        now: Date = .now
    ) throws -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let metricRaw = metric.rawValue
        let comparisonRaw = comparison.rawValue
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.comparison == comparisonRaw
                && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Persist a verified fact. `phrasing` is the finding's final, safety-vetted LLM prose (there is
    /// no template fallback), stored as the shown `summary`/`oneTapTitle`.
    @discardableResult
    func appendInsight(
        fact: VerifiedFact,
        phrasing: FindingPhrasing.Phrasing,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        now: Date = .now
    ) throws -> PersistentIdentifier {
        let row = InsightLog(
            createdAt: now,
            kind: fact.kind.rawValue,
            metric: fact.metric.rawValue,
            comparison: fact.comparison.rawValue,
            summary: phrasing.summary,
            oneTapTitle: phrasing.oneTapTitle,
            salience: fact.salience,
            verifiedRecent: fact.recent,
            verifiedBaseline: fact.baseline,
            verifiedPctChange: fact.pctChange,
            zScore: fact.z,
            sampleCount: fact.n,
            verificationPassed: true,
            embedding: embedding,
            embeddingModelID: embedding == nil ? "" : Embeddings.modelID,
            jobRunID: jobRunID
        )
        row.provenance = provenance
        modelContext.insert(row)
        try modelContext.save()
        return row.persistentModelID
    }

    /// Atomic novelty-check-then-append: dedup and insert run inside the actor as one unit, so
    /// concurrent enhancement tasks can't both pass the novelty check and double-insert the same
    /// (metric, comparison). Returns `nil` if a recent insight for the pair already exists.
    @discardableResult
    func appendInsightIfNovel(
        fact: VerifiedFact,
        phrasing: FindingPhrasing.Phrasing,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        within days: Int = 14,
        now: Date = .now
    ) throws -> PersistentIdentifier? {
        guard try !hasRecentInsight(
            metric: fact.metric,
            comparison: fact.comparison,
            within: days,
            now: now
        ) else { return nil }
        return try appendInsight(
            fact: fact,
            phrasing: phrasing,
            embedding: embedding,
            provenance: provenance,
            jobRunID: jobRunID,
            now: now
        )
    }

    /// Novelty guard for volatility-shift findings. They live in `InsightLog` with the sentinel
    /// comparison `"volatility"`, so they neither collide with nor suppress a mean-trend finding for
    /// the same metric (different question: spread vs. level).
    func hasRecentVolatility(metric: MetricKey, within days: Int, now: Date = .now) throws -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let metricRaw = metric.rawValue
        let sentinel = Self.volatilityComparison
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.comparison == sentinel
                && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Atomic novelty-check-then-append for a volatility-shift finding. The recent/baseline SDs are
    /// stored in the verified-recent/baseline fields, and `%change` is the SD-ratio change so it stays
    /// consistent with the "±recent vs ±baseline" swing the card shows (when the mean held — the case
    /// this finding targets — it equals the CV-ratio change anyway).
    @discardableResult
    func appendVolatilityIfNovel(
        _ shift: VolatilityShift,
        phrasing: FindingPhrasing.Phrasing,
        quality: Int,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        within days: Int = 14,
        now: Date = .now
    ) throws -> PersistentIdentifier? {
        guard try !hasRecentVolatility(metric: shift.metric, within: days, now: now) else { return nil }
        let row = InsightLog(
            createdAt: now,
            kind: InsightKind.volatility.rawValue,
            metric: shift.metric.rawValue,
            comparison: Self.volatilityComparison,
            summary: phrasing.summary,
            oneTapTitle: phrasing.oneTapTitle,
            salience: quality,
            verifiedRecent: shift.recentSD,
            verifiedBaseline: shift.baselineSD,
            verifiedPctChange: (shift.recentSD / shift.baselineSD - 1) * 100,
            zScore: 0,
            sampleCount: shift.n,
            verificationPassed: true,
            embedding: embedding,
            embeddingModelID: embedding == nil ? "" : Embeddings.modelID,
            jobRunID: jobRunID
        )
        row.provenance = provenance
        modelContext.insert(row)
        try modelContext.save()
        return row.persistentModelID
    }

    /// Sentinel `comparison` value marking a volatility-shift `InsightLog` (not a `ComparisonKey`).
    static let volatilityComparison = "volatility"

    /// Novelty guard for annual-rhythm findings (sentinel comparison `"seasonal"`). Its own sentinel
    /// for the same reason volatility has one: "runs high every January" is a different question
    /// from "the level moved recently", and one must not suppress the other for the same metric.
    func hasRecentSeasonal(metric: MetricKey, within days: Int, now: Date = .now) throws -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let metricRaw = metric.rawValue
        let sentinel = Self.seasonalComparison
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.comparison == sentinel
                && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Atomic novelty-check-then-append for an annual-rhythm finding. The peak and opposite months'
    /// effects go in the verified-recent/baseline fields and the swing in the metric's own units in
    /// `%change` — the same shape as the other pattern findings, so the card renders the numbers the
    /// claim is actually about rather than an unrelated recent-vs-baseline pair.
    @discardableResult
    func appendSeasonalIfNovel(
        _ swing: SeasonalSwing,
        phrasing: FindingPhrasing.Phrasing,
        quality: Int,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        within days: Int = 14,
        now: Date = .now
    ) throws -> PersistentIdentifier? {
        guard try !hasRecentSeasonal(metric: swing.metric, within: days, now: now) else { return nil }
        let row = InsightLog(
            createdAt: now,
            kind: InsightKind.seasonal.rawValue,
            metric: swing.metric.rawValue,
            comparison: Self.seasonalComparison,
            summary: phrasing.summary,
            oneTapTitle: phrasing.oneTapTitle,
            salience: quality,
            verifiedRecent: swing.peakEffect,
            verifiedBaseline: swing.oppositeEffect,
            verifiedPctChange: swing.swingInUnits,
            zScore: 0,
            sampleCount: swing.yearsObserved,
            verificationPassed: true,
            embedding: embedding,
            embeddingModelID: embedding == nil ? "" : Embeddings.modelID,
            jobRunID: jobRunID
        )
        row.provenance = provenance
        modelContext.insert(row)
        try modelContext.save()
        return row.persistentModelID
    }

    /// Sentinel `comparison` value marking an annual-rhythm `InsightLog` (not a `ComparisonKey`).
    static let seasonalComparison = "seasonal"

    /// Novelty guard for milestone findings (sentinel comparison `"milestone"`).
    func hasRecentMilestone(metric: MetricKey, within days: Int, now: Date = .now) throws -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let metricRaw = metric.rawValue
        let sentinel = Self.milestoneComparison
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.comparison == sentinel
                && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Atomic novelty-check-then-append for a milestone finding. `verifiedRecent` holds the
    /// record-setting 7-day mean; `sampleCount` holds the days the record stands over.
    @discardableResult
    func appendMilestoneIfNovel(
        _ milestone: Milestone,
        phrasing: FindingPhrasing.Phrasing,
        quality: Int,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        within days: Int = 14,
        now: Date = .now
    ) throws -> PersistentIdentifier? {
        guard try !hasRecentMilestone(metric: milestone.metric, within: days, now: now) else { return nil }
        let row = InsightLog(
            createdAt: now,
            kind: InsightKind.milestone.rawValue,
            metric: milestone.metric.rawValue,
            comparison: Self.milestoneComparison,
            summary: phrasing.summary,
            oneTapTitle: phrasing.oneTapTitle,
            salience: quality,
            verifiedRecent: milestone.recentMean,
            verifiedBaseline: 0,
            verifiedPctChange: milestone.isHigh ? 1 : -1,
            zScore: 0,
            sampleCount: milestone.spanDays,
            verificationPassed: true,
            embedding: embedding,
            embeddingModelID: embedding == nil ? "" : Embeddings.modelID,
            jobRunID: jobRunID
        )
        row.provenance = provenance
        modelContext.insert(row)
        try modelContext.save()
        return row.persistentModelID
    }

    /// Sentinel `comparison` value marking a milestone `InsightLog`.
    static let milestoneComparison = "milestone"

    /// Novelty guard for regime-shift findings (sentinel comparison `"regime"`).
    func hasRecentRegimeShift(metric: MetricKey, within days: Int, now: Date = .now) throws -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let metricRaw = metric.rawValue
        let sentinel = Self.regimeComparison
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.comparison == sentinel
                && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Atomic novelty-check-then-append for a regime-shift finding. `verifiedRecent`/`Baseline` hold
    /// the post/pre baseline means; `sampleCount` holds how long the new level has held.
    @discardableResult
    func appendRegimeShiftIfNovel(
        _ shift: RegimeShift,
        phrasing: FindingPhrasing.Phrasing,
        quality: Int,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        within days: Int = 14,
        now: Date = .now
    ) throws -> PersistentIdentifier? {
        guard try !hasRecentRegimeShift(metric: shift.metric, within: days, now: now) else { return nil }
        let pctChange = shift.preMean == 0 ? 0 : (shift.postMean - shift.preMean) / abs(shift.preMean) * 100
        let row = InsightLog(
            createdAt: now,
            kind: InsightKind.regimeShift.rawValue,
            metric: shift.metric.rawValue,
            comparison: Self.regimeComparison,
            summary: phrasing.summary,
            oneTapTitle: phrasing.oneTapTitle,
            salience: quality,
            verifiedRecent: shift.postMean,
            verifiedBaseline: shift.preMean,
            verifiedPctChange: pctChange,
            zScore: shift.score,
            sampleCount: shift.postDays,
            verificationPassed: true,
            embedding: embedding,
            embeddingModelID: embedding == nil ? "" : Embeddings.modelID,
            jobRunID: jobRunID
        )
        row.provenance = provenance
        modelContext.insert(row)
        try modelContext.save()
        return row.persistentModelID
    }

    /// Sentinel `comparison` value marking a regime-shift `InsightLog`.
    static let regimeComparison = "regime"

    /// Mark EVERY non-tombstoned insight for a metric stale after its underlying samples were deleted in
    /// HealthKit. Deliberately NOT age-bounded: the data is gone, so a finding of any age resting on it
    /// is invalid — and the feed shows findings of any age, so a recency cutoff would leave an old card
    /// live on deleted data. Tombstones rather than deletes, so the audit trail survives.
    func tombstoneInsights(for metric: MetricKey) throws {
        let metricRaw = metric.rawValue
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.tombstoned == false
        })
        let rows = try modelContext.fetch(descriptor)
        for row in rows {
            row.tombstoned = true
        }
        if !rows.isEmpty { try modelContext.save() }
    }

    /// User-initiated "delete all my insights" — hard delete, overriding the append-only policy.
    /// Embeddings live inline on the row and are deleted with it.
    func deleteAllInsights() throws {
        try modelContext.delete(model: InsightLog.self)
        try modelContext.save()
    }

    /// Recent, non-tombstoned insights as Sendable snapshots for embedding search.
    func snapshotsForSearch(within days: Int = 120, now: Date = .now) throws -> [InsightSnapshot] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let descriptor = FetchDescriptor<InsightLog>(
            predicate: #Predicate { $0.tombstoned == false && $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map {
            InsightSnapshot(
                id: $0.persistentModelID,
                summary: $0.summary,
                metric: $0.metric,
                embedding: $0.embedding
            )
        }
    }

    /// The active feed's strongest findings as drill-down anchors — how an indefinite deep run
    /// directs its own depth: when breadth goes dry, it points the focused-lens fleet at what it has
    /// already surfaced. Correlations first (the premium finding), then single-metric insights,
    /// strongest first; keys that no longer resolve (registry changes) are skipped.
    func activeInvestigationFoci(limit: Int) throws -> [InvestigationFocus] {
        var correlationFetch = FetchDescriptor<CorrelationLog>(
            predicate: #Predicate { $0.tombstoned == false },
            sortBy: [SortDescriptor(\.quality, order: .reverse)]
        )
        correlationFetch.fetchLimit = limit
        var insightFetch = FetchDescriptor<InsightLog>(
            predicate: #Predicate { $0.tombstoned == false },
            sortBy: [SortDescriptor(\.salience, order: .reverse)]
        )
        insightFetch.fetchLimit = limit
        var foci: [InvestigationFocus] = []
        for row in try modelContext.fetch(correlationFetch) {
            guard let metricA = row.metricAKey else { continue }
            foci.append(InvestigationFocus(
                metric: metricA, secondaryMetric: row.metricBKey, title: row.oneTapTitle
            ))
        }
        for row in try modelContext.fetch(insightFetch) {
            guard let metric = row.metricKey else { continue }
            foci.append(InvestigationFocus(metric: metric, secondaryMetric: nil, title: row.oneTapTitle))
        }
        return Array(foci.prefix(limit))
    }

    /// Short descriptors of EVERY finding surfaced recently (insights and correlations), fed to the
    /// investigator so its lens fleet digs for new ground instead of re-proposing what the novelty
    /// gate would reject anyway — the difference between a pass going dry and a pass going deeper.
    func recentFindingDescriptors(within days: Int = 14, now: Date = .now) throws -> [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let insights = try modelContext.fetch(FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.tombstoned == false && $0.createdAt >= cutoff
        }))
        let correlations = try modelContext.fetch(FetchDescriptor<CorrelationLog>(predicate: #Predicate {
            $0.tombstoned == false && $0.createdAt >= cutoff
        }))
        var out: [String] = []
        for row in insights {
            out.append("\(row.kind) on \(row.metricKey?.displayName ?? row.metric)")
        }
        for row in correlations {
            let a = row.metricAKey?.displayName ?? row.metricA
            let b = row.metricBKey?.displayName ?? row.metricB
            out.append("link \(a) ↔ \(b)")
        }
        return out
    }

    /// The standing finding a candidate would collide with — title + story + age — as PRIOR
    /// context for the novelty-judge agent. Freshness is an AGENT decision: this lookup only
    /// SELECTS the standing finding; nothing is dropped by the clock alone. `nil` means no active
    /// finding for the same key surfaced within the lookback (no collision, nothing to judge).
    func recentPriorDescriptor(
        kind: InsightKind,
        metric: MetricKey,
        secondaryMetric: MetricKey?,
        comparison: ComparisonKey?,
        within days: Int,
        now: Date = .now
    ) throws -> String? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        if kind == .correlation, let other = secondaryMetric, other != metric {
            let key = [metric.rawValue, other.rawValue].sorted().joined(separator: "|")
            let descriptor = FetchDescriptor<CorrelationLog>(predicate: #Predicate {
                $0.pairKey == key && $0.tombstoned == false && $0.createdAt >= cutoff
            })
            guard let row = try modelContext.fetch(descriptor).first else { return nil }
            return Self.priorDescriptor(
                title: row.oneTapTitle, summary: row.summary, createdAt: row.createdAt, now: now
            )
        }
        let comparisonRaw: String = switch kind {
        case .volatility: Self.volatilityComparison
        case .milestone: Self.milestoneComparison
        case .regimeShift: Self.regimeComparison
        case .seasonal: Self.seasonalComparison
        // A correlation without a valid distinct pair can't collide with anything — it will be
        // dropped downstream; don't spend a judge on an unrelated single-metric lookup.
        case .correlation: ""
        // Exhaustive, with no `default`. Each pattern kind stores under its own SENTINEL comparison,
        // so a kind that fell through would look itself up under the passed `ComparisonKey` — empty
        // for every pattern kind — return no prior, and skip the novelty judge entirely. Nothing
        // fails; the same finding is simply free to surface again. The level-change kinds below do
        // legitimately key on their comparison.
        case .trend, .anomaly, .redFlag, .none: comparison?.rawValue ?? ""
        }
        guard !comparisonRaw.isEmpty else { return nil }
        let metricRaw = metric.rawValue
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.metric == metricRaw && $0.comparison == comparisonRaw
                && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        return Self.priorDescriptor(
            title: row.oneTapTitle, summary: row.summary, createdAt: row.createdAt, now: now
        )
    }

    /// One clamped "prior finding" line for the novelty judge — stored prose is model-written and
    /// rides into a 4k session.
    private static func priorDescriptor(
        title: String, summary: String, createdAt: Date, now: Date
    ) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: createdAt, to: now).day ?? 0)
        return "\(PromptText.clamped(title, to: 80)): \(PromptText.clamped(summary, to: 240)) "
            + "(surfaced \(days) day\(days == 1 ? "" : "s") ago)"
    }

    /// Kinds of insights surfaced in the last `days`, for the Discovery digest.
    func recentInsightKinds(within days: Int = 14, now: Date = .now) throws -> [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try Array(Set(modelContext.fetch(descriptor).map(\.kind)))
    }
}
