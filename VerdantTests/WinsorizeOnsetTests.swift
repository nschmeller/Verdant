import Foundation
import Testing
@testable import Verdant

/// Where the outlier protection actually switches on, measured rather than assumed.
///
/// `winsorize` clips to the 2.5/97.5 percentiles "so one device gap or backfilled day can't swing a
/// correlation", behind a `count >= 8` guard. The guard is not what decides it — the percentiles are,
/// and they switch on ASYMMETRICALLY:
///
///     n <= 20   neither end clipped
///     n == 21   low end only        <- exactly `minPairs`
///     n >= 22   both ends
///
/// It matters because of where that lands. A pair sitting exactly at the eligibility floor has no
/// UPPER clip, and the upper end is where real outliers arrive: a backfilled day or a device gap
/// produces a large positive change. That is also the correlation most exposed to one, being 1/21 of
/// its evidence.
///
/// These pin the boundary so a future change to the percentiles, the guard, or `minPairs` has to
/// confront it. They assert the CURRENT behaviour is understood, not that it is ideal.
///
/// The first version of this suite said protection began at 24 and tested only the high end. That
/// came from sampling n at 8, 12, 16, 20, 21, 24 and reading the boundary off the gap — 22 and 23
/// were never computed. Writing the test is what found it. A boundary inferred from a grid is a
/// guess about the points you did not evaluate.
struct WinsorizeOnsetTests {
    /// A series of `count` days with one extreme value at the top or the bottom.
    private func series(count: Int, high: Bool) -> [Date: Double] {
        var map: [Date: Double] = [:]
        for day in 0..<count {
            let date = Date(timeIntervalSince1970: Double(day) * 86400)
            map[date] = day == 0 ? (high ? 1000 : -1000) : Double(10 + day % 3)
        }
        return map
    }

    private func clipsHigh(_ count: Int) -> Bool {
        let input = series(count: count, high: true)
        return CorrelationEngine.winsorize(input).values.max() != input.values.max()
    }

    private func clipsLow(_ count: Int) -> Bool {
        let input = series(count: count, high: false)
        return CorrelationEngine.winsorize(input).values.min() != input.values.min()
    }

    /// The finding, and it is asymmetric: at exactly `minPairs` the LOW end is clipped and the HIGH
    /// end is not. A backfilled day or a device gap produces a large positive change, so the end that
    /// is unprotected at the floor is the end the real outliers arrive at.
    @Test func `at the eligibility floor only the low end is protected`() {
        let floor = CorrelationEngine.Config().minPairs
        #expect(floor == 21, "minPairs moved — the boundaries below were measured against 21")
        #expect(clipsLow(floor))
        #expect(!clipsHigh(floor), "the upper clip now fires at the floor; update winsorize's doc")
    }

    @Test func `both ends are protected from twenty-two days`() {
        #expect(!clipsHigh(21))
        #expect(clipsHigh(22), "the upper clip no longer switches on at 22")
        #expect(clipsLow(22))
    }

    /// And nothing at all is clipped below 21, despite the guard reading `>= 8`.
    @Test func `nothing is clipped below the floor`() {
        #expect(!clipsHigh(20))
        #expect(!clipsLow(20))
    }

    /// Non-vacuity: the fixture really does contain an outlier that CAN be clipped, so the
    /// false results above mean "not clipped" rather than "nothing to clip".
    @Test func `the fixture has an outlier a longer series does remove`() {
        let input = series(count: 60, high: true)
        let output = CorrelationEngine.winsorize(input)
        #expect(input.values.max() == 1000)
        let maximum = try? #require(output.values.max())
        #expect(maximum ?? 0 < 1000, "the outlier survived a 60-day winsorize")
        // And the clip is to a real observed value, not to some invented bound.
        #expect(input.values.contains(maximum ?? -1))
    }

    /// The guard the reader sees first is honest about its own job: it stops percentile arithmetic on
    /// a series too short to have percentiles, and decides nothing about clipping.
    @Test func `the count guard passes short series through untouched`() {
        let tiny = series(count: 7, high: true)
        #expect(CorrelationEngine.winsorize(tiny) == tiny)
    }
}
