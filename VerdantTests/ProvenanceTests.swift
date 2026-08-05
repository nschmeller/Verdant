import Foundation
import SwiftData
import Testing
@testable import Verdant

/// Provenance: whether a metric changed hands between recording devices, and whether that fact
/// reaches the agent judging a finding built on it.
///
/// The defect this answers is not a crash and not a wrong number. Buy a new Apple Watch and resting
/// heart rate steps a few bpm and stays there. Replace a scale and body weight reads two pounds
/// heavy forever. `RegimeShiftScan` detects those correctly — the level really did move, the
/// statistics are sound, a replication analyst re-computing them agrees, because re-computing the
/// same rollups reproduces the shift faithfully every time. Every safeguard in the app passes, and
/// the user is told their body changed when their equipment did.
///
/// Nothing in the numbers can distinguish the two. Only the record of who wrote them can.
struct ProvenanceTests {
    private let calendar = Calendar.civil

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
    }

    private func day(_ ago: Int) -> Date {
        calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now))!
    }

    // MARK: - The signature

    /// HealthKit returns sources in no guaranteed order, so the same two devices must not read as a
    /// change every time the order flips — which would bury every real transition in noise.
    @Test func `a source signature is order-independent and de-duplicated`() {
        #expect(
            SourceSignature.joined(["Apple Watch", "iPhone"])
                == SourceSignature.joined(["iPhone", "Apple Watch"])
        )
        #expect(SourceSignature.canonical(["iPhone", "iPhone"]) == ["iPhone"])
        #expect(SourceSignature.canonical(["  ", "iPhone", ""]) == ["iPhone"])
    }

    /// Round-trip, because the stored form is what every comparison runs on.
    @Test func `a signature survives storage and comes back apart`() {
        let names = ["Apple Watch", "Withings"]
        #expect(SourceSignature.split(SourceSignature.joined(names)) == names)
        #expect(SourceSignature.split("") == [], "unknown provenance read as a named source")
    }

    // MARK: - The scan

    @Test func `a change of recording source is found, with the run each side`() {
        let signatures = Dictionary(uniqueKeysWithValues: (0..<10).map { ago in
            (day(ago), SourceSignature.joined(ago < 4 ? ["Apple Watch"] : ["iPhone"]))
        })
        let changes = ProvenanceScan.changes(
            in: SourceHistory(metric: .stepCount, signatures: signatures)
        )
        let change = try? #require(changes.first)
        #expect(changes.count == 1, "\(changes.count) changes for one transition")
        #expect(change?.before == ["iPhone"])
        #expect(change?.after == ["Apple Watch"])
        // Days 9...4 are the iPhone (6), days 3...0 the Watch (4).
        #expect(change?.daysBefore == 6)
        #expect(change?.daysAfter == 4)
        #expect(change?.day == day(3), "the change is dated to the first day recorded the new way")
    }

    @Test func `a metric recorded the same way throughout reports no change`() {
        let signatures = Dictionary(uniqueKeysWithValues: (0..<30).map {
            (day($0), SourceSignature.joined(["Apple Watch"]))
        })
        #expect(ProvenanceScan.changes(
            in: SourceHistory(metric: .stepCount, signatures: signatures)
        ).isEmpty)
    }

    /// Days ingested before provenance was recorded carry an empty signature. Treating unknown as a
    /// distinct source would manufacture two changes at the edges of every such stretch — for every
    /// existing user, on nothing but our own upgrade, and pointed at findings that are fine.
    @Test func `days with unknown provenance are not a change`() {
        var signatures: [Date: String] = [:]
        for ago in 0..<10 {
            signatures[day(ago)] = ago >= 5 ? "" : SourceSignature.joined(["Apple Watch"])
        }
        #expect(ProvenanceScan.changes(
            in: SourceHistory(metric: .stepCount, signatures: signatures)
        ).isEmpty, "an unrecorded stretch was reported as a device change")
    }

    /// A watch left on the charger for one night is a real transition in the record and a
    /// meaningless one here. It is reported — suppressing it is the agent's call, not the scan's —
    /// but its run lengths say plainly what it is.
    @Test func `a one-day blip is reported with the run lengths that give it away`() {
        var signatures: [Date: String] = [:]
        for ago in 0..<20 {
            signatures[day(ago)] = SourceSignature.joined(ago == 10 ? ["iPhone"] : ["Apple Watch"])
        }
        let changes = ProvenanceScan.changes(
            in: SourceHistory(metric: .stepCount, signatures: signatures)
        )
        #expect(changes.count == 2, "a there-and-back blip is two transitions")
        #expect(changes.allSatisfy { $0.establishedDays == 1 }, "a blip looked well-established")
    }
}
