import Foundation
import Testing
@testable import Verdant

/// The Neural Engine duty cycle is the instrument for the app's entire purpose — "the model was
/// generating N% of the last minute" is how anyone tells whether the thing is doing its job. It has
/// to be honest about that, especially when it flatters the app.
struct DutyCycleTests {
    private func samples(_ pairs: [(Double, Double)]) -> [ResourceMonitor.BusySample] {
        pairs.map { ResourceMonitor.BusySample(at: $0.0, busy: $0.1) }
    }

    @Test func `a model generating half the window reads as half`() throws {
        // 10 seconds elapsed, 5 of them spent generating.
        let measured = try #require(ResourceMonitor.dutyCycle(samples([(100, 20), (110, 25)])))
        #expect(abs(measured - 0.5) < 1e-9)
    }

    /// The regression. `Task.sleep(for: .seconds(1))` guarantees a floor, not a period — under load
    /// the sampler drifts, and the app is *designed* to run the device hot. Dividing the busy delta
    /// by the SAMPLE COUNT instead of the measured span inflated the result by exactly the drift
    /// factor and then clamped it to 1.0, so the meter would report a fully saturated engine while
    /// it actually idled a third of the time.
    @Test func `sampler drift does not inflate the reading`() throws {
        // Eleven samples 1.5s apart: 15s elapsed, 10s generating — a true two-thirds.
        let drifted = samples((0...10).map { (Double($0) * 1.5, Double($0) * 1.0) })
        let measured = try #require(ResourceMonitor.dutyCycle(drifted))
        #expect(abs(measured - 2.0 / 3.0) < 1e-9)
        // Counting samples as seconds would have produced 10/10 = 1.0. Pin that it does not.
        #expect(measured < 0.99)
    }

    @Test func `an idle engine reads zero and a saturated one reads one`() throws {
        #expect(try #require(ResourceMonitor.dutyCycle(samples([(0, 7), (60, 7)]))) == 0)
        #expect(try #require(ResourceMonitor.dutyCycle(samples([(0, 0), (60, 60)]))) == 1)
    }

    /// Never above 1, whatever the clocks do. `busySeconds` and the sample stamp are read a moment
    /// apart, so a generation straddling the read can contribute slightly more busy time than the
    /// span — a duty cycle over 100% would just look broken.
    @Test func `the reading is clamped into zero to one`() throws {
        #expect(try #require(ResourceMonitor.dutyCycle(samples([(0, 0), (10, 11)]))) == 1)
        #expect(try #require(ResourceMonitor.dutyCycle(samples([(0, 5), (10, 4)]))) == 0)
    }

    /// Too little history is reported as "don't know" rather than a wild ratio off a fraction of a
    /// second — the meter keeps its previous value instead of flickering on startup.
    @Test func `too short a base yields no reading at all`() {
        #expect(ResourceMonitor.dutyCycle([]) == nil)
        #expect(ResourceMonitor.dutyCycle(samples([(0, 0)])) == nil)
        #expect(ResourceMonitor.dutyCycle(samples([(0, 0), (0.4, 0.4)])) == nil)
    }

    /// The meter names the window it is ACTUALLY averaging over.
    ///
    /// It used to say "last minute" from the moment it appeared, holding a few seconds of history —
    /// a small lie on the one screen whose entire job is honest measurement. The fix had no test, so
    /// simplifying the label back to a constant string would have restored the lie silently.
    @Test func `the window label never claims more history than it has`() {
        #expect(ResourceMonitor.dutyCycleWindowLabel(spanSeconds: 0) == "last 0s")
        #expect(ResourceMonitor.dutyCycleWindowLabel(spanSeconds: 3) == "last 3s")
        #expect(ResourceMonitor.dutyCycleWindowLabel(spanSeconds: 20) == "last 20s")
        // One second of slack, so a sampler that lands at 59.4s does not read "last 59s" forever.
        #expect(ResourceMonitor.dutyCycleWindowLabel(spanSeconds: 58) == "last 58s")
        #expect(ResourceMonitor.dutyCycleWindowLabel(spanSeconds: 59) == "last minute")
        #expect(ResourceMonitor.dutyCycleWindowLabel(spanSeconds: 60) == "last minute")

        // The property, not just the examples: below the window it must never claim a minute.
        for span in stride(from: 0.0, through: 58.0, by: 1.0) {
            #expect(
                ResourceMonitor.dutyCycleWindowLabel(spanSeconds: span) != "last minute",
                "claimed a full minute with only \(span)s of history"
            )
        }
    }
}
