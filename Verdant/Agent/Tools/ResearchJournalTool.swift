import Foundation
import FoundationModels

@Generable nonisolated struct JournalLines {
    @Guide(description: "Journal lines, newest first; empty if nothing of that kind is recorded")
    let lines: [String]
}

/// A **logical tool** over the fleet's own cross-run memory (`ResearchJournalEntry`): what previous
/// runs established, what the panels rejected and why, what the audit retired.
///
/// Every other agent has this history PUSHED at it as a fixed do-not-repeat list. That is right for
/// an investigator — it needs steering, not a research question. The research director is the one
/// agent whose actual job is deciding from history, and it was making that call from three clamped
/// lines chosen for it. Now it can ask: has anything been confirmed lately, or are we churning? what
/// keeps getting rejected, and for what reason? Its session is prose-only and tiny, so it has room
/// for a tool the crowded investigator sessions could never afford. 100% local.
nonisolated struct ResearchJournalTool: Tool {
    let name = "researchJournal"
    let description = "The fleet's memory across runs: findings CONFIRMED (each with the angle that "
        + "found it), hypotheses REJECTED (with the panel's reason), findings the audit RETIRED, and "
        + "BARREN angles that were chased and yielded nothing. Ask before choosing a strategy — which "
        + "kinds of looking keep paying off, and what keeps failing."

    /// The row cap, stated once. It was written three times — in the guide's prose, in the
    /// `.range`, and in the clamp — and those are the transcriptions that silently disagree.
    static let maxLines = 8

    @Generable nonisolated struct Arguments {
        @Guide(description: "Which history to read", .anyOf(ResearchJournalKind.allRawValues))
        let kind: String
        @Guide(
            description: "Max lines to return (1-\(ResearchJournalTool.maxLines))",
            .range(1...ResearchJournalTool.maxLines)
        )
        let limit: Int
    }

    let writer: StoreWriter
    let now: Date

    func call(arguments: Arguments) async throws -> JournalLines {
        // The closed vocabulary is the boundary, as everywhere else: an unrecognized kind returns
        // nothing rather than being coerced into one the director didn't ask for.
        guard let kind = ResearchJournalKind(rawValue: arguments.kind) else {
            return JournalLines(lines: [])
        }
        let lines = await (try? writer.journalEntries(
            kind: kind, limit: max(1, min(Self.maxLines, arguments.limit)), now: now
        )) ?? []
        return JournalLines(lines: lines)
    }
}
