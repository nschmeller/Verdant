import Foundation
import FoundationModels
import Testing
@testable import Verdant

/// Every identifier a prompt tells the model to use must exist.
///
/// `SessionToolsTests` already pins one half of this: a prompt may only name TOOLS the role holds,
/// which it enforces because a prompt naming a tool the session lacked was a real bug here — Ask's
/// gather pass was told to use `eventWindow` it did not carry, wasting one of four permitted calls
/// on the user-facing path.
///
/// The other half went unchecked. Prompts also name SCHEMA FIELDS — `consistentAcrossThirds`,
/// `dayFilter`, `holdsUp`, `recentThirdCoefficient` — and a lens that names a field which does not
/// exist sends an investigator hunting for a number it can never find, burning a session on nothing.
/// That costs the same as the tool bug and fails the same way: no crash, no error, just less
/// reasoning per unit time, which is the one thing this app is measured in. It becomes likely the
/// moment a `@Generable` property is renamed, since nothing connects the two.
///
/// Read from the RUNTIME strings rather than the source file, so doc comments (full of Swift
/// identifiers that are not prompt text) are excluded by construction.
struct PromptIdentifierTests {
    /// Every property declared inside a `@Generable` type, plus every enum case in the app — the
    /// vocabulary of things a prompt may legitimately tell the model to read, call or request.
    ///
    /// Enum cases are in because closed vocabularies reach the model as `.anyOf(X.allRawValues)`, so
    /// a lens naming `stdDev` is naming something real. Leaving them out produced two false
    /// positives on the first run of this test — the same shape as the `\bToolPrecision\b` sweep that
    /// reported a well-tested file as untested. A check that over-reports is worse than useless: it
    /// sends you to "fix" correct code, and the next real hit gets waved through with the noise.
    ///
    /// So the collection is deliberately PERMISSIVE and generic — every enum case anywhere, not a
    /// curated list of the vocabularies that happen to be exposed today. A curated list would be one
    /// more thing to keep in sync, and forgetting it would show up as a false alarm rather than a
    /// miss. Over-permissiveness only weakens this test; it can never make it lie.
    private func knownIdentifiers() throws -> Set<String> {
        var known: Set<String> = []
        for source in try SourceScan.swiftSources() {
            var insideGenerable = false
            var depth = 0
            for line in source.text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Enum case declarations, comma-separated forms included. Lines containing a colon
                // are switch cases (`case .stdDev: "…"`), not declarations.
                if trimmed.hasPrefix("case "), !trimmed.contains(":") {
                    for token in trimmed.dropFirst(5).components(separatedBy: ",") {
                        let name = token.trimmingCharacters(in: .whitespaces)
                            .prefix { $0.isLetter || $0.isNumber }
                        if !name.isEmpty { known.insert(String(name)) }
                    }
                }
                if line.contains("@Generable") { insideGenerable = true; depth = 0 }
                guard insideGenerable else { continue }
                depth += line.count(where: { $0 == "{" }) - line.count(where: { $0 == "}" })
                if let range = line.range(of: "let ") ?? line.range(of: "var ") {
                    let name = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
                    if !name.isEmpty { known.insert(String(name)) }
                }
                if depth <= 0, line.contains("}") { insideGenerable = false }
            }
        }
        return known
    }

    /// Substrate-free: the tool objects are needed only for their names.
    private func toolNames(_ s: Subagents) -> Set<String> {
        let substrate = AnalysisSubstrate(provider: s.provider, series: [], now: Date())
        let all: [any Tool] = s.explorerTools(substrate)
            + s.scoutTools(substrate)
            + s.replicatorTools(substrate)
            + s.directorTools(now: Date())
            + s.answererTools(substrate, now: Date())
        return Set(all.map(\.name))
    }

    /// The prompt text actually sent, lenses included — a lens is prompt text the same as the
    /// system instructions, and lenses are where field names are named most.
    private func promptTexts() -> [String] {
        let focus = InvestigationFocus(metric: .stepCount, secondaryMetric: nil, title: "A finding")
        return [
            Instructions.investigator,
            Instructions.explorer,
            Instructions.scout,
            Instructions.replicator,
            Instructions.answerer,
            Instructions.director
        ]
            + Instructions.investigationLenses
            + Instructions.deepLenses(pass: 1, metrics: [.stepCount, .bodyMass])
            + Instructions.scoutAngles
            + Orchestrator.focusedLenses(focus)
            + Orchestrator.replicationLenses
    }

    private func camelCaseTokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                guard let first = token.first, first.isLowercase else { return false }
                return token.dropFirst().contains { $0.isUppercase }
            }
    }

    @Test func `the vocabulary sweep finds the schema it is checking against`() throws {
        let known = try knownIdentifiers()
        // Vacuity guard: a scan that found nothing would accept any prompt at all.
        #expect(known.count > 20, "found only \(known.count) identifiers")
        // Two canaries, one per collection path, both long-lived. Deliberately NOT the newest field:
        // pinning a name that is likely to churn makes a LEGITIMATE rename fail here, which is the
        // false alarm this test's own doc warns about.
        #expect(known.contains("holdsUp"), "@Generable properties are missing")
        #expect(known.contains("stdDev"), "enum cases are missing — the sweep will false-alarm")
    }

    @Test func `every identifier a prompt names actually exists`() throws {
        let s = try Subagents(
            provider: MetricStatsProvider(modelContainer: TestSupport.inMemoryContainer()),
            writer: StoreWriter(modelContainer: TestSupport.inMemoryContainer()),
            embeddings: Embeddings()
        )
        let vocabulary = try knownIdentifiers().union(toolNames(s))
        for text in promptTexts() {
            for token in camelCaseTokens(in: text) where !vocabulary.contains(token) {
                Issue.record(
                    "a prompt names “\(token)”, which is neither a tool nor a field of any schema"
                )
            }
        }
    }
}
