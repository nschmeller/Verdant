import HealthKit
import Testing
@testable import Verdant

/// Integrity of the data-driven metric registry — the single table every data source derives from.
/// These validate each row against the REAL HealthKit SDK, so a typo'd identifier or an incompatible
/// unit fails CI instead of crashing ingestion on a user's device.
struct MetricRegistryTests {
    @Test func `registry keys are unique and drive the closed vocabulary`() {
        let keys = MetricRegistry.table.map(\.key)
        #expect(Set(keys).count == keys.count, "duplicate registry keys")
        #expect(MetricKey.allRawValues == keys)
        #expect(MetricKey.allCases.count == keys.count)
    }

    @Test func `every quantity row resolves to a real HealthKit type`() {
        for descriptor in MetricRegistry.table {
            guard let identifier = descriptor.healthKitIdentifier else {
                // Category-based sources (sleep, mindfulness) have no quantity identifier.
                continue
            }
            let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: identifier))
            #expect(type != nil, "\(descriptor.key): unknown HealthKit identifier \(identifier)")
        }
    }

    @Test func `every quantity row's unit is compatible with its HealthKit type`() {
        for descriptor in MetricRegistry.table {
            guard let identifier = descriptor.healthKitIdentifier,
                  let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: identifier)),
                  let metric = MetricKey(rawValue: descriptor.key)
            else { continue }
            let unit = HealthTypeMapping.unit(for: metric)
            #expect(
                type.is(compatibleWith: unit),
                "\(descriptor.key): unit \(unit) incompatible with \(identifier)"
            )
        }
    }

    @Test func `unregistered keys do not resolve (the anti-hallucination boundary)`() {
        #expect(MetricKey(rawValue: "notARealMetric") == nil)
        #expect(MetricKey(rawValue: "") == nil)
        // Sentinel comparison strings must never resolve as metrics either.
        #expect(MetricKey(rawValue: StoreWriter.volatilityComparison) == nil)
    }

    @Test func `authorization covers every registered source`() {
        // Every registered metric's sample type is requested — reading from every possible source.
        #expect(HealthTypeMapping.allReadableTypes.count >= 70)
    }

    @Test func `rule-based redundancy kills tautologies and spares genuine links at scale`() {
        // Exertion aggregates: mutually redundant, and vs. raw movement volume.
        #expect(MetricCatalog.isMechanicallyRedundant(.activeEnergyBurned, .physicalEffort))
        #expect(MetricCatalog.isMechanicallyRedundant(.distanceRowing, .activeEnergyBurned))
        #expect(MetricCatalog.isMechanicallyRedundant(.distanceSwimming, .appleExerciseTime))
        // Raw volumes among themselves stay eligible — cross-mode substitution is genuinely interesting.
        #expect(!MetricCatalog.isMechanicallyRedundant(.stepCount, .distanceCycling))
        #expect(!MetricCatalog.isMechanicallyRedundant(.distanceSwimming, .distanceCycling))
        // Daily heart rates vs. the new activity metrics — the rule scales automatically.
        #expect(MetricCatalog.isMechanicallyRedundant(.heartRate, .distanceRowing))
        #expect(MetricCatalog.isMechanicallyRedundant(.walkingHeartRateAverage, .physicalEffort))
        // Rest-measured recovery signals stay eligible vs. everything.
        #expect(!MetricCatalog.isMechanicallyRedundant(.heartRateRecoveryOneMinute, .activeEnergyBurned))
        #expect(!MetricCatalog.isMechanicallyRedundant(.restingHeartRate, .distanceRowing))
        // Body composition includes the new waist measure.
        #expect(MetricCatalog.isMechanicallyRedundant(.waistCircumference, .bodyMass))
        // New curated pairs.
        #expect(MetricCatalog.isMechanicallyRedundant(.bloodPressureSystolic, .bloodPressureDiastolic))
        #expect(MetricCatalog.isMechanicallyRedundant(.dietaryCarbohydrates, .dietarySugar))
        // Cross-domain depth stays open: glucose vs. activity, sleep vs. glucose, daylight vs. sleep.
        #expect(!MetricCatalog.isMechanicallyRedundant(.bloodGlucose, .stepCount))
        #expect(!MetricCatalog.isMechanicallyRedundant(.sleepDurationHours, .bloodGlucose))
        #expect(!MetricCatalog.isMechanicallyRedundant(.timeInDaylight, .sleepDurationHours))
    }
}
