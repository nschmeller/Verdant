import Foundation

/// The data-driven registry of every health data source Verdant reads — **one row per source**.
/// Adding a source means adding a row here (and nothing else): ingestion, authorization, the stats
/// provider, every LLM-facing `.anyOf` vocabulary, the Settings list, and the redundancy rules all
/// derive from this table. The registry is also the anti-hallucination boundary: `MetricKey`'s
/// failable `init?(rawValue:)` resolves against it, so the model can only ever name a metric the
/// deterministic layer can recompute.
///
/// Coverage philosophy: every HealthKit type whose *daily trend* is meaningful — activity and sport
/// distances, running/cycling dynamics, vitals, body and metabolic measures, gait and mobility,
/// hearing, nutrition, sleep, mindfulness, and daylight. Deliberately skipped: workout-session-scoped
/// types (e.g. underwater depth), event/category types with no daily magnitude, diagnosis-adjacent
/// clinical burdens, and the micronutrient long tail.
///
/// `healthKitIdentifier` strings are validated by `MetricRegistryTests` against the real SDK
/// (identifier resolves, unit is compatible), so a typo here fails CI rather than crashing ingest.
nonisolated enum MetricRegistry {
    static let table: [MetricDescriptor] = [
        // MARK: Activity — volume

        .init(
            key: "stepCount", displayName: "Steps", source: .quantity(.count, .sum),
            unitLabel: "steps", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierStepCount",
            tags: [.locomotionOutput], minRecentSamples: 5
        ),
        .init(
            key: "distanceWalkingRunning", displayName: "Walking + running distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceWalkingRunning",
            tags: [.locomotionOutput], minRecentSamples: 5
        ),
        .init(
            key: "distanceCycling", displayName: "Cycling distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceCycling",
            tags: [.locomotionOutput], minRecentSamples: 5
        ),
        .init(
            key: "flightsClimbed", displayName: "Flights climbed", source: .quantity(.count, .sum),
            unitLabel: "flights", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierFlightsClimbed", tags: [.locomotionOutput]
        ),
        .init(
            key: "distanceSwimming", displayName: "Swimming distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceSwimming",
            tags: [.locomotionOutput]
        ),
        .init(
            key: "swimmingStrokeCount", displayName: "Swimming strokes", source: .quantity(.count, .sum),
            unitLabel: "strokes", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierSwimmingStrokeCount", tags: [.locomotionOutput]
        ),
        .init(
            key: "pushCount", displayName: "Wheelchair pushes", source: .quantity(.count, .sum),
            unitLabel: "pushes", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierPushCount", tags: [.locomotionOutput]
        ),
        .init(
            key: "distanceWheelchair", displayName: "Wheelchair distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceWheelchair",
            tags: [.locomotionOutput]
        ),
        .init(
            key: "distanceDownhillSnowSports", displayName: "Downhill snow-sports distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceDownhillSnowSports",
            tags: [.locomotionOutput]
        ),
        .init(
            key: "distancePaddleSports", displayName: "Paddle-sports distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistancePaddleSports",
            tags: [.locomotionOutput]
        ),
        .init(
            key: "distanceRowing", displayName: "Rowing distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceRowing",
            tags: [.locomotionOutput]
        ),
        .init(
            key: "distanceCrossCountrySkiing", displayName: "Cross-country skiing distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceCrossCountrySkiing",
            tags: [.locomotionOutput]
        ),
        .init(
            key: "distanceSkatingSports", displayName: "Skating distance",
            source: .quantity(.distanceMeters, .sum), unitLabel: "km", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierDistanceSkatingSports",
            tags: [.locomotionOutput]
        ),

        // MARK: Activity — exertion aggregates

        .init(
            key: "activeEnergyBurned", displayName: "Active energy", source: .quantity(.kilocalorie, .sum),
            unitLabel: "kcal", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
            tags: [.exertionAggregate], minRecentSamples: 5
        ),
        .init(
            key: "basalEnergyBurned", displayName: "Resting energy", source: .quantity(.kilocalorie, .sum),
            unitLabel: "kcal", higherIsHealthier: nil, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierBasalEnergyBurned"
        ),
        .init(
            key: "appleExerciseTime", displayName: "Exercise minutes", source: .quantity(.minutes, .sum),
            unitLabel: "min", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierAppleExerciseTime", tags: [.exertionAggregate]
        ),
        .init(
            key: "appleStandTime", displayName: "Stand minutes", source: .quantity(.minutes, .sum),
            unitLabel: "min", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierAppleStandTime", tags: [.exertionAggregate]
        ),
        .init(
            key: "appleMoveTime", displayName: "Move minutes", source: .quantity(.minutes, .sum),
            unitLabel: "min", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierAppleMoveTime", tags: [.exertionAggregate]
        ),
        .init(
            key: "physicalEffort", displayName: "Physical effort", source: .quantity(.mets, .average),
            unitLabel: "MET", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierPhysicalEffort", tags: [.exertionAggregate]
        ),

        // MARK: Activity — running & cycling dynamics

        .init(
            key: "runningSpeed", displayName: "Running speed", source: .quantity(.metersPerSecond, .average),
            unitLabel: "m/s", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierRunningSpeed"
        ),
        .init(
            key: "runningPower", displayName: "Running power", source: .quantity(.watts, .average),
            unitLabel: "W", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierRunningPower", tags: [.exertionAggregate]
        ),
        .init(
            key: "runningStrideLength", displayName: "Running stride length",
            source: .quantity(.centimeters, .average), unitLabel: "cm", higherIsHealthier: nil,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierRunningStrideLength"
        ),
        .init(
            key: "runningGroundContactTime", displayName: "Ground contact time",
            source: .quantity(.milliseconds, .average), unitLabel: "ms", higherIsHealthier: false,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierRunningGroundContactTime"
        ),
        .init(
            key: "runningVerticalOscillation", displayName: "Vertical oscillation",
            source: .quantity(.centimeters, .average), unitLabel: "cm", higherIsHealthier: false,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierRunningVerticalOscillation"
        ),
        .init(
            key: "cyclingSpeed", displayName: "Cycling speed", source: .quantity(.metersPerSecond, .average),
            unitLabel: "m/s", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierCyclingSpeed"
        ),
        .init(
            key: "cyclingPower", displayName: "Cycling power", source: .quantity(.watts, .average),
            unitLabel: "W", higherIsHealthier: true, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierCyclingPower", tags: [.exertionAggregate]
        ),
        .init(
            key: "cyclingCadence", displayName: "Cycling cadence", source: .quantity(.perMinute, .average),
            unitLabel: "rpm", higherIsHealthier: nil, domain: .activity,
            healthKitIdentifier: "HKQuantityTypeIdentifierCyclingCadence"
        ),
        .init(
            key: "cyclingFunctionalThresholdPower", displayName: "Cycling FTP",
            source: .quantity(.watts, .average), unitLabel: "W", higherIsHealthier: true,
            domain: .activity, healthKitIdentifier: "HKQuantityTypeIdentifierCyclingFunctionalThresholdPower"
        ),

        // MARK: Heart & circulation

        .init(
            key: "heartRate", displayName: "Heart rate", source: .quantity(.perMinute, .average),
            unitLabel: "bpm", higherIsHealthier: nil, domain: .cardio,
            healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate"
        ),
        .init(
            key: "restingHeartRate", displayName: "Resting heart rate",
            source: .quantity(.perMinute, .average), unitLabel: "bpm", higherIsHealthier: false,
            domain: .cardio, healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate",
            isWatchVital: true
        ),
        .init(
            key: "walkingHeartRateAverage", displayName: "Walking heart rate",
            source: .quantity(.perMinute, .average), unitLabel: "bpm", higherIsHealthier: false,
            domain: .cardio, healthKitIdentifier: "HKQuantityTypeIdentifierWalkingHeartRateAverage",
            isWatchVital: true
        ),
        .init(
            key: "heartRateVariabilitySDNN", displayName: "Heart rate variability",
            source: .quantity(.milliseconds, .average), unitLabel: "ms", higherIsHealthier: true,
            domain: .cardio, healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            isWatchVital: true
        ),
        .init(
            key: "heartRateRecoveryOneMinute", displayName: "Heart rate recovery",
            source: .quantity(.perMinute, .average), unitLabel: "bpm", higherIsHealthier: true,
            domain: .cardio, healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute",
            isWatchVital: true
        ),
        .init(
            key: "vo2Max", displayName: "VO₂ max", source: .quantity(.vo2Max, .average),
            unitLabel: "mL/kg·min", higherIsHealthier: true, domain: .cardio,
            healthKitIdentifier: "HKQuantityTypeIdentifierVO2Max", isWatchVital: true
        ),
        .init(
            key: "bloodPressureSystolic", displayName: "Systolic blood pressure",
            source: .quantity(.millimetersOfMercury, .average), unitLabel: "mmHg",
            higherIsHealthier: nil, domain: .cardio,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureSystolic"
        ),
        .init(
            key: "bloodPressureDiastolic", displayName: "Diastolic blood pressure",
            source: .quantity(.millimetersOfMercury, .average), unitLabel: "mmHg",
            higherIsHealthier: nil, domain: .cardio,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodPressureDiastolic"
        ),

        // MARK: Breathing

        .init(
            key: "respiratoryRate", displayName: "Respiratory rate",
            source: .quantity(.perMinute, .average), unitLabel: "breaths/min", higherIsHealthier: nil,
            domain: .respiratory, healthKitIdentifier: "HKQuantityTypeIdentifierRespiratoryRate",
            isWatchVital: true
        ),
        .init(
            key: "oxygenSaturation", displayName: "Blood oxygen", source: .quantity(.percent, .average),
            unitLabel: "%", higherIsHealthier: true, domain: .respiratory,
            healthKitIdentifier: "HKQuantityTypeIdentifierOxygenSaturation", isWatchVital: true
        ),

        // MARK: Body & metabolic

        .init(
            key: "appleSleepingWristTemperature", displayName: "Wrist temperature",
            source: .quantity(.celsius, .average), unitLabel: "°C", higherIsHealthier: nil,
            domain: .body, healthKitIdentifier: "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
            isWatchVital: true
        ),
        .init(
            key: "bodyMass", displayName: "Weight", source: .quantity(.kilograms, .average),
            unitLabel: "kg", higherIsHealthier: nil, domain: .body,
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyMass", tags: [.bodyComposition]
        ),
        .init(
            key: "bodyMassIndex", displayName: "Body mass index", source: .quantity(.count, .average),
            unitLabel: "", higherIsHealthier: nil, domain: .body,
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyMassIndex", tags: [.bodyComposition]
        ),
        .init(
            key: "bodyFatPercentage", displayName: "Body fat", source: .quantity(.percent, .average),
            unitLabel: "%", higherIsHealthier: nil, domain: .body,
            healthKitIdentifier: "HKQuantityTypeIdentifierBodyFatPercentage", tags: [.bodyComposition]
        ),
        .init(
            key: "leanBodyMass", displayName: "Lean body mass", source: .quantity(.kilograms, .average),
            unitLabel: "kg", higherIsHealthier: true, domain: .body,
            healthKitIdentifier: "HKQuantityTypeIdentifierLeanBodyMass", tags: [.bodyComposition]
        ),
        .init(
            key: "waistCircumference", displayName: "Waist circumference",
            source: .quantity(.centimeters, .average), unitLabel: "cm", higherIsHealthier: nil,
            domain: .body, healthKitIdentifier: "HKQuantityTypeIdentifierWaistCircumference",
            tags: [.bodyComposition]
        ),
        .init(
            key: "bodyTemperature", displayName: "Body temperature",
            source: .quantity(.celsius, .average), unitLabel: "°C", higherIsHealthier: nil,
            domain: .body, healthKitIdentifier: "HKQuantityTypeIdentifierBodyTemperature"
        ),
        .init(
            key: "basalBodyTemperature", displayName: "Basal body temperature",
            source: .quantity(.celsius, .average), unitLabel: "°C", higherIsHealthier: nil,
            domain: .body, healthKitIdentifier: "HKQuantityTypeIdentifierBasalBodyTemperature"
        ),
        .init(
            key: "bloodGlucose", displayName: "Blood glucose",
            source: .quantity(.milligramsPerDeciliter, .average), unitLabel: "mg/dL",
            higherIsHealthier: nil, domain: .body,
            healthKitIdentifier: "HKQuantityTypeIdentifierBloodGlucose"
        ),

        // MARK: Mobility

        .init(
            key: "walkingSpeed", displayName: "Walking speed",
            source: .quantity(.metersPerSecond, .average), unitLabel: "m/s", higherIsHealthier: true,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierWalkingSpeed"
        ),
        .init(
            key: "walkingStepLength", displayName: "Step length",
            source: .quantity(.centimeters, .average), unitLabel: "cm", higherIsHealthier: nil,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierWalkingStepLength"
        ),
        .init(
            key: "walkingAsymmetryPercentage", displayName: "Walking asymmetry",
            source: .quantity(.percent, .average), unitLabel: "%", higherIsHealthier: false,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierWalkingAsymmetryPercentage"
        ),
        .init(
            key: "walkingDoubleSupportPercentage", displayName: "Double support time",
            source: .quantity(.percent, .average), unitLabel: "%", higherIsHealthier: false,
            domain: .mobility,
            healthKitIdentifier: "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage"
        ),
        .init(
            key: "stairAscentSpeed", displayName: "Stair ascent speed",
            source: .quantity(.metersPerSecond, .average), unitLabel: "m/s", higherIsHealthier: true,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierStairAscentSpeed"
        ),
        .init(
            key: "stairDescentSpeed", displayName: "Stair descent speed",
            source: .quantity(.metersPerSecond, .average), unitLabel: "m/s", higherIsHealthier: true,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierStairDescentSpeed"
        ),
        .init(
            key: "sixMinuteWalkTestDistance", displayName: "Six-minute walk distance",
            source: .quantity(.meters, .average), unitLabel: "m", higherIsHealthier: true,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierSixMinuteWalkTestDistance"
        ),
        .init(
            key: "appleWalkingSteadiness", displayName: "Walking steadiness",
            source: .quantity(.percent, .average), unitLabel: "%", higherIsHealthier: true,
            domain: .mobility, healthKitIdentifier: "HKQuantityTypeIdentifierAppleWalkingSteadiness"
        ),

        // MARK: Hearing

        .init(
            key: "headphoneAudioExposure", displayName: "Headphone audio",
            source: .quantity(.decibels, .average), unitLabel: "dB", higherIsHealthier: false,
            domain: .audio, healthKitIdentifier: "HKQuantityTypeIdentifierHeadphoneAudioExposure"
        ),
        .init(
            key: "environmentalAudioExposure", displayName: "Environmental sound",
            source: .quantity(.decibels, .average), unitLabel: "dB", higherIsHealthier: false,
            domain: .audio, healthKitIdentifier: "HKQuantityTypeIdentifierEnvironmentalAudioExposure"
        ),

        // MARK: Nutrition

        .init(
            key: "dietaryEnergyConsumed", displayName: "Dietary energy",
            source: .quantity(.kilocalorie, .sum), unitLabel: "kcal", higherIsHealthier: nil,
            domain: .nutrition, healthKitIdentifier: "HKQuantityTypeIdentifierDietaryEnergyConsumed"
        ),
        .init(
            key: "dietaryWater", displayName: "Water", source: .quantity(.milliliters, .sum),
            unitLabel: "mL", higherIsHealthier: true, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryWater"
        ),
        .init(
            key: "dietaryProtein", displayName: "Protein", source: .quantity(.grams, .sum),
            unitLabel: "g", higherIsHealthier: nil, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryProtein"
        ),
        .init(
            key: "dietaryCarbohydrates", displayName: "Carbohydrates", source: .quantity(.grams, .sum),
            unitLabel: "g", higherIsHealthier: nil, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryCarbohydrates"
        ),
        .init(
            key: "dietaryFatTotal", displayName: "Total fat", source: .quantity(.grams, .sum),
            unitLabel: "g", higherIsHealthier: nil, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryFatTotal"
        ),
        .init(
            key: "dietaryFatSaturated", displayName: "Saturated fat", source: .quantity(.grams, .sum),
            unitLabel: "g", higherIsHealthier: nil, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryFatSaturated"
        ),
        .init(
            key: "dietaryFiber", displayName: "Fiber", source: .quantity(.grams, .sum),
            unitLabel: "g", higherIsHealthier: true, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryFiber"
        ),
        .init(
            key: "dietarySugar", displayName: "Sugar", source: .quantity(.grams, .sum),
            unitLabel: "g", higherIsHealthier: false, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietarySugar"
        ),
        .init(
            key: "dietarySodium", displayName: "Sodium", source: .quantity(.milligrams, .sum),
            unitLabel: "mg", higherIsHealthier: nil, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietarySodium"
        ),
        .init(
            key: "dietaryCholesterol", displayName: "Dietary cholesterol",
            source: .quantity(.milligrams, .sum), unitLabel: "mg", higherIsHealthier: nil,
            domain: .nutrition, healthKitIdentifier: "HKQuantityTypeIdentifierDietaryCholesterol"
        ),
        .init(
            key: "dietaryCaffeine", displayName: "Caffeine", source: .quantity(.milligrams, .sum),
            unitLabel: "mg", higherIsHealthier: nil, domain: .nutrition,
            healthKitIdentifier: "HKQuantityTypeIdentifierDietaryCaffeine"
        ),
        .init(
            key: "numberOfAlcoholicBeverages", displayName: "Alcoholic drinks",
            source: .quantity(.count, .sum), unitLabel: "drinks", higherIsHealthier: false,
            domain: .nutrition, healthKitIdentifier: "HKQuantityTypeIdentifierNumberOfAlcoholicBeverages"
        ),

        // MARK: Sleep, mindfulness & environment

        .init(
            key: "sleepDurationHours", displayName: "Sleep duration", source: .sleepHours,
            unitLabel: "h", higherIsHealthier: nil, domain: .sleep
        ),
        .init(
            key: "mindfulMinutes", displayName: "Mindful minutes", source: .mindfulMinutes,
            unitLabel: "min", higherIsHealthier: true, domain: .mindfulness
        ),
        .init(
            key: "timeInDaylight", displayName: "Time in daylight", source: .quantity(.minutes, .sum),
            unitLabel: "min", higherIsHealthier: true, domain: .environment,
            healthKitIdentifier: "HKQuantityTypeIdentifierTimeInDaylight"
        )
    ]

    /// Key → descriptor lookup — the resolve behind `MetricKey.init?(rawValue:)`.
    static let byKey: [String: MetricDescriptor] = Dictionary(
        uniqueKeysWithValues: table.map { ($0.key, $0) }
    )

    /// Every registered key as a `MetricKey`, in table (domain-grouped) order.
    static let orderedKeys: [MetricKey] = table.map { MetricKey(registryKey: $0.key) }
}
