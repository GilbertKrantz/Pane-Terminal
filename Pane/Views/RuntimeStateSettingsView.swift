import SwiftUI

struct RuntimeStateSettingsView: View {
    @ObservedObject var settings: RuntimeStateSettings
    @ObservedObject var session: TerminalSession
    @State private var confirmClearAll = false
    @State private var confirmClearPrevious = false
    @State private var confirmClearCommands = false
    @State private var confirmClearOutput = false

    var body: some View {
        Form {
            Section("Local session storage") {
                configurationToggle(
                    "Remember command and block history",
                    isOn: $settings.predictionHistoryEnabled
                )
                configurationToggle(
                    "Persist history across app restarts",
                    isOn: $settings.persistenceEnabled
                )
                .disabled(!settings.predictionHistoryEnabled)

                Text(settings.persistenceEnabled
                    ? "Allowed history is stored only in Pane's local Application Support folder. Pane does not upload commands, output, diagnostics, or crash data."
                    : "History remains memory-only until Pane quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Collected categories") {
                storedCategory("Command history", detail: "Optional; sensitive commands excluded")
                storedCategory("Block metadata", detail: "Stored locally")
                storedCategory("Exit status and duration", detail: "Stored locally")
                configurationToggle(
                    "Output and error summaries",
                    isOn: $settings.outputSummariesEnabled
                )
                configurationToggle(
                    "Working-directory paths",
                    isOn: $settings.filePathCollectionEnabled
                )
                storedCategory("Sanitized output excerpts", detail: settings.outputSummariesEnabled ? "Optional, enabled" : "Optional, disabled")
                storedCategory("Runtime state", detail: "Lifecycle only; no raw bytes")
                storedCategory("Application preferences", detail: "Stored locally")
                storedCategory("Raw terminal byte stream", detail: "Never stored")
                storedCategory("Environment-variable values", detail: "Never stored")
                storedCategory("Git metadata", detail: "Not collected")
                storedCategory("Typed or secure input", detail: "Never stored during secure input")
            }

            Section("Manage local data") {
                Button("Clear Current Session") {
                    session.clearCurrentSessionPredictionHistory()
                }
                Button("Clear Previous Sessions", role: .destructive) {
                    confirmClearPrevious = true
                }
                Button("Clear Exact Command History", role: .destructive) {
                    confirmClearCommands = true
                }
                Button("Clear Persisted Block Output", role: .destructive) {
                    confirmClearOutput = true
                }
                Button("Reveal Local Data Location") {
                    session.revealLocalDataLocation()
                }
                Button("Clear All Pane Data", role: .destructive) {
                    confirmClearAll = true
                }
            }

            if let diagnostic = session.runtimeStateDiagnostic {
                Section("Status") {
                    Label(diagnostic, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    if diagnostic.localizedCaseInsensitiveContains("recovery file") {
                        Button("Reveal Recovery File") { session.revealRecoveryFile() }
                        Button("Clear Recovery File", role: .destructive) { session.clearRecoveryFile() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .alert("Clear all Pane data?", isPresented: $confirmClearAll) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                session.clearAllPredictionHistory()
            }
        } message: {
            Text("This removes Pane's saved sessions, exact command history, persisted excerpts, runtime metadata, and in-memory blocks. It does not remove your shell's own history.")
        }
        .alert("Clear previous sessions?", isPresented: $confirmClearPrevious) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Previous Sessions", role: .destructive) { session.clearPreviousSessions() }
        } message: { Text("This removes restored blocks and metadata from sessions before the current shell.") }
        .alert("Clear exact command history?", isPresented: $confirmClearCommands) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Command History", role: .destructive) { session.clearExactCommandHistory() }
        } message: { Text("This removes exact rerunnable command text and its persisted block records.") }
        .alert("Clear persisted block output?", isPresented: $confirmClearOutput) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Output", role: .destructive) { session.clearPersistedBlockOutput() }
        } message: { Text("This removes all saved sanitized output and error excerpts while retaining eligible command metadata.") }
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
