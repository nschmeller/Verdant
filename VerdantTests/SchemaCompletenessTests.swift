import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Every `@Model` in the app must appear in `SchemaV1.models`.
///
/// The two lists are written independently — one is a set of class declarations spread across the
/// persistence layer, the other a hand-maintained array — and nothing connects them. Adding a
/// seventh model and forgetting the array compiles cleanly and passes every other test in the suite,
/// because the tests build their containers from the same incomplete schema and are therefore
/// consistent with it.
///
/// On device it fails differently and worse. The container cannot open against a store whose schema
/// omits a model in use, and `VerdantApp` deliberately falls back to an IN-MEMORY container when the
/// store will not open — right for a foreground launch, where a usable session beats a refusal to
/// start. So the app would launch, work, and discard everything written: findings, the research
/// journal, the ingest anchors. `AppModel.storeIsEphemeral` catches that state and yields background
/// windows rather than burning them, so the damage is bounded — but the cause would be a missing
/// line in an array, and nothing would say so.
struct SchemaCompletenessTests {
    /// Scanned from source rather than listed here. A hand-written expectation would be a third copy
    /// of the same list, drifting alongside the two it is supposed to reconcile.
    private func declaredModels() throws -> Set<String> {
        var found: Set<String> = []
        for source in try SourceScan.swiftSources() {
            let lines = source.text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.hasPrefix("@Model") {
                // The declaration is on the same line or the next one.
                let candidates = [line, index + 1 < lines.count ? lines[index + 1] : ""]
                for candidate in candidates {
                    guard let range = candidate.range(of: "class ") else { continue }
                    let name = candidate[range.upperBound...]
                        .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty { found.insert(String(name)) }
                }
            }
        }
        return found
    }

    @Test func `the sweep finds the models it is supposed to reconcile`() throws {
        let declared = try declaredModels()
        // Vacuity guard: a scan that matched nothing would certify any schema at all.
        #expect(declared.count >= 6, "found only \(declared.count) @Model types — did the scan break?")
        #expect(declared.contains("InsightLog"))
    }

    @Test func `every persisted model is registered in the schema`() throws {
        let registered = Set(SchemaV1.models.map { String(describing: $0) })
        let declared = try declaredModels()
        let missing = declared.subtracting(registered)
        #expect(
            missing.isEmpty,
            Comment(rawValue: "declared but not in SchemaV1.models: \(missing.sorted())")
        )
    }

    /// And the reverse: a registered type that no longer exists as a model would mean the array was
    /// updated for a rename while the declaration moved on.
    @Test func `the schema registers nothing that is not a model`() throws {
        let declared = try declaredModels()
        let stale = Set(SchemaV1.models.map { String(describing: $0) }).subtracting(declared)
        #expect(stale.isEmpty, Comment(rawValue: "in SchemaV1.models but not declared: \(stale.sorted())"))
    }

    /// The container must actually open against that schema — the assertion the two above are only a
    /// proxy for.
    @Test func `a container opens against the registered schema`() throws {
        let container = try ModelContainer(
            for: Schema(SchemaV1.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        #expect(!container.schema.entities.isEmpty)
    }
}
