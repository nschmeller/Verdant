# Verdant HealthKit Metric Catalog

> **Status: historical research artifact.** This table records the HealthKit unit/aggregation
> research behind the metric set — it is not the source of truth and is not kept in step with the
> code. `Domain/MetricRegistry.swift` is the single table the app actually reads, and
> `MetricRegistryTests` validates it against the real HealthKit SDK on every run: every identifier
> resolves to a real type, every unit is compatible with that type, keys are unique, and
> authorization covers every registered source. Trust those over anything below.
>
> Two columns here describe things the app no longer has. `redFlag` belongs to a clinical
> red-flag tier that was **removed** — the regulatory posture is wellness/informational, and a
> notably high reading is an ordinary material change for the agents to reason about, never a
> diagnosis. `swiftCase` predates `MetricKey` becoming a registry-backed struct rather than an
> enum; metrics are added by appending a row to the registry table, not by adding a case.

All verifier verdicts confirmed the researched unit/aggregation (every `correctedUnitSwift`/`correctedAggregation` echoed the proposal), so no overrides were needed. No duplicate `hkIdentifier`s were present. Two metrics were dropped for `dailyTrendSuitable=false`.

## 1. Final recommended set (daily-trend-suitable)

| swiftCase | hkIdentifier | kind | displayName | unitSwift | unitLabel | aggregation | higherIsHealthier | redFlag |
|---|---|---|---|---|---|---|---|---|
| stepCount | HKQuantityTypeIdentifier.stepCount | quantity | Steps | `.count()` | steps | sum | true | — |
| distanceWalkingRunning | HKQuantityTypeIdentifier.distanceWalkingRunning | quantity | Walking + Running Distance | `HKUnit.meter()` | km | sum | true | — |
| distanceCycling | HKQuantityTypeIdentifier.distanceCycling | quantity | Cycling Distance | `HKUnit.meter()` | km | sum | true | — |
| distanceWheelchair | HKQuantityTypeIdentifier.distanceWheelchair | quantity | Wheelchair Distance | `HKUnit.meter()` | km | sum | true | — |
| pushCount | HKQuantityTypeIdentifier.pushCount | quantity | Pushes | `.count()` | pushes | sum | true | — |
| flightsClimbed | HKQuantityTypeIdentifier.flightsClimbed | quantity | Flights Climbed | `.count()` | flights | sum | true | — |
| activeEnergyBurned | HKQuantityTypeIdentifier.activeEnergyBurned | quantity | Active Energy | `HKUnit.kilocalorie()` | kcal | sum | true | — |
| basalEnergyBurned | HKQuantityTypeIdentifier.basalEnergyBurned | quantity | Resting Energy | `HKUnit.kilocalorie()` | kcal | sum | nil | — |
| appleExerciseTime | HKQuantityTypeIdentifier.appleExerciseTime | quantity | Exercise Minutes | `HKUnit.minute()` | min | sum | true | — |
| appleStandTime | HKQuantityTypeIdentifier.appleStandTime | quantity | Stand Minutes | `HKUnit.minute()` | min | sum | true | — |
| appleMoveTime | HKQuantityTypeIdentifier.appleMoveTime | quantity | Move Minutes | `HKUnit.minute()` | min | sum | true | — |
| distanceSwimming | HKQuantityTypeIdentifier.distanceSwimming | quantity | Swimming Distance | `HKUnit.meter()` | m | sum | true | — |
| swimmingStrokeCount | HKQuantityTypeIdentifier.swimmingStrokeCount | quantity | Swimming Strokes | `.count()` | strokes | sum | nil | — |
| distanceDownhillSnowSports | HKQuantityTypeIdentifier.distanceDownhillSnowSports | quantity | Downhill Snow Sports Distance | `HKUnit.meter()` | km | sum | nil | — |
| distancePaddleSports | HKQuantityTypeIdentifier.distancePaddleSports | quantity | Paddle Sports Distance | `HKUnit.meter()` | km | sum | nil | — |
| distanceRowing | HKQuantityTypeIdentifier.distanceRowing | quantity | Rowing Distance | `HKUnit.meter()` | km | sum | nil | — |
| distanceCrossCountrySkiing | HKQuantityTypeIdentifier.distanceCrossCountrySkiing | quantity | Cross-Country Skiing Distance | `HKUnit.meter()` | km | sum | nil | — |
| distanceSkatingSports | HKQuantityTypeIdentifier.distanceSkatingSports | quantity | Skating Sports Distance | `HKUnit.meter()` | km | sum | nil | — |
| heartRate | HKQuantityTypeIdentifier.heartRate | quantity | Heart Rate | `HKUnit.count().unitDivided(by: .minute())` | bpm | average | nil | — |
| restingHeartRate | HKQuantityTypeIdentifier.restingHeartRate | quantity | Resting Heart Rate | `HKUnit.count().unitDivided(by: .minute())` | bpm | average | false | RHR >100 bpm (tachy) or <40 bpm w/o athletic context — CLINICAL REVIEW |
| walkingHeartRateAverage | HKQuantityTypeIdentifier.walkingHeartRateAverage | quantity | Walking Heart Rate Average | `HKUnit.count().unitDivided(by: .minute())` | bpm | average | false | — |
| heartRateVariabilitySDNN | HKQuantityTypeIdentifier.heartRateVariabilitySDNN | quantity | Heart Rate Variability (SDNN) | `HKUnit.secondUnit(with: .milli)` | ms | average | true | — |
| vo2Max | HKQuantityTypeIdentifier.vo2Max | quantity | VO2 Max | `HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))` | mL/kg·min | average | true | <~14 (men)/~13 (women) mL/kg·min — CLINICAL REVIEW |
| respiratoryRate | HKQuantityTypeIdentifier.respiratoryRate | quantity | Respiratory Rate | `HKUnit.count().unitDivided(by: .minute())` | breaths/min | average | nil | Resting <8 or >24 breaths/min — CLINICAL REVIEW |
| oxygenSaturation | HKQuantityTypeIdentifier.oxygenSaturation | quantity | Blood Oxygen (SpO2) | `HKUnit.percent()` | % | average | true | Sustained <0.90 (90%) — CLINICAL REVIEW |
| appleSleepingWristTemperature | HKQuantityTypeIdentifier.appleSleepingWristTemperature | quantity | Wrist Temperature (Sleeping) | `HKUnit.degreeCelsius()` | degC | average | nil | — |
| appleSleepingBreathingDisturbances | HKQuantityTypeIdentifier.appleSleepingBreathingDisturbances | quantity | Breathing Disturbances (Sleep) | `HKUnit.count()` | count | average | false | Persistently elevated — possible sleep apnea (defer to Apple thresholds) |
| bodyMass | HKQuantityTypeIdentifier.bodyMass | quantity | Weight | `.gramUnit(with: .kilo)` | kg | average | nil | — |
| bodyMassIndex | HKQuantityTypeIdentifier.bodyMassIndex | quantity | Body Mass Index | `.count()` | BMI | average | nil | BMI <16 or >40 — CLINICAL REVIEW |
| bodyFatPercentage | HKQuantityTypeIdentifier.bodyFatPercentage | quantity | Body Fat Percentage | `.percent()` | % | average | nil | — |
| leanBodyMass | HKQuantityTypeIdentifier.leanBodyMass | quantity | Lean Body Mass | `.gramUnit(with: .kilo)` | kg | average | true | — |
| waistCircumference | HKQuantityTypeIdentifier.waistCircumference | quantity | Waist Circumference | `.meterUnit(with: .centi)` | cm | average | false | — |
| walkingSpeed | HKQuantityTypeIdentifier.walkingSpeed | quantity | Walking Speed | `HKUnit.meterUnit().unitDivided(by: .secondUnit())` | m/s | average | true | — |
| walkingStepLength | HKQuantityTypeIdentifier.walkingStepLength | quantity | Walking Step Length | `HKUnit.meterUnitWithMetricPrefix(.centi)` | cm | average | nil | — |
| walkingAsymmetryPercentage | HKQuantityTypeIdentifier.walkingAsymmetryPercentage | quantity | Walking Asymmetry | `HKUnit.percent()` | % | average | false | Sustained >0.50 (50%) — possible gait impairment, CLINICAL REVIEW |
| walkingDoubleSupportPercentage | HKQuantityTypeIdentifier.walkingDoubleSupportPercentage | quantity | Double Support Time | `HKUnit.percent()` | % | average | false | — |
| stairAscentSpeed | HKQuantityTypeIdentifier.stairAscentSpeed | quantity | Stair Ascent Speed | `HKUnit.meterUnit().unitDivided(by: .secondUnit())` | m/s | average | true | — |
| stairDescentSpeed | HKQuantityTypeIdentifier.stairDescentSpeed | quantity | Stair Descent Speed | `HKUnit.meterUnit().unitDivided(by: .secondUnit())` | m/s | average | true | — |
| sixMinuteWalkTestDistance | HKQuantityTypeIdentifier.sixMinuteWalkTestDistance | quantity | Six-Minute Walk Distance | `HKUnit.meterUnit()` | m | average | true | Trending <~300 m — cardiopulmonary/mobility, CLINICAL REVIEW |
| environmentalAudioExposure | HKQuantityTypeIdentifier.environmentalAudioExposure | quantity | Environmental Sound Levels | `HKUnit.decibelAWeightedSoundPressureLevelUnit()` | dBASPL | average | false | — |
| headphoneAudioExposure | HKQuantityTypeIdentifier.headphoneAudioExposure | quantity | Headphone Audio Levels | `HKUnit.decibelAWeightedSoundPressureLevelUnit()` | dBASPL | average | false | 7-day avg >~80 dBA (WHO) — hearing-loss risk, CLINICAL REVIEW |
| dietaryEnergyConsumed | HKQuantityTypeIdentifier.dietaryEnergyConsumed | quantity | Dietary Energy | `.kilocalorie()` | kcal | sum | nil | — |
| dietaryWater | HKQuantityTypeIdentifier.dietaryWater | quantity | Water | `.literUnit(with: .milli)` | mL | sum | true | — |
| dietaryProtein | HKQuantityTypeIdentifier.dietaryProtein | quantity | Protein | `.gram()` | g | sum | nil | — |
| dietaryCarbohydrates | HKQuantityTypeIdentifier.dietaryCarbohydrates | quantity | Carbohydrates | `.gram()` | g | sum | nil | — |
| dietaryFatTotal | HKQuantityTypeIdentifier.dietaryFatTotal | quantity | Total Fat | `.gram()` | g | sum | nil | — |
| dietaryFatSaturated | HKQuantityTypeIdentifier.dietaryFatSaturated | quantity | Saturated Fat | `.gram()` | g | sum | false | — |
| dietaryFiber | HKQuantityTypeIdentifier.dietaryFiber | quantity | Fiber | `.gram()` | g | sum | true | — |
| dietarySugar | HKQuantityTypeIdentifier.dietarySugar | quantity | Sugar | `.gram()` | g | sum | false | — |
| dietarySodium | HKQuantityTypeIdentifier.dietarySodium | quantity | Sodium | `.gramUnit(with: .milli)` | mg | sum | false | — |
| dietaryCholesterol | HKQuantityTypeIdentifier.dietaryCholesterol | quantity | Dietary Cholesterol | `.gramUnit(with: .milli)` | mg | sum | false | — |
| dietaryCaffeine | HKQuantityTypeIdentifier.dietaryCaffeine | quantity | Caffeine | `.gramUnit(with: .milli)` | mg | sum | nil | Sustained >~400 mg/day — CLINICAL REVIEW |
| sleepDurationHours | HKCategoryTypeIdentifier.sleepAnalysis | sleepHours | Sleep Duration | n/a (category; sum asleep-sample durations) | h | sum | nil | — |
| mindfulMinutes | HKCategoryTypeIdentifier.mindfulSession | category | Mindful Minutes | n/a (category; sum session durations) | min | sum | true | — |

