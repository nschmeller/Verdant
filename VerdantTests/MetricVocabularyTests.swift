import Foundation
import FoundationModels
import Testing
@testable import Verdant

/// A role that must name a metric must be able to SPELL one.
///
/// Five runs of the replication panel against the real model completed zero re-tests. Every failure
/// was the same, in the analysts' own words: `res`, `restingHear`, `resting_heart_rate`,
/// `Heart rate`. Not one is a guess at a different metric — they are truncations, a snake_case
/// spelling, and a display name of the very metric the analyst was asked to re-test. All three tools
/// the panel held took a free-generated `metric: String`, so there was no path to a key it could not
/// mangle, and each failure surfaced as the honest, useless "could not run this check."
///
/// Three prompt-level fixes were tried before the cause was found — naming the exact keys in the
/// lens, listing the available metrics, naming the near miss in the tool's error reply. None moved
/// it, and none could have: prompt text does not constrain generation. A closed vocabulary in the
/// SCHEMA does, because the anchored list is what the decoder samples against.
///
/// The invariant is therefore structural, not verbal. A metric argument is safe if EITHER it carries
/// the anchored list, OR its own description names an all-metrics value that always works — an agent
/// that cannot spell `restingHeartRate` can still ask for "all" and get an answer. An argument with
/// neither is a dead end reachable by one truncation, and a role holding one must carry the
/// vocabulary somewhere in its session, so the correct spellings are in front of the model.
///
/// This is the check that would have caught it the day `metricStats` was left out of the replicator,
/// instead of five model runs later.
struct MetricVocabularyTests {
    private struct Role {
        let name: String
        let tools: [any Tool]
    }

    private func subagents() throws -> Subagents {
        try Subagents(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            writer: StoreWriter(modelContainer: TestSupport.inMemoryContainer()),
            embeddings: Embeddings()
        )
    }

    private func roles(_ s: Subagents) -> [Role] {
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        return [
            Role(name: "investigator", tools: s.investigatorTools(substrate)),
            Role(name: "explorer", tools: s.explorerTools(substrate)),
            Role(name: "scout", tools: s.scoutTools(substrate)),
            Role(name: "replicator", tools: s.replicatorTools(substrate)),
            Role(name: "answerer", tools: s.answererTools(substrate, now: Date())),
            Role(name: "director", tools: s.directorTools(now: Date()))
        ]
    }

    /// Read from the encoded `GenerationSchema` — what the model is actually handed — so a `.anyOf`
    /// written in source but not reaching the model cannot pass this.
    private func properties(_ tool: any Tool) throws -> [String: [String: Any]] {
        let data = try JSONEncoder().encode(tool.parameters)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return root?["properties"] as? [String: [String: Any]] ?? [:]
    }

    /// Metric arguments with no anchored list and no all-metrics escape: the shape that failed.
    private func unanchoredMetricArguments(_ tools: [any Tool]) throws -> [String] {
        var found: [String] = []
        for tool in tools {
            for (name, schema) in try properties(tool) where name.lowercased().contains("metric") {
                guard schema["type"] as? String == "string" else { continue }
                if schema["enum"] != nil { continue }
                let description = (schema["description"] as? String ?? "").lowercased()
                // Both forms in the app today: "or empty for all metrics", "or \"all\" for every
                // metric". Either tells the model a value that cannot be misspelled into nothing.
                if description.contains("for all metrics") || description.contains("for every metric") {
                    continue
                }
                found.append("\(tool.name).\(name)")
            }
        }
        return found
    }

    private func carriesVocabulary(_ tools: [any Tool]) throws -> Bool {
        for tool in tools {
            for (_, schema) in try properties(tool) {
                guard let values = schema["enum"] as? [String] else { continue }
                if values.contains(MetricKey.restingHeartRate.rawValue) { return true }
            }
        }
        return false
    }

    @Test func `every role that must name a metric can spell one`() throws {
        let s = try subagents()
        for role in roles(s) {
            let exposed = try unanchoredMetricArguments(role.tools)
            guard !exposed.isEmpty else { continue }
            #expect(
                try carriesVocabulary(role.tools),
                Comment(
                    rawValue: """
                    the \(role.name) must free-generate a metric key for \
                    \(exposed.joined(separator: ", ")) and no tool in its session carries the \
                    anchored vocabulary — one truncation and the call returns nothing
                    """
                )
            )
        }
    }

    /// Non-vacuity, and the exact regression that caused this: the replicator DOES hold unanchored
    /// metric arguments, and its only anchor is `metricStats`. Drop that one tool and the panel is
    /// back to spelling from memory — while the sweep above still passes for every other role, which
    /// is why it needs saying here. The next person to trim this surface for tokens should read what
    /// the tokens buy.
    @Test func `the replicator would fail this check without its anchored tool`() throws {
        let s = try subagents()
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let all = s.replicatorTools(substrate)
        #expect(try !unanchoredMetricArguments(all).isEmpty, "nothing left for the anchor to protect")
        #expect(try carriesVocabulary(all))
        #expect(try !carriesVocabulary(all.filter { $0.name != "metricStats" }))
    }

    /// The scout is the role this check deliberately does NOT fail, so the reasoning is pinned rather
    /// than left to whoever reads the pass. Its one metric argument is `unusualDays`, whose
    /// description offers "all"; every other scout tool is a sweep that names no metric at all. A
    /// mangled key there costs one tool call, not the role's purpose — unlike the replicator, where
    /// naming the key correctly WAS the purpose.
    ///
    /// The cheap fix for even that would be `.anyOf` on `unusualDays.metric`, which is blocked: the
    /// investigator holds the same tool at 2,036 of 2,048 tokens. So this is a recorded exposure with
    /// a known price, not an oversight — and if the scout ever gains a tool that requires a real key,
    /// the sweep above starts failing.
    @Test func `the scout is exempt because it always has a way to ask for everything`() throws {
        let s = try subagents()
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let tools = s.scoutTools(substrate)
        #expect(try unanchoredMetricArguments(tools).isEmpty)
        #expect(try !carriesVocabulary(tools), "the scout now anchors the vocabulary; drop this test")
        // The exemption rests entirely on that description, so pin the escape hatch itself.
        let unusual = try #require(tools.first { $0.name == "unusualDays" })
        let metric = try #require(properties(unusual)["metric"]?["description"] as? String)
        #expect(metric.contains("all"))
    }
}
