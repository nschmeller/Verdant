import Foundation

/// The body system a metric belongs to, for feed diversity.
nonisolated enum MetricDomain: String, Hashable, CaseIterable {
    case activity, cardio, respiratory, body, mobility, audio, nutrition, sleep, mindfulness, environment

    /// Human-facing body-system label (e.g. for grouping the tracked-metrics list).
    var displayName: String {
        switch self {
        case .activity: "Activity"
        case .cardio: "Heart & circulation"
        case .respiratory: "Breathing"
        case .body: "Body measurements"
        case .mobility: "Mobility"
        case .audio: "Hearing"
        case .nutrition: "Nutrition"
        case .sleep: "Sleep"
        case .mindfulness: "Mindfulness"
        case .environment: "Environment"
        }
    }

    // `scopePhrase` lived here: a domain list derived from the cases, so scope copy "can never
    // silently claim a narrower coverage than the app actually tracks". Removed 2026-08-03 because
    // there is no scope copy left to derive. It served the Q&A out-of-scope answer, and that answer
    // went away when Ask became fully agentic — `Orchestrator.answer` has "no router and no
    // pre-resolved fact string", and scope is the agent's judgement now. Two tests still asserted on
    // it, which is why nothing noticed: they called it directly, so the helper stayed green while
    // its only caller disappeared.
    //
    // The Ask screen's empty state names two EXAMPLE questions rather than domains, deliberately and
    // with a reason recorded there. If a domain list is ever wanted again, derive it from `allCases`
    // as this did — and give it a caller in the same change.
}

/// How a metric's daily value is aggregated from raw samples.
nonisolated enum Aggregation {
    /// Sum all samples in the day (e.g. steps, active energy).
    case sum
    /// Mean of the day's samples (e.g. resting heart rate, HRV).
    case average

    /// The HealthKit statistic this aggregation asks for, decided once instead of at each query.
    ///
    /// The ingest sites used to write `let isSum = metric.aggregation == .sum` and branch on the
    /// boolean. That is correct for exactly two cases and silently wrong for a third: a new
    /// aggregation would be averaged, and an averaged step count is a plausible-looking number that
    /// is simply not the day's total. Wrong daily values feed every statistic, every finding and
    /// every card, so this is the worst place in the app to lose a case quietly. Expressed as a
    /// property so the compiler demands an answer instead.
    var wantsCumulativeSum: Bool {
        switch self {
        case .sum: true
        case .average: false
        }
    }
}

/// The physical unit a metric's daily value is stored in (the canonical HealthKit unit). Domain
/// stays free of HealthKit types; `HealthTypeMapping` maps these to concrete `HKUnit`s. The
/// `display`/`fractionDigits` describe how a stored value is shown (e.g. meters shown as km, the
/// 0–1 percent fraction shown ×100).
nonisolated enum UnitKind: String {
    case count, distanceMeters, meters, kilocalorie, minutes, hours, perMinute, milliseconds
    case vo2Max, percent, celsius, kilograms, centimeters, metersPerSecond
    case decibels, milliliters, grams, milligrams
    case watts, millimetersOfMercury, milligramsPerDeciliter, mets

    var fractionDigits: Int {
        switch self {
        case .count, .kilocalorie, .minutes, .perMinute, .milliseconds, .percent, .decibels,
             .milliliters, .grams, .milligrams, .meters, .watts, .millimetersOfMercury,
             .milligramsPerDeciliter: 0
        case .distanceMeters, .hours, .vo2Max, .celsius, .kilograms, .centimeters, .mets: 1
        case .metersPerSecond: 2
        }
    }

    /// Convert the stored canonical value to its display value.
    ///
    /// Exhaustive, with no `default`. A unit that needs conversion but silently inherits "no
    /// conversion" is the worst shape of bug this app can have: the number is shown under the NEW
    /// unit's label while still holding the canonical value — metres per second presented as miles
    /// per hour — and nothing anywhere fails. Listing every case forces whoever adds one to answer
    /// the only question that matters here, even when the answer is "no conversion".
    func display(_ stored: Double) -> Double {
        switch self {
        case .distanceMeters: stored / 1000 // meters → km
        case .percent: stored * 100 // 0–1 fraction → %
        // Stored canonically in the unit already shown.
        case .count, .meters, .kilocalorie, .minutes, .hours, .perMinute, .milliseconds, .vo2Max,
             .celsius, .kilograms, .centimeters, .metersPerSecond, .decibels, .milliliters, .grams,
             .milligrams, .watts, .millimetersOfMercury, .milligramsPerDeciliter, .mets:
            stored
        }
    }
}

