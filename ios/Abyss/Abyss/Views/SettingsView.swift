import SwiftUI

/// Settings sheet for configuring recording mode and API keys.
struct SettingsView: View {
    @Binding var recordingMode: RecordingMode
    @Binding var useServerConductor: Bool
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("cursorAPIKey") private var cursorAPIKey = ""
    @AppStorage("elevenLabsVoiceId") private var voiceId = "21m00Tcm4TlvDq8ikWAM"
    @AppStorage("elevenLabsModelId") private var modelId = "eleven_turbo_v2_5"
    @AppStorage("cursorAgentModel") private var cursorAgentModel = ""

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsLoadError: String? = nil

    @State private var showCursorAPIKeyModal = false
    @State private var cursorAPIKeyInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("App") {
                    NavigationLink {
                        AppLanguagePickerView()
                    } label: {
                        Label("App language", systemImage: "globe")
                        Spacer()
                        Text("English")
                            .foregroundStyle(.secondary)
                    }

                    Picker(selection: $appAppearanceRaw) {
                        ForEach(AppAppearance.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        Label("Appearance", systemImage: "sun.max")
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $useServerConductor) {
                        Label("Use Server Conductor", systemImage: "server.rack")
                    }
                    .disabled(!Config.isBackendWSConfigured)

                    if Config.isBackendWSConfigured {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BACKEND_WS_URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Config.backendWSURLString ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Label("Set BACKEND_WS_URL in Secrets.plist or Info.plist to enable server mode.", systemImage: "network.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Recording Mode") {
                    Picker("Mode", selection: $recordingMode) {
                        Text("Tap to Toggle").tag(RecordingMode.tapToToggle)
                        Text("Press and Hold").tag(RecordingMode.pressAndHold)
                    }
                    .pickerStyle(.segmented)

                    switch recordingMode {
                    case .tapToToggle:
                        Label("Tap mic to start, tap again to stop", systemImage: "hand.tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .pressAndHold:
                        Label("Hold mic to record, release to stop", systemImage: "hand.tap.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("ElevenLabs TTS") {
                    HStack {
                        Text("API Key")
                        Spacer()
                        if Config.isElevenLabsAPIKeyConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Set", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    TextField("Voice ID", text: $voiceId)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Model ID", text: $modelId)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Cursor Cloud Agents") {
                    HStack {
                        if Config.isCursorAPIKeyConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Change key") {
                                cursorAPIKeyInput = cursorAPIKey
                                showCursorAPIKeyModal = true
                            }
                        } else {
                            Button("Enter API key") {
                                cursorAPIKeyInput = ""
                                showCursorAPIKeyModal = true
                            }
                        }
                    }

                    Picker("Default Model", selection: $cursorAgentModel) {
                        Text("Cursor's default").tag("")
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(!Config.isCursorAPIKeyConfigured)

                    if isLoadingModels {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading models…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = modelsLoadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !Config.isElevenLabsAPIKeyConfigured {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Setup Required", systemImage: "info.circle")
                                .font(.subheadline.bold())

                            Text("Create a file at ios/Abyss/Abyss/App/Secrets.plist with your ELEVENLABS_API_KEY. See README for details.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadModels() }
            .onChange(of: cursorAPIKey) { _, _ in Task { await loadModels() } }
            .sheet(isPresented: $showCursorAPIKeyModal) {
                CursorAPIKeyModalView(
                    apiKey: $cursorAPIKeyInput,
                    onSave: {
                        let trimmed = cursorAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            cursorAPIKey = trimmed
                        }
                        showCursorAPIKeyModal = false
                    },
                    onCancel: {
                        showCursorAPIKeyModal = false
                    }
                )
            }
        }
    }

    private func loadModels() async {
        guard Config.isCursorAPIKeyConfigured else {
            modelsLoadError = "Configure Cursor API Key first."
            return
        }
        isLoadingModels = true
        modelsLoadError = nil
        do {
            let response = try await CursorCloudAgentsClient().models()
            availableModels = response.models
            if !cursorAgentModel.isEmpty && !availableModels.contains(cursorAgentModel) {
                cursorAgentModel = ""
            }
        } catch {
            modelsLoadError = error.localizedDescription
        }
        isLoadingModels = false
    }
}

// MARK: - App Language Picker (placeholder for future localization)
private struct AppLanguagePickerView: View {
    @AppStorage("appLanguage") private var appLanguage = "en"

    var body: some View {
        Form {
            Picker("App language", selection: $appLanguage) {
                Text("English").tag("en")
            }
            .pickerStyle(.inline)
        }
        .navigationTitle("App language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Cursor API Key Modal
private struct CursorAPIKeyModalView: View {
    @Binding var apiKey: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Cursor API Key", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Cursor API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save key") {
                        onSave()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
