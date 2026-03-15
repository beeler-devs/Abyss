import SwiftUI

/// Settings sheet for configuring app/network/provider options.
struct SettingsView: View {
    let pairedBridgeDevices: [PairedBridgeDevice]
    let bridgePairingMessage: String?
    let onPairComputer: ((String, String?) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @AppStorage("recordingMode") private var recordingModeRaw = RecordingMode.vadAuto.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("cursorAPIKey") private var cursorAPIKey = ""
    @AppStorage("cursorAgentModel") private var cursorAgentModel = ""
    @AppStorage("backendWSURL") private var backendWSURL = ""

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsLoadError: String? = nil

    @State private var showCursorAPIKeyModal = false
    @State private var cursorAPIKeyInput = ""
    @State private var showPairComputerSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("App") {
                    Picker(selection: $appAppearanceRaw) {
                        ForEach(AppAppearance.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    } label: {
                        Label("Appearance", systemImage: "sun.max")
                    }
                    .pickerStyle(.menu)
                }

                Section("Server") {
                    TextField("ws://host:8080/ws", text: $backendWSURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))

                    if backendWSURL.isEmpty {
                        Text("Using default from Secrets.plist or Info.plist.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if Config.backendWSURL != nil {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Invalid URL — must start with ws:// or wss://", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Recording") {
                    Picker("Input Mode", selection: $recordingModeRaw) {
                        Text("Hands-free (VAD)").tag(RecordingMode.vadAuto.rawValue)
                        Text("Push to Talk").tag(RecordingMode.pushToTalk.rawValue)
                    }
                    .pickerStyle(.segmented)

                    if recordingModeRaw == RecordingMode.vadAuto.rawValue {
                        Text("Hands-free mode streams microphone audio to the backend with Nova Sonic. Keep BACKEND_WS_URL pointed at a server with VOICE_PROVIDER=nova-sonic.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Push to Talk records locally, then sends the final transcript to Nova 2 Lite when you release.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    .pickerStyle(.menu)
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

                Section("Bridge") {
                    Button {
                        showPairComputerSheet = true
                    } label: {
                        Label("Pair Computer", systemImage: "desktopcomputer")
                    }

                    if let bridgePairingMessage, !bridgePairingMessage.isEmpty {
                        Text(bridgePairingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if pairedBridgeDevices.isEmpty {
                        Text("No paired computers yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pairedBridgeDevices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.deviceName)
                                    Text(device.deviceId)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(device.status)
                                    .font(.caption)
                                    .foregroundStyle(device.status == "online" ? .green : .secondary)
                            }
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
            .sheet(isPresented: $showPairComputerSheet) {
                PairComputerSheet { code, deviceName in
                    onPairComputer?(code, deviceName)
                    showPairComputerSheet = false
                }
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

private struct PairComputerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pairingCode = ""
    @State private var deviceName = ""

    let onSubmit: (String, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing Code") {
                    TextField("ABC123", text: $pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Display Name (Optional)") {
                    TextField("My Mac", text: $deviceName)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Pair Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        onSubmit(
                            pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                            deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