53 metrics retained.

## 2. Distinct unit "kinds" for the UnitKind enum

These are the distinct measurement kinds across the suitable set (category-derived ones are handled outside HKUnit):

| UnitKind | HKUnit Swift expression | label |
|---|---|---|
| count | `HKUnit.count()` | (steps / pushes / flights / strokes / BMI / count — bare count) |
| distanceMeters | `HKUnit.meter()` | km or m (display choice per metric) |
| energyKilocalories | `HKUnit.kilocalorie()` | kcal |
| durationMinutes | `HKUnit.minute()` | min |
| frequencyPerMinute | `HKUnit.count().unitDivided(by: .minute())` | bpm / breaths/min |
| timeMilliseconds | `HKUnit.secondUnit(with: .milli)` | ms |
| vo2Max | `HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))` | mL/kg·min |
| percent | `HKUnit.percent()` | % (stores 0.0–1.0 fraction; ×100 for display) |
| temperatureCelsius | `HKUnit.degreeCelsius()` | degC |
| massKilograms | `HKUnit.gramUnit(with: .kilo)` | kg |
| lengthCentimeters | `HKUnit.meterUnit(with: .centi)` | cm |
| speedMetersPerSecond | `HKUnit.meterUnit().unitDivided(by: .secondUnit())` | m/s |
| soundPressureLevel | `HKUnit.decibelAWeightedSoundPressureLevelUnit()` | dBASPL |
| volumeMilliliters | `HKUnit.literUnit(with: .milli)` | mL |
| massGrams | `HKUnit.gram()` | g |
| massMilligrams | `HKUnit.gramUnit(with: .milli)` | mg |

