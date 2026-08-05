import Foundation
import SwiftData

/// What the standing-finding audit needs about one active finding — Sendable, so it crosses from
/// the store actor to the orchestrator. Targets carry the row's stable `UUID` (not a
/// `PersistentIdentifier`): retirement must re-fetch defensively, because the row can be
/// hard-deleted mid-run (Settings' delete-all doesn't hold the run gate).
nonisolated struct AuditCandidate {
    enum Target: Hashable {
        case insight(UUID)
        case correlation(UUID)
    }

    let target: Target
    let title: String
    /// The registry keys this standing finding is about, so the replication analysts re-testing it
    /// know which series to pull — see `Orchestrator.survivesReplication`. Without them an analyst
    /// has only the finding's prose and guesses the key, which it was observed getting wrong.
    let metrics: [MetricKey]
    /// The claim under re-test — the finding's shown summary, clamped (stored prose carries no
    /// schema-side length bound, and this text rides into three 4k replication sessions).
    let claim: String
}

/// Audit-specific reads/writes on the single `StoreWriter` actor, serialized with every other
/// mutation like the rest of the Memory module.
extension StoreWriter {
    /// The audit's docket: `limit` ACTIVE findings, both kinds, INTERLEAVED (strongest correlation,
    /// strongest insight, second correlation, …) rather than correlations-first — a correlation-rich
    /// feed would otherwise fill the whole docket and single-metric insights would never be
    /// re-audited.
    ///
    /// `round` ROTATES the window through the ranked feed. It used to be the strongest `limit`
    /// findings at every refresh, forever: with a feed of 11 and a docket of 4, findings ranked 5+
    /// were re-tested exactly never, so a mid-ranked claim that had quietly stopped holding could
    /// sit there for the life of the app. Rotating is coverage plumbing, not a worth judgment — it
    /// decides WHEN each finding faces the panel, never whether it survives; the strongest still come
    /// up first, and every standing finding now comes up within a few refreshes.
    func auditCandidates(limit: Int, round: Int = 0) throws -> [AuditCandidate] {
        var correlationFetch = FetchDescriptor<CorrelationLog>(
            predicate: #Predicate { $0.tombstoned == false },
            sortBy: [SortDescriptor(\.quality, order: .reverse)]
        )
        // The whole active feed, not just the docket's worth: `round` rotates a window through this
        // ranked list, so it has to be able to see past the head. Bounded by the feed's own budget.
        let ranked = EnhancementPolicy.maxActiveFindings
        correlationFetch.fetchLimit = ranked
        var insightFetch = FetchDescriptor<InsightLog>(
            predicate: #Predicate { $0.tombstoned == false },
            sortBy: [SortDescriptor(\.salience, order: .reverse)]
        )
        insightFetch.fetchLimit = ranked
        let correlations = try modelContext.fetch(correlationFetch).map { row in
            AuditCandidate(
                target: .correlation(row.id),
                title: row.oneTapTitle,
                metrics: [row.metricAKey, row.metricBKey].compactMap(\.self),
                claim: PromptText.clamped(row.summary, to: 400)
            )
        }
        let insights = try modelContext.fetch(insightFetch).map { row in
            AuditCandidate(
                target: .insight(row.id),
                title: row.oneTapTitle,
                metrics: [row.metricKey].compactMap(\.self),
                claim: PromptText.clamped(row.summary, to: 400)
            )
        }
        var interleaved: [AuditCandidate] = []
        var rank = 0
        while rank < max(correlations.count, insights.count) {
            if rank < correlations.count { interleaved.append(correlations[rank]) }
            if rank < insights.count { interleaved.append(insights[rank]) }
            rank += 1
        }
        guard !interleaved.isEmpty, limit > 0 else { return [] }
        // Walk the whole ranked list across successive rounds, wrapping — so a docket smaller than
        // the feed still reaches every finding instead of re-testing the same head forever.
        let start = (round * limit) % interleaved.count
        return (0..<min(limit, interleaved.count)).map { interleaved[(start + $0) % interleaved.count] }
    }

