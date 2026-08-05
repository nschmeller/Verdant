// Bounded-concurrency helpers used by the enhancement phase to issue many subagents at once
// without unbounded fan-out. Generic and side-effect-free, so they live outside the Orchestrator.

/// Run `transform` over `items` with at most `maxConcurrent` tasks in flight, returning all results
/// (order not guaranteed).
nonisolated func concurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    maxConcurrent: Int,
    _ transform: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    guard !items.isEmpty else { return [] }
    let limit = max(1, maxConcurrent)
    return await withTaskGroup(of: Output.self) { group in
        var index = 0
        while index < limit, index < items.count {
            let item = items[index]
            group.addTask { await transform(item) }
            index += 1
        }
        var output: [Output] = []
        while let result = await group.next() {
            output.append(result)
            if index < items.count {
                let item = items[index]
                group.addTask { await transform(item) }
                index += 1
            }
        }
        return output
    }
}
