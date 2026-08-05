import Darwin
import Foundation
import Observation

/// Live device-compute sampling for the resource meter: per-core CPU, the app's own CPU share, memory
/// footprint, thermal state, and on-device inference activity. Everything here uses public API — Mach
/// host/task info for CPU and memory, `ProcessInfo` for thermals. Apple exposes **no public Neural
/// Engine utilization API**, so inference load is shown honestly as live generation activity
/// (`InferenceActivity`) plus thermal state, the system's indirect load signal.
///
/// `@MainActor`: sampled once a second while the meter is visible; each sample is a few microseconds
/// of syscalls, so running it on main is free and keeps the observation model trivial.
@MainActor
@Observable
final class ResourceMonitor {
    /// Busy fraction (0…1) per CPU core over the last sampling interval.
    private(set) var perCoreUsage: [Double] = []
    /// This app's own CPU usage, in units of one core (1.3 = 130% of a single core).
    private(set) var appCPU: Double = 0
    /// The app's physical memory footprint, in megabytes.
    private(set) var memoryFootprintMB: Double = 0
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// Generations in flight right now (serial execution ⇒ 1 means the ANE is actively generating).
    private(set) var generationsInFlight = 0
    /// Total model calls since launch — the agent odometer.
    private(set) var totalModelCalls = 0
    /// Fraction (0…1) of the last minute the on-device model spent actively generating — the
    /// measured Neural Engine duty cycle (utilization-within-a-generation isn't publicly readable,
    /// but WHEN the ANE is working, and how continuously, is exactly this).
    private(set) var neuralDutyCycle: Double = 0
    /// How much history the duty cycle above is actually averaged over. The window fills up over
    /// the first minute the meter is visible, and the app's rule is that what you read is literally
    /// what is happening — so the label says "last 20s" until it has earned "last minute".
    private(set) var dutyCycleSpanSeconds: Double = 0

    private var sampler: Task<Void, Never>?
    /// Previous per-core tick counters (user, system, nice, idle — flattened), for delta-based usage.
    private var previousTicks: [UInt64] = []
    /// Rolling samples of `InferenceActivity.busySeconds`, each STAMPED with the monotonic time it
    /// was taken. The stamp matters: this used to store bare values and treat "one sample" as "one
    /// second", but `Task.sleep(for: .seconds(1))` guarantees a floor, not a period — under load the
    /// interval stretches, and the app is designed to be under load. See `dutyCycle`.
    private var busySamples: [BusySample] = []

    /// One reading of the cumulative busy counter, with when it was taken.
    nonisolated struct BusySample: Equatable {
        /// Monotonic seconds (same clock as `InferenceActivity`, so differences are meaningful).
        let at: Double
        /// Cumulative seconds the model has spent generating since launch.
        let busy: Double
    }

    func start() {
        guard sampler == nil else { return }
        sample() // immediate first paint rather than a blank second
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                sample()
            }
        }
    }

    func stop() {
        sampler?.cancel()
        sampler = nil
    }

    private func sample() {
        perCoreUsage = Self.sampleCores(previous: &previousTicks)
        appCPU = Self.sampleAppCPU()
        memoryFootprintMB = Self.sampleMemoryMB()
        thermalState = ProcessInfo.processInfo.thermalState
        generationsInFlight = InferenceActivity.shared.inFlight
        totalModelCalls = InferenceActivity.shared.totalCalls

        // Duty cycle over (up to) the last minute — see `dutyCycle` for why the samples are stamped.
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        busySamples.append(BusySample(at: now, busy: InferenceActivity.shared.busySeconds))
        busySamples.removeAll { now - $0.at > Self.dutyCycleWindow }
        if let measured = Self.dutyCycle(busySamples) {
            neuralDutyCycle = measured
            dutyCycleSpanSeconds = (busySamples.last?.at ?? 0) - (busySamples.first?.at ?? 0)
        }
    }

    /// The window the duty cycle is averaged over.
    nonisolated static let dutyCycleWindow = 60.0

    /// Names the window the duty cycle is ACTUALLY averaged over.
    ///
    /// The meter said "last minute" from the moment it appeared, when it held a few seconds of
    /// history — a small lie on the one screen whose entire job is honest measurement, and against
    /// the rule the live feed follows: what you read is literally what is happening. That was fixed;
    /// this lives here, next to the window it reads, so the fix is testable and a regression to a
    /// flat "last minute" fails instead of quietly returning the lie.
    nonisolated static func dutyCycleWindowLabel(spanSeconds span: Double) -> String {
        span >= dutyCycleWindow - 1 ? "last minute" : "last \(Int(span.rounded()))s"
    }

    /// Fraction of the sampled window the model spent generating, or `nil` while there is too
    /// little history to say.
    ///
    /// Divides the busy-time delta by the MEASURED elapsed time between the oldest and newest
    /// samples, not by the sample count. Assuming one second per sample overstated the figure
    /// whenever the sampler drifted — and it drifts most when the device is busiest, which is
    /// exactly when this number is being read. A 1.5s actual interval reported 150% of the true
    /// duty cycle, clamped to a flat 100%: the meter for the app's whole purpose would have claimed
    /// a saturated Neural Engine while it idled a third of the time. Pure, so that is test-pinned.
    nonisolated static func dutyCycle(_ samples: [BusySample]) -> Double? {
        guard let oldest = samples.first, let newest = samples.last else { return nil }
        let span = newest.at - oldest.at
        guard span >= 1 else { return nil } // too short a base to divide by meaningfully
        return min(1, max(0, (newest.busy - oldest.busy) / span))
    }

    /// Per-core busy fractions from `host_processor_info` tick deltas (public Mach API).
    private nonisolated static func sampleCores(previous: inout [UInt64]) -> [Double] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount
        )
        guard result == KERN_SUCCESS, let infoArray else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: infoArray)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let stateMax = Int(CPU_STATE_MAX)
        var usages: [Double] = []
        var newTicks: [UInt64] = []
        newTicks.reserveCapacity(Int(cpuCount) * 4)
        for core in 0..<Int(cpuCount) {
            let base = core * stateMax
            // Tick counters are unsigned; reinterpret the signed integer_t bits.
            let user = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)]))
            newTicks.append(contentsOf: [user, system, nice, idle])

            let prevBase = core * 4
            if previous.count >= prevBase + 4 {
                let busy = Double((user &- previous[prevBase])
                    &+ (system &- previous[prevBase + 1])
                    &+ (nice &- previous[prevBase + 2]))
                let total = busy + Double(idle &- previous[prevBase + 3])
                usages.append(total > 0 ? min(1, busy / total) : 0)
            } else {
                usages.append(0) // first sample has no delta yet
            }
        }
        previous = newTicks
        return usages
    }

    /// The app's own CPU usage summed across its threads (units of one core), via `task_threads`.
    private nonisolated static func sampleAppCPU() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return 0 }
        defer {
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threadList[i])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
            }
        }
        return total
    }

    /// The app's physical memory footprint (the figure Xcode's memory gauge shows), via `task_vm_info`.
    private nonisolated static func sampleMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

nonisolated extension ProcessInfo.ThermalState {
    /// Human-facing label for the meter.
    var meterLabel: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair — warming up"
        case .serious: "Serious — heavy sustained load"
        case .critical: "Critical — throttled"
        @unknown default: "Unknown"
        }
    }
}
