import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Query private var agentStates: [AgentState]
    @State private var confirmingDelete = false
    @State private var requestingAccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section("On-device intelligence") {
                    LabeledContent("Status", value: capabilityText)
                    if let state = agentStates.first {
                        LabeledContent(
                            "Last analyzed",
                            value: state.lastRunAt.formatted(.relative(presentation: .named))
                        )
                    }
                }

                if model.healthAccessPending {
                    Section {
                        // Tappable on purpose: re-runs the same check-then-request flow as
                        // foregrounding, so the user can bring the permission sheet back up RIGHT
                        // NOW instead of waiting for the next app switch. If everything gets
                        // granted, `healthAccessPending` clears and this section disappears —
                        // that vanishing is the success feedback.
                        Button {
                            requestingAccess = true
                            Task {
                                await model.ensureHealthAccess()
                                requestingAccess = false
                            }
                        } label: {
                            Label {
                                Text("Some Health sources are awaiting permission — tap to grant")
                                    .foregroundStyle(.primary)
                            } icon: {
                                if requestingAccess {
                                    ProgressView()
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .disabled(requestingAccess)
                    } footer: {
                        Text(
                            "Tapping brings the permission sheet back up for the sources that have "
                                + "never been through it. You can also grant access anytime in the "
                                + "Health app under Sharing → Apps → Verdant. Sources without "
                                + "permission can't be read and are skipped."
                        )
                    }
                }

                Section {
                    ResourceMeterView()
                } header: {
                    Text("Device compute")
                } footer: {
                    Text(
                        "The Neural Engine bar is measured directly: the share of the window it names "
                            + "that the on-device model spent generating. Apple provides no public "
                            + "per-generation ANE utilization API, so how continuously it runs — plus "
                            + "thermal state — is the honest measure of how hard it's working."
                    )
                }

                Section {
                    LabeledContent("Last background data refresh", value: relativeOrNever(
                        BackgroundRunDiagnostics.lastRefresh
                    ))
                    LabeledContent("Last on-power analysis", value: relativeOrNever(
                        BackgroundRunDiagnostics.lastEnhance
                    ))
                } header: {
                    Text("Background activity")
                } footer: {
                    Text(
                        "iOS grants these windows on its own schedule. The on-power analysis requires "
                            + "external power and typically runs while the phone charges overnight; the "
                            + "everyday foreground catch-up covers you either way."
                    )
                }

                Section("Privacy") {
                    Label("All reasoning runs on this iPhone", systemImage: "iphone")
                    Label(
                        "Nothing leaves your device — not your health data, not the reasoning over it",
                        systemImage: "lock.shield"
                    )
                    Label(
                        "Findings stay on this device — encrypted, never copied to iCloud or backups",
                        systemImage: "externaldrive.badge.checkmark"
                    )
                }

                // Grouped by body system rather than one flat 30-item dump, so it's scannable and
                // shows the breadth of what Verdant reasons over.
                ForEach(MetricDomain.allCases, id: \.self) { domain in
                    let metrics = MetricKey.allCases.filter { $0.domain == domain }
                    if !metrics.isEmpty {
                        Section(domain.displayName) {
                            ForEach(metrics) { Text($0.displayName) }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete all findings", systemImage: "trash")
                    }
                } footer: {
                    Text(
                        "Permanently deletes every insight and connection Verdant has surfaced, and its "
                            + "memory of what it's already shown you. Your Apple Health data is untouched — "
                            + "Verdant can rediscover findings over time."
                    )
                }

                Section {
                    Text(
                        "Verdant surfaces patterns and associations in your own data — never causes, "
                            + "diagnoses, or treatments. It's for insight and curiosity, not medical "
                            + "guidance. Bring anything that concerns you to a clinician."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Delete all findings?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) {
                    Task { await model.deleteAllInsights() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func relativeOrNever(_ date: Date?) -> String {
        date.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet"
    }

    private var capabilityText: String {
        switch model.capability {
        case .available: "Ready"
        case .downloading: "Downloading the on-device model"
        case .notEnabled: "Turn on Apple Intelligence in Settings to enable findings"
        case .unavailableForever: "Not available — needs a device with Apple Intelligence"
        }
    }
}
