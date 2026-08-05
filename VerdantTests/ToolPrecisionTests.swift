import Foundation
import Testing
@testable import Verdant

/// `toolRounded` sits on the boundary where numbers enter the model's transcript — every figure the
/// agents ever see passes through it (correlation coefficients and p-values, metric means, percent
/// changes, z-scores, custom query results). It trades precision the model cannot use for tokens it
/// badly needs on a 4k window, so it has to be exact about what it keeps and total about what it
/// accepts.
struct ToolPrecisionTests {
    @Test func `keeps four significant digits across magnitudes`() {
        #expect(12345.0.toolRounded == 12350)
        #expect(abs((-4.5678).toolRounded - -4.568) < 1e-12)
        #expect(abs(0.000123456.toolRounded - 0.0001235) < 1e-12)
        #expect(7.0.toolRounded == 7)
    }

    @Test func `passes through the values that have no meaningful rounding`() {
        #expect(0.0.toolRounded == 0)
        #expect(Double.infinity.toolRounded.isInfinite)
        #expect(Double.nan.toolRounded.isNaN)
    }

    /// The regression this guards. For a subnormal the scale factor itself overflows to infinity and
    /// the result used to be NaN — a statistic handed to the model as "not a number". Unreachable
    /// with today's inputs, but this is the wrong place to rely on that.
    @Test func `a subnormal survives instead of becoming NaN`() {
        for tiny in [1e-320, 5e-324, -1e-320] {
            let rounded = tiny.toolRounded
            #expect(rounded.isFinite, "\(tiny) rounded to a non-finite value")
            #expect(!rounded.isNaN)
        }
    }

    /// Nothing routed through here may emerge non-finite from a finite input — that is the property
    /// the model's trust in these figures actually rests on.
    @Test func `no finite input ever produces a non-finite figure`() {
        let samples: [Double] = [
            1e300, -1e300, 1e-300, -1e-300, 1e-308, .leastNormalMagnitude,
            .leastNonzeroMagnitude, .greatestFiniteMagnitude, 0.5, -0.5, 99999.999
        ]
        for value in samples {
            #expect(value.toolRounded.isFinite, "\(value) produced a non-finite result")
        }
    }
}
