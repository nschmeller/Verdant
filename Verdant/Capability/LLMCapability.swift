import FoundationModels

/// Runtime gate for the on-device model. When the model isn't available the app surfaces no findings
/// (there is no deterministic/template fallback) — so the distinction the UI needs is whether the
/// user can *fix* it: `downloading` resolves itself, `notEnabled` is one Settings toggle away on this
/// same device, and only `unavailableForever` truly requires different hardware. The UI re-renders
/// when the state flips (`SystemLanguageModel` is `Observable`). Never gate on a hardcoded device list.
nonisolated enum LLMCapability: Equatable {
    case available
    /// The model is downloading. Transient — flips to `available` on its own.
    case downloading
    /// Apple Intelligence is supported on this device but switched off. Recoverable here, in Settings.
    case notEnabled
    /// This device can't run Apple Intelligence at all. The only permanent state.
    case unavailableForever

    static var current: LLMCapability {
        evaluate(SystemLanguageModel.default.availability)
    }

    static func evaluate(_ availability: SystemLanguageModel.Availability) -> LLMCapability {
        switch availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .modelNotReady:
                return .downloading
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .deviceNotEligible:
                return .unavailableForever
            @unknown default:
                return .unavailableForever
            }
        }
    }

    var isAvailable: Bool {
        self == .available
    }
}
