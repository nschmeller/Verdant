import Foundation
import SwiftData

/// Research-journal writes/reads on the single `StoreWriter` actor — the agent fleet's persistent
/// cross-run memory (see `ResearchJournalEntry`). Serialized with every other mutation like the
/// rest of the Memory module.
extension StoreWriter {
    /// Append one journal entry. Text and reason are clamped HERE (the single choke point): both
    /// are model-written strings, and journal lines ride inside future 4k-token prompts.
    func recordJournal(
        kind: ResearchJournalKind,
        text: String,
        reason: String = "",
        jobRunID: UUID,
        now: Date = .now
    ) throws {
        modelContext.insert(ResearchJournalEntry(
            createdAt: now,
            kind: kind.rawValue,
            text: PromptText.clamped(text, to: 90),
            reason: PromptText.clamped(reason, to: 90),
            jobRunID: jobRunID
        ))
        try modelContext.save()
        try pruneJournal()
    }

    /// Steering lines from PRIOR runs — the most recent rejected/retired claims, newest first,
    /// capped hard (they ride in a 4k window). The current run is excluded: its in-memory
    /// `RunLedger` already steers it, and mixing the two would repeat every line twice.
    func journalSteering(
        excludingRun jobRunID: UUID,
        limit: Int = 4,
        within days: Int = 21,
        now: Date = .now
    ) throws -> [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let rejected = ResearchJournalKind.rejected.rawValue
        let retired = ResearchJournalKind.retired.rawValue
        var descriptor = FetchDescriptor<ResearchJournalEntry>(
            predicate: #Predicate {
                $0.jobRunID != jobRunID && $0.createdAt >= cutoff
                    && ($0.kind == rejected || $0.kind == retired)
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            $0.reason.isEmpty ? $0.text : "\($0.text) (\($0.reason))"
        }
    }

    /// Journal lines of ONE kind, newest first — the agent-queryable view behind the
    /// `researchJournal` tool. Where `journalSteering` PUSHES a fixed do-not-repeat list at every
    /// agent, this lets one ASK: what has actually been established? what did the audit retire, and
    /// why? Same clamping discipline — the rows were clamped at write time and the caller bounds the
    /// count, because these ride in a 4k window.
    func journalEntries(
        kind: ResearchJournalKind,
        limit: Int,
        within days: Int = 90,
        now: Date = .now
    ) throws -> [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<ResearchJournalEntry>(
            predicate: #Predicate { $0.kind == raw && $0.createdAt >= cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try modelContext.fetch(descriptor).map {
            $0.reason.isEmpty ? $0.text : "\($0.text) — \($0.reason)"
        }
    }

    /// Erase the fleet's cross-run memory. Part of the user's delete-all, and load-bearing for it:
    /// the journal is literally "what Verdant has already shown you" (every confirmed finding) plus
    /// every dead end, and `journalSteering` pushes the rejections and retirements at investigators
    /// as "do NOT re-propose". Leaving it behind made the Settings promise false twice over — the
    /// memory survived, and the fleet went on avoiding the very ground the user had just cleared, so
    /// "Verdant can rediscover findings over time" was actively impeded for as long as the steering
    /// window lasted.
    func deleteJournal() throws {
        try modelContext.delete(model: ResearchJournalEntry.self)
        try modelContext.save()
    }

    /// Bound the journal: an INDEFINITE research program appends entries for as long as the app
    /// stays open, so an unpruned table would grow without limit. Keeps the newest `keep` rows.
    func pruneJournal(keep: Int = 400) throws {
        let total = try modelContext.fetchCount(FetchDescriptor<ResearchJournalEntry>())
        guard total > keep else { return }
        var oldest = FetchDescriptor<ResearchJournalEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        oldest.fetchLimit = total - keep
        for row in try modelContext.fetch(oldest) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
