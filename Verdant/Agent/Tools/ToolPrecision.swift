import Foundation

/// Rounds numbers at the tool boundary, before they enter the model's transcript. A raw `Double`
/// JSON-encodes with up to 17 digits — ~10 tokens where 3 or 4 carry all the meaning a language
/// model can use. On the 4096-token on-device window, full-precision floats across a multi-call
/// exploration are a real budget leak (they contributed to real overflows on device).
nonisolated extension Double {
    /// The value rounded to 4 significant digits — indistinguishable to the model, far cheaper.
    ///
    /// The `scale.isFinite` guard is defensive, not decorative. For a subnormal input (below about
    /// 1e-308) the scale factor itself overflows to infinity, `self * scale` becomes infinity, and
    /// the result is **NaN** — which would then be handed to the model as a statistic. Nothing
    /// currently reaches that range: every value routed through here is a health measurement, a
    /// ratio, a z-score or a percentage, and the one candidate that could underflow — a p-value from
    /// an extreme correlation — collapses to exactly 0.0 (already guarded) long before going
    /// subnormal. But this sits on the boundary where numbers enter the transcript, so it should be
    /// total rather than merely correct for today's inputs.
    var toolRounded: Double {
        guard isFinite, self != 0 else { return self }
        let scale = pow(10, 3 - floor(log10(abs(self))))
        let rounded = (self * scale).rounded() / scale
        // Check the RESULT, not the intermediates. A first attempt guarded `scale` and `self * scale`
        // and still let `greatestFiniteMagnitude` through: there the multiply stays finite and the
        // DIVISION overflows. Anything that cannot round without leaving the finite range is already
        // far past four significant digits of meaning, so returning it untouched loses nothing.
        return rounded.isFinite ? rounded : self
    }
}
