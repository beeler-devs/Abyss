import SwiftUI

/// Settings sheet for configuring recording mode and API keys.
struct SettingsView: View {
    @Binding var recordingMode: RecordingMode
    @Binding var useServerConductor: Bool
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("cursorAPIKey") private var cursorAPIKey = ""
    @AppStorage("cursorAgentModel") private var cursorAgentModel = ""
    @AppStorage("elevenLabsVoiceId") private var voiceId = "21m00Tcm4TlvDq8ikWAM"
    @AppStorage("elevenLabsModelId") private var modelId = "eleven_turbo_v2_5"
    @State private var showCursorKey = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsLoadError: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appAppearanceRaw) {
                        ForEach(AppAppearance.allCases, id: \.rawValue) { mode in
                            Label(mode.displayName, systemImage: mode.iconName)
                                .tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
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

                Section("Conductor") {
                    Toggle("Use Server Conductor", isOn: $useServerConductor)
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
                        Text("API Key")
                        Spacer()
                        if Config.isCursorAPIKeyConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Not Set", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Group {
                        if showCursorKey {
                            TextField("Cursor API Key", text: $cursorAPIKey)
                        } else {
                            SecureField("Cursor API Key", text: $cursorAPIKey)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle("Show Key", isOn: $showCursorKey)

                    Picker("Default Model", selection: $cursorAgentModel) {
                        Text("Cursor's default").tag("")
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)

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
                    } else {
                        Text("Model used for agent.spawn when not specified by the assistant.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Refresh Models") { Task { await loadModels() } }
                        .font(.caption)
                        .disabled(isLoadingModels || !Config.isCursorAPIKeyConfigured)

                    Text("Used by agent tools: agent.spawn, agent.status, agent.cancel, agent.followup, and agent.list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: "Phase 2")
                    LabeledContent("Architecture", value: "Tool-Calling + WS Conductor")
                    LabeledContent("STT Engine", value: "WhisperKit")
                    LabeledContent("TTS Engine", value: "ElevenLabs")
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
