import Foundation
import HealthKit

/// Translates the domain's registry rows into concrete HealthKit types and units. The only place
/// HealthKit identifiers materialize, and fully registry-driven: adding a data source is one
/// `MetricRegistry` row — no switch here to extend (the `unit(for:)` switch maps physical *unit
/// kinds*, not metrics; it only grows when a genuinely new physical unit appears).
nonisolated enum HealthTypeMapping {
    static func quantityTypeIdentifier(for metric: MetricKey) -> HKQuantityTypeIdentifier? {
        metric.descriptor.healthKitIdentifier.map(HKQuantityTypeIdentifier.init(rawValue:))
    }

    static func sampleType(for metric: MetricKey) -> HKSampleType {
        if let id = quantityTypeIdentifier(for: metric) {
            return HKQuantityType(id)
        }
        // Only two metrics are HealthKit CATEGORY samples rather than quantities; everything else
        // returned above. The `default` this replaces mapped anything unrecognised to sleep
        // analysis, so a newly added category metric would have silently queried the wrong
        // HealthKit type and ingested someone's sleep as its own data.
        switch metric.source {
        case .mindfulMinutes: return HKCategoryType(.mindfulSession)
        case .sleepHours: return HKCategoryType(.sleepAnalysis)
        case .quantity:
            // Unreachable by construction: a `.quantity` metric returns above via its HealthKit
            // identifier, so arriving here means the registry row has none — a configuration error,
            // not a sleep metric. Preserves the previous fallback rather than trapping, since a
            // misconfigured row should degrade to reading nothing useful, not crash the app.
            return HKCategoryType(.sleepAnalysis)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func unit(for metric: MetricKey) -> HKUnit {
        switch metric.unitKind {
        case .count: .count()
        case .distanceMeters, .meters: .meter()
        case .kilocalorie: .kilocalorie()
        case .minutes: .minute()
        case .hours: .hour()
        case .perMinute: HKUnit.count().unitDivided(by: .minute())
        case .milliseconds: .secondUnit(with: .milli)
        case .vo2Max: HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .percent: .percent()
        case .celsius: .degreeCelsius()
        case .kilograms: .gramUnit(with: .kilo)
        case .centimeters: .meterUnit(with: .centi)
        case .metersPerSecond: HKUnit.meter().unitDivided(by: .second())
        case .decibels: .decibelAWeightedSoundPressureLevel()
        case .milliliters: .literUnit(with: .milli)
        case .grams: .gram()
        case .milligrams: .gramUnit(with: .milli)
        case .watts: .watt()
        case .millimetersOfMercury: .millimeterOfMercury()
        case .milligramsPerDeciliter: HKUnit.gramUnit(with: .milli)
            .unitDivided(by: .literUnit(with: .deci))
        case .mets: HKUnit.kilocalorie()
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        }
    }

    /// Read authorization for every registered source — derived wholly from the registry, so a new
    /// row is automatically requested on the next permission prompt.
    static var allReadableTypes: Set<HKObjectType> {
        Set(MetricKey.allCases.map { sampleType(for: $0) as HKObjectType })
    }
}
