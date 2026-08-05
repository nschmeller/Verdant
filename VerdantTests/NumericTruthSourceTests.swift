import Foundation
import Testing
@testable import Verdant

/// One reader of the daily rollups, so no two statistics in the app can be looking at different days.
///
/// `MetricStatsProvider` calls itself "the single source of numeric truth". The version of that claim
/// worth enforcing is narrower than the one it used to make: the provider does NOT compute every
/// statistic — `RegimeShiftScan` computes Cohen's d and pooled standard deviations, `VolatilityScan`
/// coefficients of variation, `SeasonalityScan` de-trended residuals — and the doc said otherwise
/// until this suite was written.
///
/// What holds is the data. Every one of those engines reads its series through this actor, so the
/// figures behind two findings can disagree about interpretation but never about which days
/// happened. Break that — a second `FetchDescriptor<MetricRollup>` somewhere convenient, reading
/// with its own predicate or its own calendar — and two numbers shown side by side on one screen
/// could rest on different data, with nothing in the UI able to tell.
///
/// The rollup key is a UTC day boundary (`Calendar.civil`), which is exactly the kind of detail a
/// second reader gets subtly wrong: `CivilCalendar`'s own doc warns that a local-time bucket splits
/// one physical day across two rows "which the stats then double-count (a wrong number behind every
/// finding for that metric)".
struct NumericTruthSourceTests {
    /// Writing is the store's job; reading for analysis is the provider's.
    private let allowed = ["MetricStatsProvider.swift", "StoreWriter.swift"]

    /// The QUERY, not the type name. Scanning for `MetricRollup` alone flags `Models.swift` and
    /// `SchemaV1.swift`, which declare the model and never read a row — an allowlist that would grow
    /// with every schema version and eventually be padded until it stopped catching anything.
    private let read = "FetchDescriptor<MetricRollup>"

    @Test func `only the provider reads the daily rollups`() throws {
        let readers = try SourceScan.swiftSources()
            .filter { SourceScan.code($0.text).contains(read) }
            .map(\.path)
            .filter { !allowed.contains($0) }
            .sorted()
        #expect(
            readers.isEmpty,
            Comment(rawValue: "MetricRollup is read outside the single source: \(readers)")
        )
    }

    /// Non-vacuity: the scan finds the readers it allows, or an empty result above means nothing.
    /// Comments are stripped by `SourceScan.code` too, since four files MENTION `MetricRollup` in
    /// prose only and a scan over raw text would report them as offenders.
    @Test func `the scan sees the readers it permits`() throws {
        let found = try SourceScan.swiftSources()
            .filter { SourceScan.code($0.text).contains(read) }
            .map(\.path)
            .sorted()
        for path in allowed {
            #expect(found.contains(path), Comment(rawValue: "\(path) no longer reads rollups: \(found)"))
        }
    }

    /// And the engines really do take their series from the provider rather than fetching their own
    /// — the reason the rule above is worth having. `AnalysisSubstrate` is the one carrier.
    @Test func `the substrate is built from the provider's series`() throws {
        let source = try #require(
            try SourceScan.swiftSources().first { $0.path == "AnalysisSubstrate.swift" }
        )
        let code = SourceScan.code(source.text)
        #expect(code.contains("provider"), "the substrate no longer holds the provider")
        #expect(!code.contains("MetricRollup"), "the substrate started fetching rollups itself")
    }
}
