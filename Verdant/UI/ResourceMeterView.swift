import SwiftUI

/// Live device-compute meter: per-core CPU bars, the app's own CPU share, memory footprint, thermal
/// state, and on-device inference activity. Honest by design: Apple exposes no public Neural Engine
/// utilization API, so the inference row shows live generation activity (the model reasoning right
/// now + total calls), with thermal state as the system's indirect load signal.
///
/// Plain content (no card/section chrome) so it embeds in both a `Form` section (Settings) and a
/// card on the Deep Analysis screen. Samples only while visible.
struct ResourceMeterView: View {
    @State private var monitor = ResourceMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            inferenceRow
            neuralEngineBar
            coreBars
            detailRows
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: Inference (the ANE proxy)

    private var inferenceRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(monitor.generationsInFlight > 0 ? Theme.brand : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)
            Text(monitor.generationsInFlight > 0 ? "Model reasoning now" : "Model idle")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("\(monitor.totalModelCalls) agent calls")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    /// The measured Neural Engine duty cycle: what share of the last minute the model spent
    /// actively generating. Per-generation ANE utilization has no public API, but when it runs and
    /// how continuously — the saturation the app aims for — is measured exactly.
    private var neuralEngineBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Neural Engine — generating time, \(dutyCycleWindowLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", monitor.neuralDutyCycle * 100))
                    .font(.caption.monospacedDigit())
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.brand.opacity(0.85))
                        .frame(width: max(3, geo.size.width * monitor.neuralDutyCycle))
                }
            }
            .frame(height: 8)
            .animation(.smooth(duration: 0.6), value: monitor.neuralDutyCycle)
        }
    }

    /// Names the window the figure is ACTUALLY averaged over. It said "last minute" from the
    /// moment the meter appeared, when it had a few seconds of history — a small lie on the one
    /// screen whose entire job is honest measurement, and the same rule the live feed follows: what
    /// you read is literally what is happening.
    private var dutyCycleWindowLabel: String {
        ResourceMonitor.dutyCycleWindowLabel(spanSeconds: monitor.dutyCycleSpanSeconds)
    }

    // MARK: Per-core CPU

    @ViewBuilder private var coreBars: some View {
        if !monitor.perCoreUsage.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(monitor.perCoreUsage.enumerated()), id: \.offset) { _, usage in
                        VStack(spacing: 2) {
                            GeometryReader { geo in
                                VStack {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Theme.brand.opacity(0.85))
                                        .frame(height: max(2, geo.size.height * usage))
                                }
                            }
                        }
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                        )
                    }
                }
                .animation(.smooth(duration: 0.6), value: monitor.perCoreUsage)
            }
        }
    }

    // MARK: Details

    private var detailRows: some View {
        VStack(spacing: 6) {
            row("This app's CPU", String(format: "%.0f%% of one core", monitor.appCPU * 100))
            row("Memory footprint", String(format: "%.0f MB", monitor.memoryFootprintMB))
            row("Thermal state", monitor.thermalState.meterLabel)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}