/// Where a metric's data comes from and how it is reduced to one value per day.
nonisolated enum MetricSource: Equatable {
    /// A HealthKit quantity type aggregated with `Aggregation`.
    case quantity(UnitKind, Aggregation)
    /// Total asleep hours per night, from `HKCategoryType.sleepAnalysis`.
    case sleepHours
    /// Total mindful minutes per day, from `HKCategoryType.mindfulSession`.
    case mindfulMinutes
}

/// One registered metric — a single ROW of configuration, so adding a data source touches exactly
/// one place (`MetricRegistry.table`) instead of parallel switches across the codebase.
nonisolated struct MetricDescriptor {
    let key: String
    let displayName: String
    let source: MetricSource
    /// Short unit label for phrasing/UI (e.g. "bpm", "km", "%"; "" for bare counts).
    let unitLabel: String
    /// Framing hint for phrasing only — never affects any decision.
    let higherIsHealthier: Bool?
    /// The body system, for feed diversity and the Settings grouping.
    let domain: MetricDomain
    /// The full HealthKit quantity-type identifier raw value (nil for category-based sources).
    var healthKitIdentifier: String?
    /// Auto-measured Apple Watch vitals. A new/replaced Watch recalibrates these, producing a
    /// simultaneous step across several of them — which a regime-shift detector must not mistake
    /// for physiology.
    var isWatchVital = false
    /// Redundancy tags (see `MetricCatalog`): metrics tagged `exertionAggregate` are mutually
    /// redundant AND redundant with anything tagged `locomotionOutput` — "you moved more so you
    /// burned more" is a tautology, not an insight.
    var tags: Set<MetricTag> = []
    /// Minimum recent-window days required to even attempt a comparison.
    var minRecentSamples = 4
    /// Minimum baseline days required for a stable baseline.
    var minBaselineSamples = 14
}

/// Mechanical-coupling tags for the rule-based redundancy check.
nonisolated enum MetricTag: Hashable {
    /// Raw movement volume: steps, distances, strokes, pushes, flights.
    case locomotionOutput
    /// Aggregate exertion measures mechanically driven by movement volume: energy, exercise/move
    /// time, effort, power.
    case exertionAggregate
    /// Mutually-derived body-composition measures (weight, BMI, body fat, lean mass, waist).
    case bodyComposition
}

