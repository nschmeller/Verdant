import Foundation
import Testing
@testable import Verdant

/// Every closed vocabulary the model is allowed to emit is declared twice by nature: once as the
/// Swift type the code switches on, and once as the `.anyOf` list in the guided-generation schema.
/// When those two are the same expression, they cannot disagree. When the schema list is typed out
/// by hand, nothing but proofreading keeps them together — and the failure is silent in the worst
/// way: no crash, no wrong number, just a capability the model can never reach or a value the code
/// never expects.
///
/// Three lists were hand-written. All three are now derived, and this suite pins that they stay
/// derived and stay in agreement.
struct ClosedVocabularyTests {
    /// The director's strategy vocabulary. The deep-run loop switches exhaustively over
    /// `PassStrategy`, so a schema that offered a fourth strategy would route it to the fallback and
    /// look, from the outside, like a director that kept changing its mind for no reason.
    @Test func `every strategy the schema offers is one the loop handles`() {
        for raw in Orchestrator.PassStrategy.allRawValues {
            #expect(Orchestrator.PassStrategy(rawValue: raw) != nil, "schema offers unknown \(raw)")
        }
        #expect(Orchestrator.PassStrategy.allRawValues == ["breadth", "drill", "frontier"])
    }

    /// The journal vocabulary. `researchJournal` returns nothing for a kind it cannot parse, so a
    /// missing entry here does not fail — the director simply cannot see that history at all.
    @Test func `every journal kind is reachable through the director's tool`() {
        for kind in ResearchJournalKind.allCases {
            #expect(ResearchJournalKind.allRawValues.contains(kind.rawValue), "\(kind) unreachable")
        }
        #expect(ResearchJournalKind.allRawValues.contains("barren"))
    }

    /// The pattern vocabulary, which is the one that can disagree in BOTH directions: the schema
    /// tells the model which kinds exist, and `patternScan` separately constructs the `kind` string
    /// it actually returns.
    @Test func `patternScan only ever emits kinds its own schema declares`() async throws {
        let calendar = Calendar.civil
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 17)))
        let anchor = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        )
        // Varied enough that all three detectors have something to say.
        let series = [MetricKey.bodyMass, .restingHeartRate, .stepCount].enumerated().map { i, metric in
            var values: [Date: Double] = [:]
            for ago in 0..<200 {
                let base = ago < 40 ? 120.0 + Double(i) * 9 : 60.0 + Double(i) * 4
                values[calendar.date(byAdding: .day, value: -ago, to: anchor)!] =
                    base + Double((ago * (i + 3)) % 13)
            }
            return DailySeries(metric: metric, values: values)
        }
        let substrate = try AnalysisSubstrate(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            series: series, now: now
        )
        let result = try await PatternScanTool(substrate: substrate).call(arguments: .init(perKind: 3))
        #expect(!result.patterns.isEmpty, "fixture produced no patterns — the check would be vacuous")
        for pattern in result.patterns {
            #expect(
                PatternKind(rawValue: pattern.kind) != nil,
                "emitted “\(pattern.kind)”, which its schema does not declare"
            )
        }
    }

    /// Prompts name pattern KINDS, not just tool names: the lenses say "patternScan regime",
    /// "patternScan volatility", "patternScan seasonal". That is the same drift as naming a tool a
    /// session lacks — an agent told to look for a kind the tool never emits spends a call finding
    /// nothing — and it is a class that only appeared once `seasonal` was added, so it is worth
    /// closing now rather than after it bites.
    @Test func `every pattern kind named in a prompt is one patternScan emits`() {
        let prompts = ([Instructions.investigator, Instructions.explorer, Instructions.scout]
            + Instructions.investigationLenses
            + Instructions.scoutAngles
            + Instructions.deepLenses(pass: 1, metrics: [.stepCount])).joined(separator: "\n")
        var named: [String] = []
        for line in prompts.split(separator: "\n") {
            var rest = line[...]
            while let hit = rest.range(of: "patternScan ") {
                let after = rest[hit.upperBound...]
                let word = after.prefix { $0.isLetter }
                if !word.isEmpty { named.append(String(word)) }
                rest = after
            }
        }
        // Non-vacuous: the prompts really do name kinds, so an empty scan cannot pass silently.
        #expect(named.count >= 3, "found only \(named.count) patternScan references")
        for word in named {
            #expect(
                PatternKind(rawValue: word) != nil,
                "a prompt says “patternScan \(word)”, which patternScan never emits"
            )
        }
    }

    /// The structural half: a vocabulary written as a literal in a guide is the drift itself, so the
    /// rule is that `.anyOf` always names a Swift type's values. This is what stops the three fixes
    /// above from being quietly undone by the next hand-typed list.
    @Test func `no guided-generation vocabulary is a hand-written string literal`() throws {
        var offenders: [String] = []
        for file in try SourceScan.swiftSources() {
            for line in file.text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let range = line.range(of: ".anyOf(") else { continue }
                // A literal list starts with a quote right after the opening bracket.
                let tail = line[range.upperBound...].drop { $0 == "[" }
                guard tail.first == "\"" else { continue }
                offenders.append("\(file.path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, "hand-written .anyOf vocabularies:\n\(report)")
    }
}