16 HKUnit-backed kinds, plus two non-HKUnit category-derived kinds:
- `sleepHours` — derived by summing asleep-sample durations, displayed as h.
- `mindfulMinutes` — derived by summing session durations, displayed as min.

Notes on consolidation: `distanceMeters` and `lengthCentimeters` are both meter-dimensioned but kept separate because waist circumference / step length store and display at the centi prefix while distances stay at base meter. `massGrams`, `massMilligrams`, `massKilograms` are all gram-dimensioned — you could collapse to one `mass` kind carrying a display prefix if you prefer fewer cases.

## 3. Authorization read-set (HKObjectType expressions)

All 51 suitable quantity types + the 2 category types, plus a few common extras worth requesting. Guard iOS 18+ types (`distancePaddleSports`, `distanceRowing`, `distanceCrossCountrySkiing`, `distanceSkatingSports`, `appleSleepingBreathingDisturbances`) with availability checks before adding.

```swift
let readTypes: Set<HKObjectType> = [
    // Activity
    HKQuantityType.quantityType(forIdentifier: .stepCount)!,
    HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
    HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
    HKQuantityType.quantityType(forIdentifier: .distanceWheelchair)!,
    HKQuantityType.quantityType(forIdentifier: .pushCount)!,
    HKQuantityType.quantityType(forIdentifier: .flightsClimbed)!,
    HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
    HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned)!,
    HKQuantityType.quantityType(forIdentifier: .appleExerciseTime)!,
    HKQuantityType.quantityType(forIdentifier: .appleStandTime)!,
    HKQuantityType.quantityType(forIdentifier: .appleMoveTime)!,
    HKQuantityType.quantityType(forIdentifier: .distanceSwimming)!,
    HKQuantityType.quantityType(forIdentifier: .swimmingStrokeCount)!,
    HKQuantityType.quantityType(forIdentifier: .distanceDownhillSnowSports)!,
    HKQuantityType.quantityType(forIdentifier: .distancePaddleSports)!,          // iOS 18+
    HKQuantityType.quantityType(forIdentifier: .distanceRowing)!,                // iOS 18+
    HKQuantityType.quantityType(forIdentifier: .distanceCrossCountrySkiing)!,    // iOS 18+
    HKQuantityType.quantityType(forIdentifier: .distanceSkatingSports)!,         // iOS 18+

    // Heart & cardio
    HKQuantityType.quantityType(forIdentifier: .heartRate)!,
    HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
    HKQuantityType.quantityType(forIdentifier: .walkingHeartRateAverage)!,
    HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
    HKQuantityType.quantityType(forIdentifier: .vo2Max)!,

    // Respiratory / vitals
    HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!,
    HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!,
    HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature)!,
    HKQuantityType.quantityType(forIdentifier: .appleSleepingBreathingDisturbances)!, // iOS 18+

    // Body
    HKQuantityType.quantityType(forIdentifier: .bodyMass)!,
    HKQuantityType.quantityType(forIdentifier: .bodyMassIndex)!,
    HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage)!,
    HKQuantityType.quantityType(forIdentifier: .leanBodyMass)!,
    HKQuantityType.quantityType(forIdentifier: .waistCircumference)!,

    // Mobility / gait
    HKQuantityType.quantityType(forIdentifier: .walkingSpeed)!,
    HKQuantityType.quantityType(forIdentifier: .walkingStepLength)!,
    HKQuantityType.quantityType(forIdentifier: .walkingAsymmetryPercentage)!,
    HKQuantityType.quantityType(forIdentifier: .walkingDoubleSupportPercentage)!,
    HKQuantityType.quantityType(forIdentifier: .stairAscentSpeed)!,
    HKQuantityType.quantityType(forIdentifier: .stairDescentSpeed)!,
    HKQuantityType.quantityType(forIdentifier: .sixMinuteWalkTestDistance)!,

    // Audio exposure
    HKQuantityType.quantityType(forIdentifier: .environmentalAudioExposure)!,
    HKQuantityType.quantityType(forIdentifier: .headphoneAudioExposure)!,

    // Nutrition
    HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryWater)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryProtein)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryFatTotal)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryFatSaturated)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryFiber)!,
    HKQuantityType.quantityType(forIdentifier: .dietarySugar)!,
    HKQuantityType.quantityType(forIdentifier: .dietarySodium)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryCholesterol)!,
    HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine)!,

    // Category types
    HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
    HKCategoryType.categoryType(forIdentifier: .mindfulSession)!,

    // Common extras worth requesting (not analyzed, but high-value)
    HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,        // for age-adjusted norms
    HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,      // sex-dependent thresholds (body fat, VO2 max)
    HKObjectType.characteristicType(forIdentifier: .height)!,             // BMI / context
    HKObjectType.workoutType(),                                          // attribute distances/energy to sessions
    HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic)!,  // if BP UI added later
    HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
    HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!,
]
```

