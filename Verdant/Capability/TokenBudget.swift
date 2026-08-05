import FoundationModels

/// Hard structural caps that make context-window overflow impossible regardless of measured token
/// counts. These are the no-measurement safety net for iOS 26.0–26.3 (where `tokenCount` is
/// unavailable); the token harness validates real numbers on 26.4+.
nonisolated enum TokenBudget {
    /// Q&A retrieval is capped hard: at most this many memories, each truncated. These bound the
    /// Answerer's context directly (enforced in `InsightSearchTool`).
    static let maxRetrievedMemories = 3
    static let maxMemoryCharacters = 120

    /// The model's real context window (`contextSize` is iOS 26.0+, back-deployed).
    static var modelContextSize: Int {
        SystemLanguageModel.default.contextSize
    }

    // `tokenCount(...)` is iOS 26.4+ and lives on `SystemLanguageModel`. Each returns nil below
    // 26.4, where there is no runtime measurement and the static caps govern.

    static func tokenCount(forText text: String) async -> Int? {
        if #available(iOS 26.4, *) {
            return try? await SystemLanguageModel.default.tokenCount(for: text)
        }
        return nil
    }

    static func tokenCount(forTools tools: [any Tool]) async -> Int? {
        if #available(iOS 26.4, *) {
            return try? await SystemLanguageModel.default.tokenCount(for: tools)
        }
        return nil
    }
}
