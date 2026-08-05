import Foundation

/// Minimum sample counts for a comparison to even attempt a statistic — a *produce-a-number* gate
/// (can we compute something trustworthy?), not a decision gate (worth is the agent's call).
nonisolated struct MetricRule {
    var minRecentSamples: Int = 4
    var minBaselineSamples: Int = 14
}

/// Registry-derived per-metric configuration and the mechanical-redundancy rules.
nonisolated enum MetricCatalog {
    static func rule(for metric: MetricKey) -> MetricRule {
        let descriptor = metric.descriptor
        return MetricRule(
            minRecentSamples: descriptor.minRecentSamples,
            minBaselineSamples: descriptor.minBaselineSamples
        )
    }

    // MARK: - Mechanical redundancy (the "no obvious facts" guard)

    /// Whether a pair is tautologically or mechanically coupled — correlating them tells the user
    /// nothing they don't already know. Mostly RULE-BASED so it scales with the registry:
    ///
    ///  1. **Exertion tautology** — any two exertion aggregates (energy, exercise/move time, effort,
    ///     power), or an exertion aggregate vs. any raw movement volume (steps, distances, strokes):
    ///     "you moved more so you burned more" is physics, not insight. Raw volumes among themselves
    ///     stay ELIGIBLE (steps vs. cycling distance is genuine cross-mode substitution).
    ///  2. **Body composition** — mutually derived measures (weight, BMI, body fat, lean mass, waist).
    ///  3. **Heart rate vs. activity** — daily-average HR and walking HR are mechanically driven by
    ///     that day's movement; excluded against the whole activity domain. Rest-measured recovery
    ///     signals (resting HR, HRV, VO₂ max, HR recovery) stay eligible — those are the genuinely
    ///     interesting links.
    ///  4. A small curated pair list for couplings the rules can't express.
    static func isMechanicallyRedundant(_ a: MetricKey, _ b: MetricKey) -> Bool {
        if a == b { return true }
        let da = a.descriptor, db = b.descriptor

        // Rule 1: exertion aggregates vs. each other or vs. raw movement volume.
        let aExertion = da.tags.contains(.exertionAggregate)
        let bExertion = db.tags.contains(.exertionAggregate)
        if aExertion, bExertion { return true }
        if aExertion, db.tags.contains(.locomotionOutput) { return true }
        if bExertion, da.tags.contains(.locomotionOutput) { return true }

        // Rule 2: mutually-derived body-composition measures.
        if da.tags.contains(.bodyComposition), db.tags.contains(.bodyComposition) { return true }

        // Rule 3: daily-average heart rates vs. anything in the activity domain.
        let hrLevel: Set<MetricKey> = [.heartRate, .walkingHeartRateAverage]
        if hrLevel.contains(a), db.domain == .activity { return true }
        if hrLevel.contains(b), da.domain == .activity { return true }

        return redundantPairKeys.contains([a.rawValue, b.rawValue].sorted().joined(separator: "|"))
    }

    /// Curated pairs the rules above can't express. Order-independent, stored as sorted `"a|b"` keys.
    private static let redundantPairKeys: Set<String> = {
        let pairs: [(MetricKey, MetricKey)] = [
            // Same signal expressed twice.
            (.stepCount, .distanceWalkingRunning),
            // Gait is internally coupled; steadiness is computed FROM the other gait measures.
            (.walkingSpeed, .walkingStepLength),
            (.walkingSpeed, .sixMinuteWalkTestDistance),
            (.walkingAsymmetryPercentage, .walkingDoubleSupportPercentage),
            (.appleWalkingSteadiness, .walkingSpeed),
            (.appleWalkingSteadiness, .walkingAsymmetryPercentage),
            (.appleWalkingSteadiness, .walkingDoubleSupportPercentage),
            (.stairAscentSpeed, .stairDescentSpeed),
            (.walkingHeartRateAverage, .walkingSpeed),
            // Sport dynamics: intensity measures of the same session.
            (.runningPower, .runningSpeed),
            (.cyclingPower, .cyclingSpeed),
            // Basal energy is essentially a function of body size.
            (.basalEnergyBurned, .bodyMass),
            (.basalEnergyBurned, .leanBodyMass),
            // Heart-rate measures overlap by construction.
            (.heartRate, .restingHeartRate),
            (.heartRate, .walkingHeartRateAverage),
            // The two blood-pressure numbers come from the same reading.
            (.bloodPressureSystolic, .bloodPressureDiastolic),
            // The two temperature streams measure the same physiology.
            (.bodyTemperature, .basalBodyTemperature),
            // Macronutrients are components of total dietary energy; subsets of each other.
            (.dietaryEnergyConsumed, .dietaryProtein),
            (.dietaryEnergyConsumed, .dietaryCarbohydrates),
            (.dietaryEnergyConsumed, .dietaryFatTotal),
            (.dietaryEnergyConsumed, .dietarySugar),
            (.dietaryFatTotal, .dietaryFatSaturated),
            (.dietaryCarbohydrates, .dietarySugar),
            (.dietaryCarbohydrates, .dietaryFiber)
        ]
        return Set(pairs.map { [$0.0.rawValue, $0.1.rawValue].sorted().joined(separator: "|") })
    }()
}