Note: `dateOfBirth`/`biologicalSex`/`height` are characteristic types — read them via `HKHealthStore.dateOfBirthComponents()` etc., not statistics queries. They are requested through the same authorization read-set.

## 4. Excluded types

| swiftCase | hkIdentifier | reason |
|---|---|---|
| bodyTemperature | HKQuantityTypeIdentifier.bodyTemperature | Episodic manual/third-party entry only, no continuous Apple capture; most days empty, daily mean is sparse/noisy and distorts a trend (surface raw readings instead). |
| basalBodyTemperature | HKQuantityTypeIdentifier.basalBodyTemperature | Reproductive-health metric; single waking manual entry for cycle tracking, frequently absent — best shown as raw points in a cycle context, not a daily trend. |

No duplicates were found, so none were dropped for deduplication.

## 5. Metrics where unit/aggregation is still uncertain (flag for review)

The verifier confirmed all units/aggregations, but flagged real-but-out-of-schema modeling nuances. These are technically correct as listed yet need a deliberate implementation decision:

1. **heartRate** — true aggregationStyle is *Discrete (Temporally Weighted)*, not plain arithmetic. Listed as `average`, but for an accurate daily mean use HealthKit's temporally-weighted statistic (`HKStatisticsQuery` discreteAverage handles weighting), not a hand-rolled arithmetic mean over irregularly-spaced samples.

