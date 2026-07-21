import SwiftUI

struct RuntimeStateSettingsView: View {
    @ObservedObject var settings: RuntimeStateSettings
    @ObservedObject var session: TerminalSession
    @State private var confirmClearAll = false

    var body: some View {
        Form {
            Section("Prediction history") {
                configurationToggle(
                    "Remember prediction history",
                    isOn: $settings.predictionHistoryEnabled
                )
                configurationToggle(
                    "Persist history across app restarts",
                    isOn: $settings.persistenceEnabled
                )
                .disabled(!settings.predictionHistoryEnabled)

                Text(settings.persistenceEnabled
                    ? "Sanitized history is stored locally in Pane's Application Support folder."
                    : "Prediction can continue with memory-only history until Pane quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Collected categories") {
                storedCategory("Completed command text", detail: "Sanitized before collection")
                storedCategory("Exit status and duration", detail: "Stored")
                configurationToggle(
                    "Output and error summaries",
                    isOn: $settings.outputSummariesEnabled
                )
                configurationToggle(
                    "Working-directory paths",
                    isOn: $settings.filePathCollectionEnabled
                )
                storedCategory("Raw terminal output", detail: "Never stored")
                storedCategory("Environment-variable values", detail: "Never stored")
                storedCategory("Git metadata", detail: "Not collected")
                storedCategory("Typed or secure input", detail: "Never stored")
            }

            Section("Delete history") {
                Button("Clear Current Session History") {
                    session.clearCurrentSessionPredictionHistory()
                }
                Button("Clear Current Workspace History") {
                    session.clearCurrentWorkspacePredictionHistory()
                }
                .disabled(!settings.filePathCollectionEnabled)
                Button("Clear All Prediction History", role: .destructive) {
                    confirmClearAll = true
                }
            }

            if let diagnostic = session.runtimeStateDiagnostic {
                Section("Status") {
                    Label(diagnostic, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 590)
        .alert("Clear all prediction history?", isPresented: $confirmClearAll) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                session.clearAllPredictionHistory()
            }
        } message: {
            Text("This removes all saved and in-memory prediction history. It does not clear terminal scrollback or shell history.")
        }
    }

    private func configurationToggle(
        _ title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { value in
                isOn.wrappedValue = value
                session.applyRuntimeStateConfiguration(settings.configuration)
            }
        ))
    }

    private func storedCategory(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}
