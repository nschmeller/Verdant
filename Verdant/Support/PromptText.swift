import Foundation

/// Truncation for text a MODEL will read.
///
/// Every prompt in this app is assembled from clamped strings — model-written titles, hypotheses,
/// objections, lens text — because they ride in a 4,096-token window and none of them is bounded at
/// the source (a `@Guide` constrains generation, not what reaches the function). The clamping is
/// right. Doing it with a bare `prefix(n)` is what this fixes.
///
/// Measured on a real rejection, `prefix(90)` produced:
///
///     “This is a trivial observation that could be made by anyone looking at their Apple Health
///
/// — cut mid-phrase, closing quote lost. That is prompt INPUT: `journalSteering` composes it into
/// the research director's state. Text that stops mid-word reads as corruption to the thing meant
/// to learn from it, which is a different failure from text that is merely short.
///
/// Cutting on a word and marking the cut usually costs nothing: the partial word removed is longer
/// than the ellipsis added, so a clamped string is typically SHORTER than the plain prefix — which
/// matters, because several of these budgets are within a few characters of their bound.
nonisolated enum PromptText {
    /// `text` cut to at most `limit` characters, on a word boundary, marked with an ellipsis.
    ///
    /// The result is never longer than `limit` — the ellipsis is paid for out of the budget, not
    /// added on top. Written the other way first, it returned `prefix(limit) + "…"` for a run with no
    /// whitespace, i.e. `limit + 1`, and an existing test caught it immediately. A bound a
    /// pathological input can exceed is not a bound, which this type's own doc had claimed while
    /// exceeding it.
    static func clamped(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 0 else { return text }
        let head = text.prefix(limit - 1)
        guard let lastSpace = head.lastIndex(where: \.isWhitespace) else { return String(head) + "…" }
        return String(head[..<lastSpace]) + "…"
    }
}
