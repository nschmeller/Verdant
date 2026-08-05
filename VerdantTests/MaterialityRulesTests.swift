import Testing
@testable import Verdant

struct MaterialityRulesTests {
    private func stat(
        _ metric: MetricKey,
        recent: Double,
        baseline: Double,
        z: Double,
        confident: Bool = true
    ) -> MetricStat {
        let pct = baseline == 0 ? 0 : (recent - baseline) / baseline * 100
        return MetricStat(
            metric: metric, comparison: .recentVsBaseline,
            recent: recent, baseline: baseline, pctChange: pct, z: z,
            baselineSD: 1, recentCount: 7, baselineCount: 30, confident: confident
        )
    }

    @Test func `non confident stat produces no fact`() {
        let s = stat(.stepCount, recent: 12000, baseline: 8000, z: 6, confident: false)
        #expect(MaterialityRules.buildFact(stat: s) == nil)
    }

    @Test func `materiality is no longer a gate — a confident stat always yields a fact`() {
        // Worth is now an agent decision, not a deterministic threshold. buildFact yields a fact for any
        // confident stat (even a small change); it never silently drops the agent's choice as "immaterial".
        let s = stat(.stepCount, recent: 8100, baseline: 8000, z: 0.4)
        #expect(MaterialityRules.buildFact(stat: s) != nil)
    }

    @Test func `material change produces upward fact`() throws {
        let s = stat(.stepCount, recent: 12000, baseline: 8000, z: 6)
        let fact = try #require(MaterialityRules.buildFact(stat: s))
        #expect(fact.direction == .up)
        #expect(fact.magnitude == .large)
        #expect(fact.salience > 0)
    }

    @Test func `clinically extreme value is no longer escalated as a finding`() throws {
        // The app produces no deterministic clinical findings: a high resting heart rate is treated
        // as an ordinary material change, never a special clinical escalation.
        let s = stat(.restingHeartRate, recent: 110, baseline: 70, z: 6)
        let fact = try #require(MaterialityRules.buildFact(stat: s))
        #expect(fact.kind != .redFlag)
    }

    @Test func `magnitude buckets`() {
        #expect(MaterialityRules.magnitude(z: 0.5) == .slight)
        #expect(MaterialityRules.magnitude(z: 2) == .moderate)
        #expect(MaterialityRules.magnitude(z: 5) == .large)
    }

    @Test func `a single-metric fact can only be a trend or anomaly, never another card's kind`() {
        // A model that mislabels an ordinary lead as a milestone/correlation/etc. must not route it to
        // another finding type's card — the detail view would then show that card's interpretation text
        // (e.g. "this marks a record stretch") for what is really a plain trend. Such kinds are coerced.
        let s = stat(.stepCount, recent: 12000, baseline: 8000, z: 6) // material; inferredKind(z:6) = anomaly
        for invalid in [
            InsightKind.milestone,
            .correlation,
            .regimeShift,
            .volatility,
            .redFlag,
            InsightKind.none
        ] {
            #expect(MaterialityRules.buildFact(stat: s, requestedKind: invalid)?.kind == .anomaly)
        }
        // A valid request is honored even when it differs from the inferred kind (here anomaly).
        #expect(MaterialityRules.buildFact(stat: s, requestedKind: .trend)?.kind == .trend)
    }

    @Test func `inferred kind splits trend from anomaly at the z threshold`() {
        // Below |z| 4 a material change reads as a trend; at/above it, an anomaly. (50% step jumps, so
        // both clear the effect floor; z carries the distinction.)
        #expect(MaterialityRules.buildFact(stat: stat(.stepCount, recent: 12000, baseline: 8000, z: 3))?
            .kind == .trend)
        #expect(MaterialityRules.buildFact(stat: stat(.stepCount, recent: 12000, baseline: 8000, z: 4))?
            .kind == .anomaly)
    }
}
