import Foundation
import NaturalLanguage

/// On-device sentence embeddings via `NLEmbedding` (classic static vectors — fully local, no asset
/// download, unlike `NLContextualEmbedding`). Vectors are packed as `Float32` `Data` for compact
/// storage; cosine similarity runs over the packed form with no model needed.
///
/// `modelID` pins the embedding space: vectors from different model versions are not comparable, so
/// every stored vector records the id it was produced with. Today `modelID` is a fixed constant, so
/// all stored vectors share it and comparisons are always valid; if it's ever bumped, callers
/// (`curateFindings`, `InsightSearchTool`) should start skipping cosine comparisons across differing
/// ids — they don't yet, which is safe only while the id is constant.
actor Embeddings {
    static let modelID = "nl.sentence.en.v1"

    private var embedding: NLEmbedding?

    private func model() -> NLEmbedding? {
        if embedding == nil { embedding = NLEmbedding.sentenceEmbedding(for: .english) }
        return embedding
    }

    /// Packed `Float32` vector for `text`, or `nil` if the embedding model is unavailable or the
    /// text has no representation.
    func vector(for text: String) -> Data? {
        guard let doubles = model()?.vector(for: text) else { return nil }
        return Self.pack(doubles)
    }

    nonisolated static func pack(_ doubles: [Double]) -> Data {
        let floats = doubles.map { Float($0) }
        return floats.withUnsafeBytes { Data($0) }
    }

    nonisolated static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Cosine similarity in [-1, 1]; `0` for empty or mismatched-dimension vectors.
    nonisolated static func cosine(_ a: Data, _ b: Data) -> Double {
        let x = unpack(a), y = unpack(b)
        guard x.count == y.count, !x.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in x.indices {
            dot += x[i] * y[i]
            normA += x[i] * x[i]
            normB += y[i] * y[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom == 0 ? 0 : Double(dot / denom)
    }
}