2. **restingHeartRate / walkingHeartRateAverage** — also *Temporally Weighted* discrete; same temporally-weighted-average caveat. In practice ~1 value/day so impact is minor.

3. **environmentalAudioExposure / headphoneAudioExposure** — true aggregationStyle is *Discrete (Equivalent Continuous Level, Leq / IEC 61672-1)*, not arithmetic. dBASPL is logarithmic, so a plain arithmetic daily mean understates exposure. Bucketed as `average` because the schema only allows sum/average and it is decidedly not a sum — but use `HKStatisticsQuery`'s discreteEquivalentContinuousLevel option (or label the value an approximation), not arithmetic mean.

4. **appleSleepingBreathingDisturbances** — unit is `count` but it is *Discrete (Arithmetic)*, NOT cumulative; it is a per-night level, so it must be averaged, never summed. Easy to get wrong because the `count` unit implies a tally — flagging so it isn't accidentally summed.

5. **oxygenSaturation / bodyFatPercentage / walkingAsymmetryPercentage / walkingDoubleSupportPercentage** — `HKUnit.percent()` stores a **0.0–1.0 fraction**, not 0–100. Multiply by 100 for display only. Red-flag thresholds above are expressed in fraction terms (e.g. SpO2 0.90). Not "uncertain" but a silent-corruption hazard worth a second look in display code.

6. **vo2Max** — verify Swift operator precedence in the compound unit expression: division must apply to the grouped `(kg * min)` denominator. The expression as written (`...unitDivided(by: gram(.kilo).unitMultiplied(by: .minute()))`) is correct; just confirm it isn't refactored into `... / kg * min`.

No metric has an unresolved sum-vs-average or wrong-unit conflict; the items above are correct-but-needs-careful-implementation flags.
