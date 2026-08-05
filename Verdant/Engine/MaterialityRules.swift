import Foundation

/// Turns a *trusted* statistic (already computed at source) into a surfaceable `VerifiedFact`. Worth
/// is no longer decided here — the agent decides what is worth surfacing — so this only derives the
/// deterministic descriptors (direction, magnitude, kind, salience) for a confident stat.
nonisolated enum MaterialityRules {
    static func magnitude(z: Double) -> MagnitudeBucket {
        switch abs(z) {
        case ..<1.5: .slight
        case ..<3: .moderate
        default: .large
        }
    }

    static func inferredKind(z: Double) -> InsightKind {
        abs(z) >= 4 ? .anomaly : .trend
    }

    static func salience(z: Double, pct: Double) -> Int {
        clampSalience(Int((abs(z) * 18 + abs(pct) * 0.4).rounded()))
    }

    static func clampSalience(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    /// Build a verified fact from a *trusted* statistic (already recomputed from source). Returns
    /// `nil` only when the statistic is not COMPUTABLE — too small a window, or a baseline with no
    /// spread. It used to say "when the change is not material", which had become the opposite of
    /// what the body does: materiality is an agent decision now, and the guard below says so at
    /// length. A summary line that contradicts its own implementation is worse than no summary,
    /// because it is what a reader trusts and what a future change would be measured against.
    ///
    /// - Parameters:
    ///   - requestedKind: an LLM-suggested category, sanitized (a `none`/`redFlag` request is
    ///     ignored and replaced by the inferred kind).
    ///   - requestedSalience: an LLM-suggested 0–100 salience; clamped, or computed if absent.
    static func buildFact(
        stat: MetricStat,
        requestedKind: InsightKind? = nil,
        requestedSalience: Int? = nil
    ) -> VerifiedFact? {
        // `confident` stays — it means "there is enough data to produce a trustworthy number", which is
        // about *producing the stat*, not deciding worth. Worth/materiality is NO LONGER gated here: the
        // agent decides what is worth surfacing, so buildFact yields a fact for any confident stat and
        // never silently drops the agent's choice for being "too small".
        guard stat.confident else { return nil }
        let direction = stat.direction
        let magnitude = magnitude(z: stat.z)

        // A single-metric lead may only be a trend or an anomaly; any other requested kind
        // (correlation/milestone/regimeShift/redFlag/none) is coerced to the inferred one so a lead
        // can never be persisted with a kind that routes it to another finding type's card.
        let kind: InsightKind = {
            guard let requested = requestedKind, requested == .trend || requested == .anomaly else {
                return inferredKind(z: stat.z)
            }
            return requested
        }()
        // Single-metric salience trusts the model's judgment (clamped), and deliberately does NOT
        // blend in the statistical `salience(z:pct:)` the way the correlation/volatility/etc. quality
        // scores blend their stat terms. For those, the stat term measures *trustworthiness of a
        // subtle link*; for a lone metric it measures *bigness*, which usually means *obviousness* —
        // blending it in would promote the loud, predictable changes this app exists to filter out.
        // The model's salience captures insight/non-obviousness, which is exactly what should rank.
        let salience = requestedSalience.map(clampSalience) ?? salience(z: stat.z, pct: stat.pctChange)

        return VerifiedFact(
            metric: stat.metric,
            comparison: stat.comparison,
            recent: stat.recent,
            baseline: stat.baseline,
            pctChange: stat.pctChange,
            z: stat.z,
            n: stat.n,
            kind: kind,
            direction: direction,
            magnitude: magnitude,
            salience: salience
        )
    }
}
