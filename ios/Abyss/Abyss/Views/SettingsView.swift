import SwiftUI

/// Settings sheet for configuring app/network/provider options.
struct SettingsView: View {
    let pairedBridgeDevices: [PairedBridgeDevice]
    let bridgePairingMessage: String?
    let onPairComputer: ((String, String?) -> Void)?
    @EnvironmentObject private var gmailAuthManager: GmailAuthManager
    @EnvironmentObject private var canvasManager: CanvasManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("recordingMode") private var recordingModeRaw = RecordingMode.vadAuto.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("cursorAPIKey") private var cursorAPIKey = ""
    @AppStorage("cursorAgentModel") private var cursorAgentModel = ""
    @AppStorage("backendWSURL") private var backendWSURL = ""

    @State private var showCursorAPIKeyModal = false
    @State private var cursorAPIKeyInput = ""
    @State private var showPairComputerSheet = false
    enum CanvasConnectStep: Identifiable {
        case instructions
        case pastePAT
        var id: String { String(describing: self) }
    }
    @State private var canvasConnectStep: CanvasConnectStep? = nil
    @State private var canvasBrowserURL: URL? = nil
    @State private var shouldOpenCanvasBrowser = false

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
                        ForEach(CursorModelRegistry.shared.models, id: \.modelId) { entry in
                            Text(entry.displayName).tag(entry.modelId)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Connections") {
                    // Gmail
                    if gmailAuthManager.isAuthenticated {
                        HStack {
                            Label("Gmail", systemImage: "envelope")
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button("Sign out") {
                                gmailAuthManager.signOut()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            Task { await gmailAuthManager.authenticate() }
                        } label: {
                            HStack {
                                Label("Gmail", systemImage: "envelope")
                                Spacer()
                                if gmailAuthManager.isAuthenticating {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Text("Connect")
                                        .font(.caption)
                                }
                            }
                        }
                        .disabled(gmailAuthManager.isAuthenticating)
                    }

                    if let error = gmailAuthManager.authError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    // Canvas
                    if canvasManager.isConnected {
                        HStack {
                            Label("Canvas", systemImage: "graduationcap")
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button("Sign out") {
                                canvasManager.disconnect()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            canvasConnectStep = .instructions
                        } label: {
                            HStack {
                                Label("Canvas", systemImage: "graduationcap")
                                Spacer()
                                Text("Connect")
                                    .font(.caption)
                            }
                        }
                    }

                    // Coming soon integrations
                    HStack {
                        Label("Notion", systemImage: "doc.text")
                        Spacer()
                        Text("Coming soon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Apple Health", systemImage: "heart.fill")
                        Spacer()
                        Text("Coming soon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Obsidian", systemImage: "cube")
                        Spacer()
                        Text("Coming soon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            .sheet(item: $canvasConnectStep, onDismiss: handleCanvasSheetDismiss) { step in
                switch step {
                case .instructions:
                    CanvasInstructionsView(
                        onOpenCanvas: {
                            shouldOpenCanvasBrowser = true
                            canvasConnectStep = nil
                        },
                        onCancel: {
                            canvasConnectStep = nil
                        }
                    )
                case .pastePAT:
                    CanvasTokenPasteView(
                        onSave: { token in
                            canvasManager.connect(token: token, baseURL: CanvasManager.defaultBaseURL)
                            canvasConnectStep = nil
                        },
                        onCancel: {
                            canvasConnectStep = nil
                        }
                    )
                }
            }
            .sheet(item: $canvasBrowserURL, onDismiss: {
                canvasConnectStep = .pastePAT
            }) { url in
                InAppBrowserView(url: url)
            }
        }
    }

    private func handleCanvasSheetDismiss() {
        if shouldOpenCanvasBrowser {
            shouldOpenCanvasBrowser = false
            canvasBrowserURL = URL(string: "https://canvas.cmu.edu/profile/settings")!
        }
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

// MARK: - Canvas Connect Flow

private struct CanvasInstructionsView: View {
    let onOpenCanvas: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("To connect your Canvas account, you'll need a Personal Access Token. Here's how:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        instructionRow(number: 1, text: "Tap **Open Canvas** below \u{2014} this will open your Canvas profile settings.")
                        instructionRow(number: 2, text: "Scroll to **Approved Integrations** and tap **+ New Access Token**.")
                        instructionRow(number: 3, text: "Enter a purpose (e.g. \u{201C}Abyss\u{201D}) and tap **Generate Token**.")
                        instructionRow(number: 4, text: "**Copy the token** \u{2014} you won\u{2019}t be able to see it again.")
                        instructionRow(number: 5, text: "Come back here and paste it in.")
                    }
                }
                .padding()
            }
            .navigationTitle("Connect Canvas LMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onOpenCanvas) {
                    Label("Open Canvas", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }

    private func instructionRow(number: Int, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.blue))
            Text(text)
                .font(.subheadline)
        }
    }
}

private struct CanvasTokenPasteView: View {
    @State private var token: String = ""
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste your Canvas access token")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField("Access Token", text: $token)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
            .navigationTitle("Canvas Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(token) }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
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