/// A registered metric key. Same surface as the old closed enum (static members, `allCases`,
/// failable `init?(rawValue:)`), but backed by the data-driven `MetricRegistry` — so the closed,
/// verifiable vocabulary is now *"resolvable in the registry"* rather than *"is a compiled case"*,
/// and adding a data source is one table row. `init?(rawValue:)` returning `nil` for unregistered
/// strings is the load-bearing anti-hallucination boundary: the model can only ever name a metric
/// the deterministic layer can resolve and recompute.
nonisolated struct MetricKey: RawRepresentable, Hashable, Identifiable {
    let rawValue: String

    init?(rawValue: String) {
        guard MetricRegistry.byKey[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    /// Registry-internal trusted construction (the key comes from the table itself).
    init(registryKey: String) {
        rawValue = registryKey
    }

    var id: String {
        rawValue
    }

    var descriptor: MetricDescriptor {
        // The failable init and `registryKey` construction both guarantee registry presence.
        MetricRegistry.byKey[rawValue]!
    }

    var displayName: String {
        descriptor.displayName
    }

    var source: MetricSource {
        descriptor.source
    }

    var unitLabel: String {
        descriptor.unitLabel
    }

    var higherIsHealthier: Bool? {
        descriptor.higherIsHealthier
    }

    var domain: MetricDomain {
        descriptor.domain
    }

    var isWatchVital: Bool {
        descriptor.isWatchVital
    }

    var unitKind: UnitKind {
        switch source {
        case let .quantity(unit, _): unit
        case .sleepHours: .hours
        case .mindfulMinutes: .minutes
        }
    }

    var aggregation: Aggregation {
        switch source {
        case let .quantity(_, aggregation): aggregation
        case .sleepHours, .mindfulMinutes: .sum
        }
    }

    /// All metric raw values — the closed vocabulary every LLM-facing `.anyOf` uses. Derived from
    /// the registry, so registering a source automatically extends what the model may name.
    static let allRawValues: [String] = MetricRegistry.table.map(\.key)
}

nonisolated extension MetricKey: CaseIterable {
    /// Every registered metric, in registry (domain-grouped) order.
    static var allCases: [MetricKey] {
        MetricRegistry.orderedKeys
    }
}

nonisolated extension MetricKey: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = MetricKey(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unregistered metric key: \(raw)"
            ))
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Static members (compile-time-checked names for code and tests)

nonisolated extension MetricKey {
    // Activity
    static let stepCount = MetricKey(registryKey: "stepCount")
    static let distanceWalkingRunning = MetricKey(registryKey: "distanceWalkingRunning")
    static let distanceCycling = MetricKey(registryKey: "distanceCycling")
    static let flightsClimbed = MetricKey(registryKey: "flightsClimbed")
    static let activeEnergyBurned = MetricKey(registryKey: "activeEnergyBurned")
    static let basalEnergyBurned = MetricKey(registryKey: "basalEnergyBurned")
    static let appleExerciseTime = MetricKey(registryKey: "appleExerciseTime")
    static let appleStandTime = MetricKey(registryKey: "appleStandTime")
    static let appleMoveTime = MetricKey(registryKey: "appleMoveTime")
    static let physicalEffort = MetricKey(registryKey: "physicalEffort")
    static let distanceSwimming = MetricKey(registryKey: "distanceSwimming")
    static let swimmingStrokeCount = MetricKey(registryKey: "swimmingStrokeCount")
    static let pushCount = MetricKey(registryKey: "pushCount")
    static let distanceWheelchair = MetricKey(registryKey: "distanceWheelchair")
    static let distanceDownhillSnowSports = MetricKey(registryKey: "distanceDownhillSnowSports")
    static let distancePaddleSports = MetricKey(registryKey: "distancePaddleSports")
    static let distanceRowing = MetricKey(registryKey: "distanceRowing")
    static let distanceCrossCountrySkiing = MetricKey(registryKey: "distanceCrossCountrySkiing")
    static let distanceSkatingSports = MetricKey(registryKey: "distanceSkatingSports")
    static let runningSpeed = MetricKey(registryKey: "runningSpeed")
    static let runningPower = MetricKey(registryKey: "runningPower")
    static let runningStrideLength = MetricKey(registryKey: "runningStrideLength")
    static let runningGroundContactTime = MetricKey(registryKey: "runningGroundContactTime")
    static let runningVerticalOscillation = MetricKey(registryKey: "runningVerticalOscillation")
    static let cyclingSpeed = MetricKey(registryKey: "cyclingSpeed")
    static let cyclingPower = MetricKey(registryKey: "cyclingPower")
    static let cyclingCadence = MetricKey(registryKey: "cyclingCadence")
    static let cyclingFunctionalThresholdPower = MetricKey(registryKey: "cyclingFunctionalThresholdPower")
    // Cardio
    static let heartRate = MetricKey(registryKey: "heartRate")
    static let restingHeartRate = MetricKey(registryKey: "restingHeartRate")
    static let walkingHeartRateAverage = MetricKey(registryKey: "walkingHeartRateAverage")
    static let heartRateVariabilitySDNN = MetricKey(registryKey: "heartRateVariabilitySDNN")
    static let heartRateRecoveryOneMinute = MetricKey(registryKey: "heartRateRecoveryOneMinute")
    static let vo2Max = MetricKey(registryKey: "vo2Max")
    static let bloodPressureSystolic = MetricKey(registryKey: "bloodPressureSystolic")
    static let bloodPressureDiastolic = MetricKey(registryKey: "bloodPressureDiastolic")
    // Respiratory
    static let respiratoryRate = MetricKey(registryKey: "respiratoryRate")
    static let oxygenSaturation = MetricKey(registryKey: "oxygenSaturation")
    // Body
    static let appleSleepingWristTemperature = MetricKey(registryKey: "appleSleepingWristTemperature")
    static let bodyMass = MetricKey(registryKey: "bodyMass")
    static let bodyMassIndex = MetricKey(registryKey: "bodyMassIndex")
    static let bodyFatPercentage = MetricKey(registryKey: "bodyFatPercentage")
    static let leanBodyMass = MetricKey(registryKey: "leanBodyMass")
    static let waistCircumference = MetricKey(registryKey: "waistCircumference")
    static let bodyTemperature = MetricKey(registryKey: "bodyTemperature")
    static let basalBodyTemperature = MetricKey(registryKey: "basalBodyTemperature")
    static let bloodGlucose = MetricKey(registryKey: "bloodGlucose")
    // Mobility
    static let walkingSpeed = MetricKey(registryKey: "walkingSpeed")
    static let walkingStepLength = MetricKey(registryKey: "walkingStepLength")
    static let walkingAsymmetryPercentage = MetricKey(registryKey: "walkingAsymmetryPercentage")
    static let walkingDoubleSupportPercentage = MetricKey(registryKey: "walkingDoubleSupportPercentage")
    static let stairAscentSpeed = MetricKey(registryKey: "stairAscentSpeed")
    static let stairDescentSpeed = MetricKey(registryKey: "stairDescentSpeed")
    static let sixMinuteWalkTestDistance = MetricKey(registryKey: "sixMinuteWalkTestDistance")
    static let appleWalkingSteadiness = MetricKey(registryKey: "appleWalkingSteadiness")
    // Audio
    static let headphoneAudioExposure = MetricKey(registryKey: "headphoneAudioExposure")
    static let environmentalAudioExposure = MetricKey(registryKey: "environmentalAudioExposure")
    // Nutrition
    static let dietaryEnergyConsumed = MetricKey(registryKey: "dietaryEnergyConsumed")
    static let dietaryWater = MetricKey(registryKey: "dietaryWater")
    static let dietaryProtein = MetricKey(registryKey: "dietaryProtein")
    static let dietaryCarbohydrates = MetricKey(registryKey: "dietaryCarbohydrates")
    static let dietaryFatTotal = MetricKey(registryKey: "dietaryFatTotal")
    static let dietaryFatSaturated = MetricKey(registryKey: "dietaryFatSaturated")
    static let dietaryFiber = MetricKey(registryKey: "dietaryFiber")
    static let dietarySugar = MetricKey(registryKey: "dietarySugar")
    static let dietarySodium = MetricKey(registryKey: "dietarySodium")
    static let dietaryCholesterol = MetricKey(registryKey: "dietaryCholesterol")
    static let dietaryCaffeine = MetricKey(registryKey: "dietaryCaffeine")
    static let numberOfAlcoholicBeverages = MetricKey(registryKey: "numberOfAlcoholicBeverages")
    // Sleep & mindfulness & environment
    static let sleepDurationHours = MetricKey(registryKey: "sleepDurationHours")
    static let mindfulMinutes = MetricKey(registryKey: "mindfulMinutes")
    static let timeInDaylight = MetricKey(registryKey: "timeInDaylight")
}
