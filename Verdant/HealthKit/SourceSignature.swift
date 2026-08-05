import Foundation
import HealthKit

/// Turns the set of HealthKit sources that produced a day's number into one comparable string.
///
/// Everything downstream asks a single question of provenance — "is today recorded the same way
/// yesterday was?" — so the representation only has to make that comparison correct. Two properties
/// carry the weight:
///
/// - **Order-independence.** HealthKit hands back sources in no guaranteed order, so `[Watch, iPhone]`
///   and `[iPhone, Watch]` are the same setup and must produce the same signature. Sorted, or every
///   other day looks like a device change.
/// - **Set semantics.** Duplicates are dropped: an interval metric sees one sample per sleep stage,
///   hundreds a night, all from the same watch. What matters is which sources appeared, not how
///   many samples each contributed.
///
/// The separator is a character that cannot occur in the parts, so a signature can be split back
/// apart for display without ambiguity.
nonisolated enum SourceSignature {
    /// Never appears in an `HKSource.name` — those are app/device display names.
    static let separator = "\u{1F}"

    /// Sorted, de-duplicated, blank-free. The canonical form of a day's source list.
    static func canonical(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out.sorted()
    }

    /// The canonical names behind an `HKStatistics.sources`, which is nil unless the query asked
    /// for `.separateBySource`.
    static func names(of sources: [HKSource]?) -> [String] {
        canonical((sources ?? []).map(\.name))
    }

    /// The stored form: one string per rollup row, empty when provenance is unknown.
    static func joined(_ names: [String]) -> String {
        canonical(names).joined(separator: separator)
    }

    /// Inverse of `joined`. An empty string means unknown — NOT "recorded by nobody" — which is why
    /// it maps to an empty list that `ProvenanceScan` skips rather than treats as a change.
    static func split(_ signature: String) -> [String] {
        signature.isEmpty ? [] : signature.components(separatedBy: separator)
    }

    /// How a signature reads to an agent or a person: "Apple Watch + iPhone".
    static func describe(_ names: [String]) -> String {
        names.isEmpty ? "unknown" : names.joined(separator: " + ")
    }
}
