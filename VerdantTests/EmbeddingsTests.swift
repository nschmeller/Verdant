import Foundation
import Testing
@testable import Verdant

struct EmbeddingsTests {
    @Test func `pack round trips`() {
        let packed = Embeddings.pack([1.5, -2.5, 0.0])
        #expect(Embeddings.unpack(packed) == [Float(1.5), Float(-2.5), Float(0.0)])
    }

    @Test func `cosine of identical vectors is one`() {
        let v = Embeddings.pack([1, 2, 3, 4])
        #expect(abs(Embeddings.cosine(v, v) - 1.0) < 1e-5)
    }

    @Test func `cosine of orthogonal vectors is zero`() {
        let a = Embeddings.pack([1, 0])
        let b = Embeddings.pack([0, 1])
        #expect(abs(Embeddings.cosine(a, b)) < 1e-5)
    }

    @Test func `cosine of mismatched dimensions is zero`() {
        let a = Embeddings.pack([1, 2, 3])
        let b = Embeddings.pack([1, 2])
        #expect(Embeddings.cosine(a, b) == 0)
    }

    @Test func `cosine with a zero-magnitude vector is zero, not NaN`() {
        // A zero vector has no direction, so similarity is undefined (0/0). It must come back 0, not
        // NaN — curation dedups on `cosine >= 0.85` and Q&A retrieval floors at `>= 0.5`, and a NaN
        // silently corrupts those comparisons.
        let zero = Embeddings.pack([0, 0, 0])
        let v = Embeddings.pack([1, 2, 3])
        #expect(Embeddings.cosine(zero, v) == 0)
        #expect(!Embeddings.cosine(zero, v).isNaN)
    }

    @Test func `cosine of opposing vectors is negative`() {
        // The range genuinely reaches −1: two findings whose stories point opposite ways are NOT near
        // duplicates and must never be merged or retrieved as related. If this collapsed to an absolute
        // value, opposites would falsely clear the dedup/relevance thresholds.
        let a = Embeddings.pack([1, 0])
        let b = Embeddings.pack([-1, 0])
        #expect(abs(Embeddings.cosine(a, b) - -1.0) < 1e-5)
    }

    /// A tripwire on a documented precondition.
    ///
    /// `Embeddings` states that every stored vector shares one model id, "so all comparisons are
    /// always valid; if it's ever bumped, callers (`curateFindings`, `InsightSearchTool`) should
    /// start skipping cosine comparisons across differing ids — they don't yet, which is safe only
    /// while the id is constant."
    ///
    /// That is an honest limitation, not a defect: the id IS constant, so the risk is inert. But the
    /// condition it rests on is enforced by nobody. Bump the id — after an OS change to
    /// `NLEmbedding`, say — and vectors from two different spaces start being compared by cosine,
    /// which does not fail: it returns confident, meaningless similarity. `insightSearch` would
    /// offer unrelated past findings as "related", and curation would judge distinctness on noise.
    ///
    /// `snapshotsForSearch` does not even project `embeddingModelID`, so the filter cannot be
    /// written without changing that too. This test is the reminder, sited where the change begins.
    @Test func `bumping the embedding model id requires teaching the comparisons about it`() {
        #expect(
            Embeddings.modelID == "nl.sentence.en.v1",
            """
            The embedding model id changed. Before shipping that, make the cosine comparisons \
            skip vectors stored under a different id: project `embeddingModelID` through \
            `InsightSnapshot`/`snapshotsForSearch`, then filter in `InsightSearchTool` and \
            `curateFindings`. Comparing across model versions returns plausible nonsense.
            """
        )
    }
}

/// What the embedding space actually does, measured against the model the app ships with.
///
/// Every other test here packs vectors by hand and checks the cosine arithmetic. That verifies the
/// formula and says nothing about the space the formula runs in — and the duplicate threshold is a
/// claim about that space. It was 0.85, chosen before anyone measured, and it sat BELOW a pair of
/// findings on different metrics that merely shared a sentence shape (0.856). The curation fallback
/// silently tombstoned genuine findings on that basis.
///
/// These tests need the real model, so they no-op where it is unavailable rather than failing — and
/// say which happened, because a silent skip on the one suite that touches reality would be worse
/// than no suite at all.
struct EmbeddingSpaceTests {
    private let base = "Your resting heart rate has settled at a lower level than it used to sit at."

    private func cosine(_ other: String) async -> Double? {
        let embeddings = Embeddings()
        guard let a = await embeddings.vector(for: base),
              let b = await embeddings.vector(for: other) else { return nil }
        return Embeddings.cosine(a, b)
    }

    @Test func `the shipped model produces usable vectors`() async {
        let embeddings = Embeddings()
        guard let vector = await embeddings.vector(for: base) else {
            let comment = Comment(rawValue: """
            NLEmbedding.sentenceEmbedding(for: .english) is unavailable — semantic dedup and \
            insightSearch relevance are both inert on this OS
            """)
            // Hosted CI runs against a simulator that ships no NLEmbedding asset, so absence there
            // is the environment and not a regression — recorded, but not fatal. Anywhere the model
            // COULD exist (a dev machine, a real device) it still fails outright, because an OS that
            // stopped vending sentence embeddings is exactly what this suite is here to catch.
            if ProcessInfo.processInfo.environment["CI"] != nil {
                withKnownIssue(comment) { Issue.record(comment) }
            } else {
                Issue.record(comment)
            }
            return
        }
        #expect(Embeddings.unpack(vector).count == 512)
    }

