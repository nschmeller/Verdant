import Foundation
import Testing
@testable import Verdant

/// The discovery loop's deterministic pieces: the coverage sweep (the map of what data exists),
/// the scout lens rotation, the lead → lens mapping, and the run ledger's rings.
struct CoverageScanTests {
    private let calendar = Calendar.civil

    private func day(_ daysAgo: Int, now: Date) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    }

    private func series(_ metric: MetricKey, daysAgo: [Int], now: Date) -> DailySeries {
        DailySeries(
            metric: metric,
            values: Dictionary(uniqueKeysWithValues: daysAgo.map { (day($0, now: now), 100.0) })
        )
    }

    @Test func `contiguous history has zero gap and full density`() throws {
        let now = Date()
        let coverage = CoverageScan.scan(
            series: [series(.stepCount, daysAgo: Array(1...30), now: now)], now: now
        )
        let steps = try #require(coverage.first)
        #expect(steps.observedDays == 30)
        #expect(steps.spanDays == 30)
        #expect(steps.largestGapDays == 0)
        #expect(steps.firstDaysAgo == 30 - 1) // anchored on the last complete day (yesterday)
        #expect(steps.lastDaysAgo == 0)
        #expect(steps.density == 1)
    }

    @Test func `a hole in the history is measured as the largest gap`() throws {
        let now = Date()
        // Observed 1–10 and 31–40 days ago: a 20-day hole in a 40-day span.
        let coverage = CoverageScan.scan(
            series: [series(.restingHeartRate, daysAgo: Array(1...10) + Array(31...40), now: now)],
            now: now
        )
        let hr = try #require(coverage.first)
        #expect(hr.observedDays == 20)
        #expect(hr.spanDays == 40)
        #expect(hr.largestGapDays == 20)
        #expect(hr.density == 0.5)
        #expect(hr.basis.contains("largest gap 20d"))
    }

    @Test func `today is excluded and empty series produce nothing`() {
        let now = Date()
        // Only "today" (daysAgo 0 relative to startOfDay(now)) — after anchoring on the last
        // complete day, nothing remains.
        let today = calendar.startOfDay(for: now)
        let onlyToday = DailySeries(metric: .stepCount, values: [today: 5000])
        #expect(CoverageScan.scan(series: [onlyToday], now: now).isEmpty)
        #expect(CoverageScan.scan(series: [], now: now).isEmpty)
    }

    // MARK: Scout lens rotation

    @Test func `each pass gets scoutsPerPass lenses and consecutive passes rotate`() {
        let first = Instructions.scoutLenses(pass: 1)
        let second = Instructions.scoutLenses(pass: 2)
        #expect(first.count == DeepAnalysisPolicy.scoutsPerPass)
        #expect(second.count == DeepAnalysisPolicy.scoutsPerPass)
        #expect(first != second)
        // Across enough passes, every survey angle gets walked.
        let walked = Set((1...Instructions.scoutAngles.count).flatMap { Instructions.scoutLenses(pass: $0) })
        #expect(walked == Set(Instructions.scoutAngles))
    }

    // MARK: Lead → lens mapping

    @Test func `a scout lead becomes a focused investigator lens, truncated defensively`() {
        let lead = ProposedLead(
            hypothesis: String(repeating: "x", count: 500),
            metric: "stepCount",
            secondaryMetric: "restingHeartRate"
        )
        let lenses = Orchestrator.leadLenses([lead])
        #expect(lenses.count == 1)
        let lens = lenses[0]
        #expect(lens.contains("stepCount and restingHeartRate"))
        // The model-written hypothesis has no schema-side length bound — it must be clamped here.
        #expect(lens.count < 350)
    }

    @Test func `a single-metric lead does not name a pair`() {
        let lead = ProposedLead(
            hypothesis: "steps dip before poor sleep",
            metric: "stepCount",
            secondaryMetric: "stepCount"
        )
        let lens = Orchestrator.leadLenses([lead])[0]
        #expect(lens.contains("focus on stepCount;"))
        #expect(!lens.contains("stepCount and stepCount"))
    }

    // MARK: Run ledger rings

    @Test func `the ledger's lead ring truncates hypotheses and caps its length`() async {
        let ledger = RunLedger()
        await ledger.recordLeads([String(repeating: "y", count: 400)])
        let leads = await ledger.recentLeads()
        #expect(leads.count == 1)
        #expect(leads[0].count == 100) // truncated at record time — it rides in every scout prompt
        await ledger.recordLeads((0..<40).map { "lead \($0)" })
        let capped = await ledger.recentLeads(limit: 100)
        #expect(capped.count <= 24)
    }

    @Test func `retirements live in their own ring, not evicted by rejections`() async {
        let ledger = RunLedger()
        await ledger.recordRetirement(title: "Sleep steadies your heart")
        for i in 0..<40 {
            await ledger.record(title: "hypothesis \(i)", reason: "rejected")
        }
        let retired = await ledger.retirements()
        #expect(retired == ["Sleep steadies your heart"])
    }

    // MARK: Policy pins

    @Test func `three-track loop knobs hold their shipped bounds`() {
        #expect(DeepAnalysisPolicy.scoutsPerPass >= 1)
        #expect(DeepAnalysisPolicy.scoutsPerPass <= Instructions.scoutAngles.count)
        #expect(DeepAnalysisPolicy.maxLeadsPerScout <= 4)
        // A pass's lead width now falls out of the schema rather than a second, arbitrary cap —
        // every distinct lead a scout hands over is chased, none dropped by arrival order.
        #expect(DeepAnalysisPolicy.maxLeadsPerPass
            == DeepAnalysisPolicy.maxLeadsPerScout * DeepAnalysisPolicy.scoutsPerPass)
        #expect(DeepAnalysisPolicy.auditFindingsPerRefresh <= 4)
        // The 14-sessions-per-kept-finding cost claim rests on exactly three replication lenses.
        #expect(Orchestrator.replicationLenses.count == 3)
        #expect(Orchestrator.auditLenses.count == 3)
    }
}
