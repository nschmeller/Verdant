import Foundation
import SwiftData

/// Correlation-specific writes/reads and the unified findings-budget curation, on the single
/// `StoreWriter` actor so every mutation stays serialized with insight and ingest writes.
extension StoreWriter {
    /// Novelty guard for correlations: has a non-tombstoned correlation for the same unordered
    /// metric pair surfaced within `days`? Keyed on `pairKey` so `{A,B}` and `{B,A}` collapse.
    func hasRecentCorrelation(pairKey: String, within days: Int, now: Date = .now) throws -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let key = pairKey
        let descriptor = FetchDescriptor<CorrelationLog>(predicate: #Predicate {
            $0.pairKey == key && $0.tombstoned == false && $0.createdAt >= cutoff
        })
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// Mark EVERY non-tombstoned correlation involving `metric` stale after its underlying samples were
    /// deleted in HealthKit — the mirror of `tombstoneInsights`. A correlation rests on BOTH metrics'
    /// data, so a deletion of either invalidates it. Not age-bounded, for the same reason as the insight
    /// version: a connection card of any age must not keep showing numbers derived from removed data.
    func tombstoneCorrelations(for metric: MetricKey) throws {
        let raw = metric.rawValue
        let descriptor = FetchDescriptor<CorrelationLog>(predicate: #Predicate {
            ($0.metricA == raw || $0.metricB == raw) && $0.tombstoned == false
        })
        let rows = try modelContext.fetch(descriptor)
        for row in rows {
            row.tombstoned = true
        }
        if !rows.isEmpty { try modelContext.save() }
    }

    /// Atomic novelty-check-then-append for a verified correlation: dedup + insert run as one unit
    /// inside the actor, so concurrent enhancement tasks can't double-insert the same pair. `quality`
    /// is the trust-weighted, surprise-blended feed score computed by the orchestrator.
    @discardableResult
    func appendCorrelationIfNovel(
        _ correlation: MetricCorrelation,
        phrasing: FindingPhrasing.Phrasing,
        quality: Int,
        embedding: Data? = nil,
        provenance: String = "",
        jobRunID: UUID,
        within days: Int = 14,
        now: Date = .now
    ) throws -> PersistentIdentifier? {
        guard try !hasRecentCorrelation(pairKey: correlation.pairKey, within: days, now: now) else {
            return nil
        }
        let row = CorrelationLog(
            createdAt: now,
            metricA: correlation.metricA.rawValue,
            metricB: correlation.metricB.rawValue,
            lag: correlation.lag,
            pairKey: correlation.pairKey,
            // Store the activity-controlled coefficient — it's what the story, sign, badge, and
            // chart are all about; the raw r can differ in sign once activity is partialled out.
            coefficient: correlation.partialR,
            sampleCount: correlation.n,
            pValue: correlation.pValue,
            activityControlled: correlation.activityControlled,
            summary: phrasing.summary,
            oneTapTitle: phrasing.oneTapTitle,
            quality: quality,
            embedding: embedding,
            jobRunID: jobRunID
        )
        row.provenance = provenance
        modelContext.insert(row)
        try modelContext.save()
        return row.persistentModelID
    }

    func deleteAllCorrelations() throws {
        try modelContext.delete(model: CorrelationLog.self)
        try modelContext.save()
    }

    /// Enforce the bounded, high-quality, **independent** findings budget. The feed should hold a few
    /// of the best findings, each as distinct from the others as possible — zero duplication. Greedy
    /// by quality, a finding is kept only if it (a) introduces a metric not already covered (so no two
    /// findings are about the same signal), (b) doesn't over-concentrate a body system, and (c) isn't
    /// semantically near an already-kept finding's story. Tombstoning (not deleting) keeps the audit
    /// trail.
    func curateFindings(maxActive: Int, now _: Date = .now) throws {
        let insightDescriptor = FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.tombstoned == false
        })
        let correlationDescriptor = FetchDescriptor<CorrelationLog>(predicate: #Predicate {
            $0.tombstoned == false
        })
        let insights = try modelContext.fetch(insightDescriptor)
        let correlations = try modelContext.fetch(correlationDescriptor)

        var ranked: [RankedFinding] = []
        for row in insights {
            ranked.append(RankedFinding(
                quality: row.salience, createdAt: row.createdAt,
                metrics: [row.metricKey].compactMap(\.self), embedding: row.embedding
            ) { row.tombstoned = true })
        }
        for row in correlations {
            ranked.append(RankedFinding(
                quality: row.quality, createdAt: row.createdAt,
                metrics: [row.metricAKey, row.metricBKey].compactMap(\.self), embedding: row.embedding
            ) { row.tombstoned = true })
        }
        ranked.sort {
            $0.quality != $1.quality ? $0.quality > $1.quality : $0.createdAt > $1.createdAt
        }

        var usedMetrics = Set<MetricKey>()
        var domainCount: [MetricDomain: Int] = [:]
        var keptEmbeddings: [Data] = []
        var kept = 0
        var changed = false
        for item in ranked {
            let domains = Set(item.metrics.map(\.domain))
            let reusesMetric = item.metrics.contains { usedMetrics.contains($0) }
            let overDomain = domains.contains { (domainCount[$0] ?? 0) >= Self.maxFindingsPerDomain }
            // The same STORY on two metrics is a duplicate and one must go. The bar for "same
            // story" is 0.93, not the 0.85 it was, and the difference is measured rather than
            // chosen — with the model this app actually uses (`NLEmbedding.sentenceEmbedding(for:
            // .english)`, 512 static dims):
            //
            //     1.000  identical text
            //     0.948  one word changed                 <- the same story
            //     0.863  the same claim reworded
            //     0.856  a DIFFERENT metric, same shape   <- not a duplicate at all
            //     0.662  the model re-telling the finding
            //     0.420  an unrelated finding
            //
            // At 0.85 this clause silently TOMBSTONED "your step count has settled at a higher level
            // than it used to sit at" for sitting seven thousandths above the bar beside the same
            // sentence about resting heart rate. Static sentence vectors key on syntax, so nothing
            // separates a reworded duplicate (0.863) from a shape-match (0.856) — and this clause
            // only ever sees findings on DIFFERENT metrics, because `reusesMetric` above has already
            // retired the same-metric ones.
            //
            // So it now catches only what is unambiguous. The ambiguous middle goes where it can
            // actually be judged: `curationRoster` computes the same cosine and hands the curator
            // "[near-duplicate of #N]" as a fact, and an agent can read both findings where a
            // threshold cannot. This clause is the fallback's floor, not its judgement.
            let duplicate = item.embedding.map { candidate in
                keptEmbeddings.contains { Embeddings.cosine(candidate, $0) >= Self.duplicateCosine }
            } ?? false
            if kept >= maxActive || reusesMetric || overDomain || duplicate {
                item.tombstone()
                changed = true
                continue
            }
            kept += 1
            if let embedding = item.embedding { keptEmbeddings.append(embedding) }
            usedMetrics.formUnion(item.metrics)
            for domain in domains {
                domainCount[domain, default: 0] += 1
            }
        }
        if changed { try modelContext.save() }
    }

    /// At most this many active findings may touch the same body system.
    private static let maxFindingsPerDomain = 3
    /// Cosine similarity at/above which two findings' stories are considered duplicates.
    /// The bar for "these two findings tell the same story". Measured against the real embedding
    /// space, not chosen: 0.85 sat below a different-metric shape-match (0.856) and silently retired
    /// genuine findings. See the table beside its use in `curateFindings`.
    ///
    /// Internal, not private, so `EmbeddingSpaceTests` can assert this NUMBER against real vectors
    /// rather than restating it. Written the other way first, the tests hardcoded 0.93 and passed
    /// happily when the constant was put back to 0.85 — pinning the embedding space while leaving
    /// the thing that reads it free to drift.
    static let duplicateCosine = 0.93

    // MARK: Agent curation

    /// Roster rows the curator can weigh in one 4k session. Strongest-first, so anything past the
    /// cap is the weakest tail — it stays active this round and enters the next round's roster
    /// once retirements free slots (curation runs at every substrate refresh and run end).
    private static let maxRosterRows = 18

    /// The curator agent's numbered roster of every active finding, strongest-first. The
    /// deterministic signals the old greedy trim DECIDED with — quality rank, shared metrics,
    /// embedding near-duplicates, body-system concentration — ride along as per-row FACTS; the
    /// keep/retire decision is the agent's (`Subagents.curate`).
    func curationRoster(now: Date = .now) throws -> [CurationCandidate] {
        struct Row {
            let target: AuditCandidate.Target
            let title: String
            let kindLabel: String
            let quality: Int
            let createdAt: Date
            let metrics: [MetricKey]
            let embedding: Data?
        }
        let insights = try modelContext.fetch(FetchDescriptor<InsightLog>(predicate: #Predicate {
            $0.tombstoned == false
        }))
        let correlations = try modelContext
            .fetch(FetchDescriptor<CorrelationLog>(predicate: #Predicate { $0.tombstoned == false }))
        var rows: [Row] = insights.map {
            Row(
                target: .insight($0.id), title: $0.oneTapTitle, kindLabel: $0.kind,
                quality: $0.salience, createdAt: $0.createdAt,
                metrics: [$0.metricKey].compactMap(\.self), embedding: $0.embedding
            )
        }
        rows += correlations.map {
            Row(
                target: .correlation($0.id), title: $0.oneTapTitle, kindLabel: "correlation",
                quality: $0.quality, createdAt: $0.createdAt,
                metrics: [$0.metricAKey, $0.metricBKey].compactMap(\.self), embedding: $0.embedding
            )
        }
        rows.sort {
            $0.quality != $1.quality ? $0.quality > $1.quality : $0.createdAt > $1.createdAt
        }
        rows = Array(rows.prefix(Self.maxRosterRows))

        return rows.enumerated().map { index, row in
            let age = max(0, Calendar.current.dateComponents(
                [.day], from: row.createdAt, to: now
            ).day ?? 0)
            let names = row.metrics.map(\.displayName).joined(separator: " + ")
            var notes: [String] = []
            if let sharing = rows.prefix(index).enumerated().first(where: { _, earlier in
                earlier.metrics.contains { row.metrics.contains($0) }
            }) {
                notes.append("[shares a metric with #\(sharing.offset)]")
            }
            if let embedding = row.embedding,
               let dupe = rows.prefix(index).enumerated().first(where: { _, earlier in
                   earlier.embedding.map {
                       Embeddings.cosine(embedding, $0) >= Self.duplicateCosine
                   } ?? false
               })
            {
                notes.append("[near-duplicate of #\(dupe.offset)]")
            }
            let note = notes.isEmpty ? "" : " " + notes.joined(separator: " ")
            let line = "\(index). \(row.kindLabel) “\(PromptText.clamped(row.title, to: 60))” — "
                + "q\(row.quality), \(age)d old, \(String(names.prefix(60)))\(note)"
            return CurationCandidate(index: index, line: line, target: row.target)
        }
    }
}

/// One row of the curator agent's roster: the numbered descriptor line it reads (with the
/// computed overlap/duplicate facts inline) and the retirement target for a number it leaves out.
nonisolated struct CurationCandidate {
    let index: Int
    let line: String
    let target: AuditCandidate.Target
}

/// A finding (insight or correlation) reduced to what curation needs: a comparable quality score,
/// a recency tie-break, the metrics it touches and its story embedding (for independence), and a
/// closure that tombstones it.
private nonisolated struct RankedFinding {
    let quality: Int
    let createdAt: Date
    let metrics: [MetricKey]
    let embedding: Data?
    let tombstone: () -> Void
}