    /// Apply the curator's standout picks: every active finding it named is highlighted, every
    /// other is not. Written as a whole SET rather than one flag at a time, so a curation round can
    /// never leave promotions behind from the round before it — the section shows one agent's
    /// decision, not an accumulation of several.
    ///
    /// The precise scope, because the stronger phrasing was wrong: this holds for every round that
    /// actually runs. `Orchestrator.curate` returns early on a roster of one and falls back to the
    /// deterministic trim when the model is unavailable, and neither calls this — so the last
    /// decision an agent DID make stands rather than being cleared. That is the better behaviour
    /// (clearing would make highlights flap whenever Apple Intelligence is briefly unavailable), but
    /// it means a highlight can outlive the round that set it. Retired findings drop out regardless:
    /// the feed only reads active rows.
    /// Bound the RETIRED findings, for the same reason `pruneJournal` bounds the journal and with
    /// the same shape: an indefinite research program retires findings for as long as the app stays
    /// open, and a tombstoned row is never deleted otherwise — only a user's "delete all" clears
    /// them. The table grew without limit on the app's own headline use case, running for days.
    ///
    /// Safe because nothing reads a retired row. Every feed, novelty and curation query filters
    /// `tombstoned == false`; `setHighlights` below is the one fetch that does not, and it skips them
    /// explicitly — so pruning also stops that per-round scan growing forever, which is the cost that
    /// would have been felt first.
    ///
    /// Some are kept rather than none: a just-retired finding is the most likely thing a user asks
    /// about, and `deleteAllInsights` is the only intended way to erase history outright.
    func pruneRetiredFindings(keep: Int = 200) throws {
        var deleted = false
        deleted = try pruneRetired(InsightLog.self, keep: keep) || deleted
        deleted = try pruneRetired(CorrelationLog.self, keep: keep) || deleted
        if deleted { try modelContext.save() }
    }

    /// Oldest-first deletion of tombstoned rows beyond `keep`, for one model.
    private func pruneRetired<Row: RetirableFinding>(_: Row.Type, keep: Int) throws -> Bool {
        var retired = FetchDescriptor<Row>(
            predicate: #Predicate { $0.tombstoned == true },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let total = try modelContext.fetchCount(retired)
        guard total > keep else { return false }
        retired.fetchLimit = total - keep
        for row in try modelContext.fetch(retired) {
            modelContext.delete(row)
        }
        return true
    }

    func setHighlights(_ targets: Set<AuditCandidate.Target>) throws {
        var changed = false
        for row in try modelContext.fetch(FetchDescriptor<InsightLog>()) {
            let wanted = targets.contains(.insight(row.id)) && !row.tombstoned
            if row.highlighted != wanted { row.highlighted = wanted; changed = true }
        }
        for row in try modelContext.fetch(FetchDescriptor<CorrelationLog>()) {
            let wanted = targets.contains(.correlation(row.id)) && !row.tombstoned
            if row.highlighted != wanted { row.highlighted = wanted; changed = true }
        }
        if changed { try modelContext.save() }
    }

    /// Retire ONE finding the audit failed — tombstoned, never deleted, so the audit trail survives
    /// (the same retirement mechanism curation and HealthKit-deletion handling use). Fetches
    /// defensively by unique id: retiring a row that's already gone is a no-op, not a crash.
    func retire(_ target: AuditCandidate.Target) throws {
        switch target {
        case let .insight(id):
            let descriptor = FetchDescriptor<InsightLog>(predicate: #Predicate { $0.id == id })
            guard let row = try modelContext.fetch(descriptor).first, !row.tombstoned else { return }
            row.tombstoned = true
            try modelContext.save()
        case let .correlation(id):
            let descriptor = FetchDescriptor<CorrelationLog>(predicate: #Predicate { $0.id == id })
            guard let row = try modelContext.fetch(descriptor).first, !row.tombstoned else { return }
            row.tombstoned = true
            try modelContext.save()
        }
    }
}