    /// The case the threshold exists to catch: near-identical prose about two metrics.
    @Test func `near-identical prose clears the duplicate bar`() async {
        guard let score = await cosine(
            "Your resting heart rate has settled at a lower point than it used to sit at."
        ) else { return }
        #expect(
            score >= StoreWriter.duplicateCosine,
            Comment(rawValue: "one word changed scored \(score); the bar is \(StoreWriter.duplicateCosine)")
        )
    }

    /// The case that made 0.85 wrong: a DIFFERENT metric wearing the same sentence. Nothing about
    /// these two findings is duplicated except their grammar.
    @Test func `a different metric in the same shape stays below the bar`() async {
        guard let score = await cosine(
            "Your step count has settled at a higher level than it used to sit at."
        ) else { return }
        #expect(
            score < StoreWriter.duplicateCosine,
            Comment(rawValue: """
            a shape-match scored \(score) and the bar is \(StoreWriter.duplicateCosine), so a genuine \
            finding on a different metric is silently retired for sharing a sentence shape
            """)
        )
        // And it really does score high — the bar is doing work, not passing on a low number.
        #expect(score > 0.7, Comment(rawValue: "shape-match scored only \(score); re-read the table"))
    }

    /// Unrelated findings must be nowhere near, or the bar means nothing.
    @Test func `an unrelated finding is far below the bar`() async {
        guard let score = await cosine(
            "Your sleep is more erratic on weekends than on weekdays."
        ) else { return }
        #expect(score < 0.6, Comment(rawValue: "an unrelated finding scored \(score)"))
    }
}

/// Whether a QUESTION can actually retrieve a relevant finding, which is a different measurement
/// from whether two findings look alike — and a CHARACTERIZATION of a mechanism that half works.
///
/// `InsightSearchTool.minRelevanceCosine` was 0.5, reasoned against finding-to-finding similarity
/// and then applied to question-to-finding. Measured, a question scores against its own finding
/// between 0.27 and 0.52, and an unrelated pair scores 0.275 — so the low end does not rank
/// relevance at all. 0.35 recalls two of four real pairs where 0.5 recalled one; the misses are the
/// embedding's, not the threshold's, and are pinned here rather than papered over.
struct RetrievalFloorTests {
    private func cosine(_ question: String, _ finding: String) async -> Double? {
        let embeddings = Embeddings()
        guard let a = await embeddings.vector(for: question),
              let b = await embeddings.vector(for: finding) else { return nil }
        return Embeddings.cosine(a, b)
    }

    /// The pairs the floor does recover — and the reason lowering it from 0.5 was worth doing.
    @Test func `the questions the floor recovers clear it`() async {
        let pairs = [
            (
                "Is my heart rate related to how much I walk?",
                "On days you walk more, your resting heart rate that night tends to be lower."
            ),
            (
                "Why are my steps so inconsistent lately?",
                "Your step count has become far more up-and-down over the last month."
            )
        ]
        for (question, finding) in pairs {
            guard let score = await cosine(question, finding) else { return }
            #expect(
                score >= InsightSearchTool.minRelevanceCosine,
                Comment(
                    rawValue: "“\(question)” scored \(score), floor \(InsightSearchTool.minRelevanceCosine)"
                )
            )
        }
    }

    /// Unrelated pairs stay out, or the floor is not a floor.
    @Test func `unrelated pairs stay below the floor`() async {
        let pairs = [
            (
                "How much water should I drink?",
                "Your resting heart rate has settled at a lower level than it used to sit at."
            ),
            ("How tall am I?", "Your step count has become far more up-and-down over the last month.")
        ]
        for (question, finding) in pairs {
            guard let score = await cosine(question, finding) else { return }
            #expect(
                score < InsightSearchTool.minRelevanceCosine,
                Comment(rawValue: "“\(question)” scored \(score) and would retrieve a finding")
            )
        }
    }

    /// The known miss, pinned so it is not rediscovered as a surprise. This question's own finding
    /// scores BELOW an unrelated pair — the space cannot rank it, and no threshold recovers it
    /// without admitting noise. If this ever passes, the embedding improved and the floor deserves
    /// re-measuring.
    @Test func `a known miss is still a miss, and still below an unrelated pair`() async {
        guard let own = await cosine(
            "Do I sleep less in winter?",
            "Your sleep runs shorter in January and February than the rest of the year."
        ), let unrelated = await cosine(
            "How much water should I drink?",
            "Your resting heart rate has settled at a lower level than it used to sit at."
        ) else { return }
        #expect(own < InsightSearchTool.minRelevanceCosine, Comment(rawValue: "recovered at \(own)"))
        #expect(
            own <= unrelated + 0.05,
            Comment(rawValue: "the space now ranks this pair above noise (\(own) vs \(unrelated))")
        )
    }
}
