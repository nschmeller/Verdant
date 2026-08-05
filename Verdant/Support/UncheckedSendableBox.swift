/// Bridges a non-`Sendable` value across an isolation boundary. Use only where the value is
/// provably accessed safely — e.g. a legacy completion handler invoked exactly once. Prefer real
/// `Sendable` types everywhere else.
nonisolated struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}
