import Foundation
import FoundationModels

/// Results returned to the Answerer: a few short, related past-insight summaries.
@Generable nonisolated struct InsightSearchResults {
    @Guide(description: "Related past insights, most relevant first")
    let results: [String]
}

/// The Answerer's only tool: embedding-similarity search over the user's own insight log. Capped
/// hard (top-3, each truncated) so it cannot blow the context window. Body is fully local.
nonisolated struct InsightSearchTool: Tool {
    let name = "insightSearch"
    let description = "Searches your previously surfaced health insights for ones related to the question."

    @Generable nonisolated struct Arguments {
        @Guide(description: "What to search for, in a few words")
        let query: String
    }

    let writer: StoreWriter
    let embeddings: Embeddings
    let now: Date

    /// Minimum query↔insight cosine to count as *related*. Without a floor the tool returns its top-3
    /// no matter how dissimilar — so a question with no related history gets three near-random
    /// insights, which the Answerer is told to weave in as "context", padding the answer with noise.
    /// Returning nothing is the better failure: the Answerer simply answers from the numbers.
    ///
    /// MEASURED 2026-08-03, because 0.5 was reasoned rather than measured — set "below the
    /// near-duplicate bar" on the assumption that a question scores like a finding. It does not. A
    /// QUESTION and a FINDING are different kinds of sentence, and against the app's own model
    /// (`NLEmbedding`, 512 static dims), scoring each question against ITS OWN relevant finding:
    ///
    ///     0.521  "Is my heart rate related to how much I walk?"
    ///     0.430  "How has my resting heart rate been?"
    ///     0.353  "Why are my steps so inconsistent lately?"
    ///     0.273  "Do I sleep less in winter?"          <- its own finding
    ///     0.275  "How much water should I drink?"      <- an UNRELATED finding
    ///     0.115  "How tall am I?"                      <- an unrelated finding
    ///
    /// Read the last three together: a question matches its own finding LESS than an unrelated
    /// question matches an unrelated one. At the low end this space does not rank relevance at all,
    /// so no threshold recovers those cases and none is claimed to.
    ///
    /// 0.35 is simply the best available trade, not a fix. It recalls two of the four real pairs
    /// where 0.5 recalled one, and admits neither unrelated pair. The remaining misses are a property
    /// of the embedding, and the honest options for them are a better model
    /// (`NLContextualEmbedding` downloads assets, which the zero-cloud promise refuses) or dropping
    /// cosine retrieval for something lexical. Both are larger decisions than a constant.
    static let minRelevanceCosine = 0.35

    func call(arguments: Arguments) async throws -> InsightSearchResults {
        let snapshots = await (try? writer.snapshotsForSearch(now: now)) ?? []

        // No embedding model is the only reason to skip the relevance check: we can't score similarity,
        // so we can't claim relatedness. Return nothing rather than recency-as-relevance — an
        // unrelated "for context" insert is worse than none, and the Answerer reads fine without it.
        guard let queryVector = await embeddings.vector(for: arguments.query) else {
            return InsightSearchResults(results: [])
        }

        let ranked = snapshots
            .compactMap { snapshot -> (InsightSnapshot, Double)? in
                guard let embedding = snapshot.embedding else { return nil }
                return (snapshot, Embeddings.cosine(queryVector, embedding))
            }
            .filter { $0.1 >= Self.minRelevanceCosine }
            .sorted { $0.1 > $1.1 }
            .prefix(TokenBudget.maxRetrievedMemories)
            .map { truncate($0.0.summary) }

        return InsightSearchResults(results: Array(ranked))
    }

    private func truncate(_ text: String) -> String {
        String(text.prefix(TokenBudget.maxMemoryCharacters))
    }
}
