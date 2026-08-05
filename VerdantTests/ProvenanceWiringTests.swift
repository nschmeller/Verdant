import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The chain, end to end: HealthKit hands over which sources wrote a day → the ingestor stores it →
/// the provider reads it back → the substrate scans it → the regime shift built on those very days
/// carries the caveat → the agent reads it in the `patternScan` row it was already going to read.
///
/// Every link is a place the feature can be perfectly implemented and completely inert. `scan` takes
/// `sourceChanges` with a default of `[]`, so a substrate that never passes it compiles, runs, and
/// reports every regime shift with no caveat at all — the exact "defaulted argument plus a
/// hand-supplied unit test" shape that has produced dead features in this codebase before. Each
/// piece has its own test in `ProvenanceTests`; only this one proves they are connected.
struct ProvenanceWiringTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    private func day(_ ago: Int) -> Date {
        calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now))!
    }

    /// A Health store that reports, per day, both a value and who recorded it — exactly the shape
    /// `HealthStore` now produces via `.separateBySource`.
    private final class FakeHealth: HealthReading, @unchecked Sendable {
        var days: [Date: (value: Double, sources: [String])] = [:]

        func anchoredScan(for _: MetricKey, anchor _: Data?) async throws -> AnchoredScan {
            AnchoredScan(
                newAnchor: Data([1]), affectedDays: [], hadDeletions: false, addedCount: days.count
            )
        }

        func dailyValues(for _: MetricKey, dayStart: Date) async throws -> DayValues? {
            guard let entry = days[dayStart] else { return nil }
            return DayValues(mean: entry.value, sum: entry.value, count: 1, sources: entry.sources)
        }

        func dailyValuesRange(
            for metric: MetricKey, from start: Date, to end: Date
        ) async throws -> [DayRollup] {
            days.filter { $0.key >= start && $0.key < end }
                .sorted { $0.key < $1.key }
                .map { DayRollup(
                    metric: metric, dayStart: $0.key,
                    values: DayValues(
                        mean: $0.value.value, sum: $0.value.value, count: 1,
                        sources: $0.value.sources
                    )
                ) }
        }

        func earliestSampleDate(for _: MetricKey) async throws -> Date? {
            days.keys.min()
        }
    }

    /// 140 days of resting heart rate that steps down 4 bpm 60 days ago — and changes watch on the
    /// very same day. A real regime shift, and an artifact, indistinguishable in the numbers.
    private func swapFixture() -> FakeHealth {
        let health = FakeHealth()
        for ago in 0..<140 {
            let recent = ago < 60
            health.days[day(ago)] = (
                value: (recent ? 56.0 : 60.0) + Double(ago % 3),
                sources: [recent ? "Apple Watch Series 11" : "Apple Watch Series 8"]
            )
        }
        return health
    }

    /// A new scale, 6 days ago: 133 days at ~80 kg from the old one, then a strict step to ~82.
    ///
    /// EXACTLY the last seven days, and a step rather than the swap fixture's: milestone means are
    /// rolling 7-day windows, so an eight-day change makes the final window TIE the one before it
    /// and `latest > maxPrior` is false — a record that is not strictly a record. The swap fixture
    /// steps DOWN across 60 days and sets no record at all, which is what sent this test looking.
    private func newScaleFixture() -> FakeHealth {
        let health = FakeHealth()
        for ago in 0..<140 {
            let isNew = ago < 7
            health.days[day(ago)] = (
                value: (isNew ? 82.0 : 80.0) + Double(ago % 3) * 0.1,
                sources: [isNew ? "New Scale" : "Old Scale"]
            )
        }
        return health
    }

    private func substrate(
        _ health: FakeHealth, _ container: ModelContainer, metric: MetricKey = .restingHeartRate
    ) async throws -> AnalysisSubstrate {
        let writer = StoreWriter(modelContainer: container)
        _ = try await Ingestor(healthStore: health, writer: writer)
            .ingest(metric: metric, now: now)
        let provider = MetricStatsProvider(modelContainer: container)
        return try await AnalysisSubstrate(
            provider: provider, series: provider.dailySeries(now: now), now: now
        )
    }

    /// The ingest actually stores who recorded each day. Without this the rest cannot work, and
    /// nothing else in the suite would say why.
    @Test func `the ingest stores which sources recorded each day`() async throws {
        let container = try TestSupport.inMemoryContainer()
        _ = try await substrate(swapFixture(), container)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<MetricRollup>())
        #expect(!rows.isEmpty)
        let signatures = Set(rows.map(\.sourceSignature))
        #expect(!signatures.contains(""), "a day was stored with no provenance")
        #expect(signatures.count == 2, "expected two recording setups, got \(signatures.count)")
    }

    /// And the scan sees the transition through the provider, not through a hand-built fixture.
    @Test func `the substrate finds the change of watch`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let changes = try await substrate(swapFixture(), container).provenance()

        let change = try #require(changes.first, "no source change reached the substrate")
        #expect(changes.count == 1)
        #expect(change.metric == .restingHeartRate)
        #expect(change.before == ["Apple Watch Series 8"])
        #expect(change.after == ["Apple Watch Series 11"])
    }

    /// THE test. The regime shift is real and correctly detected; the caveat that it may be the
    /// watch rather than the heart has to travel with it, in the line the investigator reads.
    @Test func `the regime shift's basis says the recording device changed`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let regimes = try await substrate(swapFixture(), container).regimes()

        let shift = try #require(regimes.first, "the fixture produced no regime shift to caveat")
        #expect(shift.metric == .restingHeartRate)
        let note = try #require(shift.sourceChangeNote, "the shift carries no provenance caveat")
        #expect(note.contains("Apple Watch Series 8"))
        #expect(note.contains("Apple Watch Series 11"))
        #expect(note.contains("0 days from this step"), "the caveat mis-stated the timing: \(note)")
        // The line the agent is actually shown — the caveat is worthless if it stops at the struct.
        #expect(shift.verifiedBasis.contains("what RECORDS this metric changed"))
    }

    /// The other half of the claim: an equally real shift with NO device change must not be
    /// caveated. A note on every finding is the same as a note on none.
    @Test func `a shift with no change of source carries no caveat`() async throws {
        let health = FakeHealth()
        for ago in 0..<140 {
            health.days[day(ago)] = (
                value: (ago < 60 ? 56.0 : 60.0) + Double(ago % 3), sources: ["Apple Watch Series 8"]
            )
        }
        let container = try TestSupport.inMemoryContainer()
        let regimes = try await substrate(health, container).regimes()

        let shift = try #require(regimes.first)
        #expect(shift.sourceChangeNote == nil, "an unchanged setup was reported as a device change")
        #expect(!shift.verifiedBasis.contains("what RECORDS"))
    }

    /// Why this exists at all, given the app already flags suspected device swaps.
    ///
    /// `suspectedDeviceSwap` INFERS a device change from several Watch vitals stepping within days
    /// of each other. That inference is sound and stays — it catches a firmware recalibration that
    /// leaves the source name unchanged, which provenance cannot see. But it is structurally blind
    /// to a change affecting ONE metric, and the most common real device swaps are exactly that: a
    /// new scale moves body weight and nothing else, a new phone moves step count and nothing else.
    /// The fixture has a single metric because that IS the case in question.
    @Test func `provenance catches a swap the co-jump heuristic structurally cannot`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let shift = try #require(await substrate(swapFixture(), container).regimes().first)

        #expect(!shift.suspectedDeviceSwap, "the fixture no longer isolates the gap being tested")
        #expect(shift.sourceChangeNote != nil, "the only evidence of the swap was lost")
    }

    /// The regime shift is not the only claim a device swap fakes, and annotating only that one
    /// would have left the other two exposed while looking finished.
    ///
    /// A new scale reading two pounds heavy produces a RECORD — "your highest 7-day weight ever" —
    /// which is the most alarming of the three to get wrong. A device that samples differently
    /// produces a genuinely different spread, so "your readings grew more erratic" becomes a
    /// statement about the sensor. Both are detected correctly and both are about equipment.
    @Test func `a record and a volatility shift carry the caveat too`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let built = try await substrate(newScaleFixture(), container, metric: .bodyMass)

        let milestone = try #require(await built.milestones().first, "fixture set no record")
        let note = try #require(milestone.sourceChangeNote, "the record carries no caveat")
        #expect(note.contains("New Scale"))
        #expect(milestone.verifiedBasis.contains("Caveat:"), "the caveat never reached the basis")

        let volatility = try #require(await built.volatility().first, "fixture set no volatility shift")
        #expect(volatility.sourceChangeNote != nil, "the volatility shift carries no caveat")
        #expect(volatility.verifiedBasis.contains("Caveat:"))
    }

    /// And the tool the replication analyst calls reports the same change, ranked and dated.
    @Test func `the provenance tool reports the change to the agent`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let tool = try await ProvenanceTool(substrate: substrate(swapFixture(), container))

        let result = try await tool.call(arguments: .init(metric: "restingHeartRate", limit: 8))

        let row = try #require(result.changes.first, "the tool reported no change")
        #expect(row.metric == "restingHeartRate")
        #expect(row.daysAgo == 59, "mis-dated the change at \(row.daysAgo) days ago")
        #expect(row.after == "Apple Watch Series 11")
        // 59, not the fixture's 60: the substrate excludes today's still-accumulating partial day,
        // so the newest stored day is yesterday. Provenance counts the days it can actually see.
        #expect(row.daysAfter == 59)
        #expect(result.withheld == 0)
    }

    /// An unrecognised metric string must not read as "this metric never changed hands" — a
    /// stronger claim than the truth, made to the agent that asked precisely because it suspected
    /// otherwise.
    @Test func `an unknown metric name falls back to every change, not to silence`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let tool = try await ProvenanceTool(substrate: substrate(swapFixture(), container))

        let result = try await tool.call(arguments: .init(metric: "heart_rate_resting", limit: 8))

        #expect(!result.changes.isEmpty, "a typo silently denied the agent the evidence")
    }
}
