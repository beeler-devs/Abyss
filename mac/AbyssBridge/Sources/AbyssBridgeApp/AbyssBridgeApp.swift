import SwiftUI
import AppKit
import Security
import BridgeCore

@main
struct AbyssBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = BridgeAppModel()

    var body: some Scene {
        WindowGroup("AbyssBridge") {
            BridgeStatusView(model: model)
                .frame(minWidth: 720, minHeight: 620)
        }
        .defaultSize(width: 860, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)

        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }

        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                window.delegate = self
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct WorkspaceRecord: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var path: String
    var bookmarkData: Data?

    init(id: String = UUID().uuidString, path: String, bookmarkData: Data?) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

enum BridgePermissionPreset: String, CaseIterable, Identifiable {
    case restricted = "Restricted"
    case developer  = "Developer"
    case full       = "Full"
    case custom     = "Custom"
    var id: String { rawValue }
}

@MainActor
final class BridgeAppModel: ObservableObject {
    @Published var serverURLText: String
    @Published var connectionState: BridgeConnectionState = .disconnected
    @Published var pairingCode: String = ""
    @Published var paired = false
    @Published var deviceId: String = ""
    @Published var deviceName: String
    @Published var lastExitCode: Int32?
    @Published var statusMessage: String = ""
    @Published var activeCommand: ActiveCommandSnapshot?

    @Published var workspaces: [WorkspaceRecord] = []
    @Published var selectedWorkspaceId: String = ""

    @Published var allowExecRun = true
    @Published var allowWritesApplyPatch = true
    @Published var allowGitPush = false
    @Published var requireGitPushConfirmation = true
    @Published var allowClaudeRun = false
    @Published var allowNovaAct = false
    @Published var showNovaActSetup = false
    @Published var novaActApiKey: String = ""

    private var bridgeCore: BridgeCore?
    private let defaults = UserDefaults.standard
    private var securityScopedURLs: [URL] = []

    private static let serverURLKey = "bridge.serverURL"
    private static let deviceNameKey = "bridge.deviceName"
    private static let pairingCodeKey = "bridge.pairingCode"
    private static let deviceIdKey = "bridge.deviceId"
    private static let workspaceRecordsKey = "bridge.workspaceRecords"
    private static let selectedWorkspaceIdKey = "bridge.selectedWorkspaceId"

    private static let allowExecRunKey = "bridge.permissions.allowExecRun"
    private static let allowWritesApplyPatchKey = "bridge.permissions.allowWritesApplyPatch"
    private static let allowGitPushKey = "bridge.permissions.allowGitPush"
    private static let requireGitPushConfirmationKey = "bridge.permissions.requireGitPushConfirmation"
    private static let allowClaudeRunKey = "bridge.permissions.allowClaudeRun"
    private static let allowNovaActKey = "bridge.permissions.allowNovaAct"

    private static let keychainService = "app.abyss.bridge"
    private static let novaActApiKeyAccount = "nova_act_api_key"

    private let stableDeviceId: String

    init() {
        if let existing = defaults.string(forKey: Self.deviceIdKey) {
            self.stableDeviceId = existing
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: Self.deviceIdKey)
            self.stableDeviceId = newId
        }

        self.serverURLText = defaults.string(forKey: Self.serverURLKey) ?? "ws://localhost:8080/ws"
        self.deviceName = defaults.string(forKey: Self.deviceNameKey) ?? Host.current().localizedName ?? "Abyss Mac"
        self.pairingCode = defaults.string(forKey: Self.pairingCodeKey) ?? ""

        self.allowExecRun = defaults.object(forKey: Self.allowExecRunKey) as? Bool ?? true
        self.allowWritesApplyPatch = defaults.object(forKey: Self.allowWritesApplyPatchKey) as? Bool ?? true
        self.allowGitPush = defaults.object(forKey: Self.allowGitPushKey) as? Bool ?? false
        self.requireGitPushConfirmation = defaults.object(forKey: Self.requireGitPushConfirmationKey) as? Bool ?? true
        self.allowClaudeRun = defaults.object(forKey: Self.allowClaudeRunKey) as? Bool ?? false
        self.allowNovaAct = defaults.object(forKey: Self.allowNovaActKey) as? Bool ?? false
        self.novaActApiKey = Self.loadKeychainString(account: Self.novaActApiKeyAccount) ?? ""

        restoreWorkspaces()
        bootstrapBridgeCore()
    }

    deinit {
        Task { [bridgeCore] in
            await bridgeCore?.stop()
        }

        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    var selectedWorkspacePath: String {
        selectedWorkspace?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var connectionStateLabel: String {
        switch connectionState {
        case .connected:    return paired ? "connected" : "not paired"
        case .connecting:   return "connecting"
        case .disconnected: return "disconnected"
        }
    }

    var onlineLabel: String {
        if connectionState == .connected && paired {
            return "online"
        }
        return "offline"
    }

    func reconnect() {
        persistConfiguration()
        Task {
            await bridgeCore?.stop()
            bootstrapBridgeCore()
        }
    }

    func generatePairingCode() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        pairingCode = String((0..<6).map { _ in alphabet.randomElement()! })
        defaults.set(pairingCode, forKey: Self.pairingCodeKey)
        statusMessage = "Pairing code generated."

        Task {
            await bridgeCore?.updatePairingCode(pairingCode)
        }
    }

    func copyPairingCode() {
        guard !pairingCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
        statusMessage = "Pairing code copied."
    }

    func addWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a workspace root for AbyssBridge"

        if panel.runModal() != .OK || panel.url == nil {
            return
        }

        guard let selectedURL = panel.url?.standardizedFileURL else { return }
        let path = selectedURL.path

        if workspaces.contains(where: { $0.path == path }) {
            selectedWorkspaceId = workspaces.first(where: { $0.path == path })?.id ?? selectedWorkspaceId
            statusMessage = "Workspace already added."
            persistWorkspaces()
            reconnect()
            return
        }

        do {
            let bookmark = try selectedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let _ = selectedURL.startAccessingSecurityScopedResource()
            securityScopedURLs.append(selectedURL)

            let record = WorkspaceRecord(path: path, bookmarkData: bookmark)
            workspaces.append(record)
            selectedWorkspaceId = record.id
            statusMessage = "Workspace added."
            persistWorkspaces()
            reconnect()
        } catch {
            statusMessage = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    func removeWorkspace(id: String) {
        guard workspaces.count > 1 else { return }
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceId == id {
            selectedWorkspaceId = workspaces.first?.id ?? ""
        }
        persistWorkspaces()
        reconnect()
    }

    var currentPreset: BridgePermissionPreset {
        switch (allowExecRun, allowWritesApplyPatch, allowGitPush, allowClaudeRun, allowNovaAct) {
        case (false, false, false, false, false): return .restricted
        case (true,  true,  true,  true,  false): return .developer
        case (true,  true,  true,  true,  true):  return .full
        default:                                  return .custom
        }
    }

    func applyPreset(_ preset: BridgePermissionPreset) {
        switch preset {
        case .restricted:
            allowExecRun = false; allowWritesApplyPatch = false
            allowGitPush = false; allowClaudeRun = false; allowNovaAct = false
        case .developer:
            allowExecRun = true; allowWritesApplyPatch = true
            allowGitPush = true; allowClaudeRun = true; allowNovaAct = false
        case .full:
            allowExecRun = true; allowWritesApplyPatch = true
            allowGitPush = true; allowClaudeRun = true; allowNovaAct = true
        case .custom:
            return
        }
        applyPermissions()
    }

    func applyPermissions() {
        defaults.set(allowExecRun, forKey: Self.allowExecRunKey)
        defaults.set(allowWritesApplyPatch, forKey: Self.allowWritesApplyPatchKey)
        defaults.set(allowGitPush, forKey: Self.allowGitPushKey)
        defaults.set(requireGitPushConfirmation, forKey: Self.requireGitPushConfirmationKey)
        defaults.set(allowClaudeRun, forKey: Self.allowClaudeRunKey)
        defaults.set(allowNovaAct, forKey: Self.allowNovaActKey)

        statusMessage = "Permissions saved."
        Task {
            await bridgeCore?.updatePermissions(currentPermissions())
        }
    }

    func cancelActiveCommand() {
        Task {
            let cancelled = await bridgeCore?.cancelActiveCommand() ?? false
            statusMessage = cancelled ? "Cancel signal sent." : "No running command to cancel."
        }
    }

    private func bootstrapBridgeCore() {
        guard let url = URL(string: serverURLText) else {
            statusMessage = "Invalid server URL"
            return
        }

        let workspaceURLs = workspaceRootURLs()
        let selectedURL = workspaceURLs.first ?? FileManager.default.homeDirectoryForCurrentUser

        let config = BridgeConfiguration(
            serverURL: url,
            deviceId: stableDeviceId,
            deviceName: deviceName,
            workspaceRoot: selectedURL,
            workspaceRoots: workspaceURLs,
            pairingCode: pairingCode.isEmpty ? nil : pairingCode,
            permissions: currentPermissions(),
            novaActApiKey: novaActApiKey.isEmpty ? nil : novaActApiKey
        )

        let core = BridgeCore(configuration: config)
        bridgeCore = core

        Task {
            await core.setStatusHandler { [weak self] snapshot in
                Task { @MainActor in
                    self?.apply(snapshot: snapshot)
                }
            }
            await core.setLogHandler { [weak self] line in
                Task { @MainActor in
                    self?.statusMessage = line
                }
            }
            await core.setGitPushConfirmationHandler { [weak self] remote, branch in
                await self?.confirmGitPush(remote: remote, branch: branch) ?? false
            }
            await core.start()
        }
    }

    private func apply(snapshot: BridgeStatusSnapshot) {
        connectionState = snapshot.connectionState
        paired = snapshot.paired
        deviceId = snapshot.deviceId
        lastExitCode = snapshot.lastExitCode
        activeCommand = snapshot.activeCommand
    }

    private func persistConfiguration() {
        defaults.set(serverURLText, forKey: Self.serverURLKey)
        defaults.set(deviceName, forKey: Self.deviceNameKey)
        defaults.set(pairingCode, forKey: Self.pairingCodeKey)
        defaults.set(selectedWorkspaceId, forKey: Self.selectedWorkspaceIdKey)
        persistWorkspaces()
    }

    private func currentPermissions() -> BridgePermissions {
        BridgePermissions(
            allowExecRun: allowExecRun,
            allowWritesApplyPatch: allowWritesApplyPatch,
            allowGitPush: allowGitPush,
            requireGitPushConfirmation: requireGitPushConfirmation,
            allowClaudeRun: allowClaudeRun,
            allowNovaAct: allowNovaAct
        )
    }

    private var selectedWorkspace: WorkspaceRecord? {
        workspaces.first(where: { $0.id == selectedWorkspaceId })
    }

    private func workspaceRootURLs() -> [URL] {
        var urls: [URL] = []
        if let selected = selectedWorkspace {
            urls.append(URL(fileURLWithPath: selected.path))
        }
        for workspace in workspaces {
            let url = URL(fileURLWithPath: workspace.path)
            if !urls.contains(url) {
                urls.append(url)
            }
        }
        return urls
    }

    private func persistWorkspaces() {
        defaults.set(selectedWorkspaceId, forKey: Self.selectedWorkspaceIdKey)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(workspaces) {
            defaults.set(data, forKey: Self.workspaceRecordsKey)
        }
    }

    private func restoreWorkspaces() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Self.workspaceRecordsKey),
           let decoded = try? decoder.decode([WorkspaceRecord].self, from: data),
           !decoded.isEmpty {
            workspaces = decoded
            selectedWorkspaceId = defaults.string(forKey: Self.selectedWorkspaceIdKey) ?? decoded[0].id
            restoreSecurityScopedAccess(for: decoded)
            return
        }

        let fallback = WorkspaceRecord(path: FileManager.default.homeDirectoryForCurrentUser.path, bookmarkData: nil)
        workspaces = [fallback]
        selectedWorkspaceId = fallback.id
    }

    private func restoreSecurityScopedAccess(for records: [WorkspaceRecord]) {
        securityScopedURLs.removeAll()

        for record in records {
            guard let bookmarkData = record.bookmarkData else { continue }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                continue
            }

            if url.startAccessingSecurityScopedResource() {
                securityScopedURLs.append(url)
            }
        }
    }

    private func confirmGitPush(remote: String, branch: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Allow git push?"
            alert.informativeText = "Remote: \(remote)\nBranch: \(branch)"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            continuation.resume(returning: response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Nova Act API Key (Keychain)

    func saveNovaActApiKey() {
        guard !novaActApiKey.isEmpty else { return }
        Self.saveKeychainString(novaActApiKey, account: Self.novaActApiKeyAccount)
        Task {
            await bridgeCore?.updateNovaActApiKey(novaActApiKey)
        }
    }

    func clearNovaActApiKey() {
        novaActApiKey = ""
        Self.deleteKeychainString(account: Self.novaActApiKeyAccount)
        Task {
            await bridgeCore?.updateNovaActApiKey(nil)
        }
    }

    private static func saveKeychainString(_ value: String, account: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadKeychainString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychainString(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct BridgeStatusView: View {
    @ObservedObject var model: BridgeAppModel

    @State private var transientMessage: String? = nil
    @State private var transientTask: Task<Void, Never>? = nil

    private var connectionDotColor: Color {
        switch model.connectionState {
        case .connected:    return model.paired ? .green : .orange
        case .connecting:   return .yellow
        case .disconnected: return Color(nsColor: .systemGray)
        }
    }

    private func permissionSummary(_ m: BridgeAppModel) -> String {
        func mark(_ on: Bool) -> String { on ? "✓" : "✗" }
        return "Shell \(mark(m.allowExecRun))  Writes \(mark(m.allowWritesApplyPatch))  Git \(mark(m.allowGitPush))  Claude \(mark(m.allowClaudeRun))  Nova \(mark(m.allowNovaAct))"
    }

    private var visiblePresets: [BridgePermissionPreset] {
        var presets: [BridgePermissionPreset] = [.restricted, .developer, .full]
        if model.currentPreset == .custom {
            presets.append(.custom)
        }
        return presets
    }

    private var presetBinding: Binding<BridgePermissionPreset> {
        Binding(
            get: { model.currentPreset },
            set: { model.applyPreset($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Server URL") {
                        Text(model.serverURLText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Paired") {
                        Text(model.paired ? "Yes" : "No")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Online") {
                        Text(model.onlineLabel)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Device ID") {
                        Text(model.deviceId.isEmpty ? "Not assigned" : model.deviceId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Workspace") {
                        Text(model.selectedWorkspacePath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Last Exit Code") {
                        Text(model.lastExitCode.map(String.init) ?? "N/A")
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Workspaces")) {
                    ForEach(model.workspaces) { workspace in
                        HStack(spacing: 10) {
                            Button {
                                model.selectedWorkspaceId = workspace.id
                                model.reconnect()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: model.selectedWorkspaceId == workspace.id
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.selectedWorkspaceId == workspace.id
                                                         ? .blue : .secondary)
                                        .imageScale(.medium)
                                    Text(workspace.path)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                model.removeWorkspace(id: workspace.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.workspaces.count <= 1)
                        }
                        .padding(.vertical, 2)
                    }

                    HStack {
                        Button("Add Workspace…") { model.addWorkspace() }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }

                Section("Pairing") {
                    LabeledContent("Code") {
                        Text(model.pairingCode.isEmpty ? "—" : model.pairingCode)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Generate Code") { model.generatePairingCode() }
                            .buttonStyle(.bordered)
                        Button("Copy") { model.copyPairingCode() }
                            .buttonStyle(.bordered)
                            .disabled(model.pairingCode.isEmpty)
                        Spacer()
                    }
                }

                Section("Permissions") {
                    Text(permissionSummary(model))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    Picker("Preset", selection: presetBinding) {
                        ForEach(visiblePresets) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Section {
                        Toggle("Allow command execution", isOn: $model.allowExecRun)
                            .onChange(of: model.allowExecRun) { model.applyPermissions() }
                    } header: {
                        Label("Shell", systemImage: "terminal")
                    }

                    Section {
                        Toggle("Allow writes / apply patch / git stage+commit",
                               isOn: $model.allowWritesApplyPatch)
                            .onChange(of: model.allowWritesApplyPatch) { model.applyPermissions() }
                    } header: {
                        Label("Filesystem & Git Writes", systemImage: "folder.badge.gearshape")
                    }

                    Section {
                        Toggle("Allow git push", isOn: $model.allowGitPush)
                            .onChange(of: model.allowGitPush) { model.applyPermissions() }

                        Toggle("Require confirmation before push",
                               isOn: $model.requireGitPushConfirmation)
                            .onChange(of: model.requireGitPushConfirmation) { model.applyPermissions() }
                            .disabled(!model.allowGitPush)
                            .foregroundStyle(model.allowGitPush ? .primary : .tertiary)
                            .help(model.allowGitPush ? "" : "Requires: Allow git push")
                    } header: {
                        Label("Git Push", systemImage: "arrow.triangle.branch")
                    }

                    Section {
                        Toggle("Allow Claude Code (bridge.claude.run)",
                               isOn: $model.allowClaudeRun)
                            .onChange(of: model.allowClaudeRun) { model.applyPermissions() }

                        Toggle(isOn: Binding(
                            get: { model.allowNovaAct },
                            set: { newValue in
                                if newValue {
                                    model.showNovaActSetup = true
                                } else {
                                    model.allowNovaAct = false
                                    model.applyPermissions()
                                }
                            }
                        )) {
                            Label {
                                HStack(spacing: 6) {
                                    Text("Allow Nova Act (browser automation)")
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.red.opacity(0.8))
                                        .imageScale(.small)
                                }
                            } icon: {
                                EmptyView()
                            }
                        }
                        .help("High-risk: grants full browser automation access")
                    } header: {
                        Label("AI & Automation", systemImage: "cpu.fill")
                    }
                }

                Section("Active Command") {
                    if let active = model.activeCommand {
                        LabeledContent("Command ID") {
                            Text(active.commandId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        LabeledContent("State") {
                            Text(active.state.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("CWD") {
                            Text(active.cwd)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Started") {
                            Text(active.startedAt)
                                .foregroundStyle(.secondary)
                        }

                        Text(active.command)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ScrollView {
                            Text(active.stdoutTail + (active.stderrTail.isEmpty ? "" : "\n\n[stderr]\n" + active.stderrTail))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 100, maxHeight: 160)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                        Button("Cancel Active Command") {
                            model.cancelActiveCommand()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Label("No active command", systemImage: "terminal")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }
                }

                Section("Configuration") {
                    TextField("Server", text: $model.serverURLText)
                    TextField("Device Name", text: $model.deviceName)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .sheet(isPresented: $model.showNovaActSetup) {
                NovaActSetupSheet(model: model)
            }
            .onChange(of: model.statusMessage) {
                guard !model.statusMessage.isEmpty else { return }
                transientTask?.cancel()
                withAnimation(.easeInOut(duration: 0.15)) {
                    transientMessage = model.statusMessage
                }
                transientTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        transientMessage = nil
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            if let msg = transientMessage {
                                Text(msg)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            } else {
                                Circle()
                                    .fill(connectionDotColor)
                                    .frame(width: 8, height: 8)
                                Text(model.connectionStateLabel.capitalized)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            }
                        }
                        .animation(.easeInOut(duration: 0.15), value: transientMessage)
                    }
                    .buttonStyle(.bordered)
                    .allowsHitTesting(false)
                    .animation(.spring(duration: 0.25), value: transientMessage)
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 6) {
                        if model.pairingCode.isEmpty {
                            Button("Get Pairing Code") { model.generatePairingCode() }
                                .buttonStyle(.bordered)
                        }
                        Button("", systemImage: "arrow.clockwise") {
                            model.reconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

struct NovaActSetupSheet: View {
    @ObservedObject var model: BridgeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyInput: String = ""

    private var hasApiKey: Bool {
        !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasEnvVarKey: Bool {
        if let key = ProcessInfo.processInfo.environment["NOVA_ACT_API_KEY"], !key.isEmpty {
            return true
        }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Nova Act requires an API key to function. Enter your key below — it will be stored securely in Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.headline)

                    SecureField("Paste your Nova Act API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    if !model.novaActApiKey.isEmpty && apiKeyInput.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.small)
                            Text("Previously saved key found (\(model.novaActApiKey.prefix(8))…)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if hasEnvVarKey && apiKeyInput.isEmpty && model.novaActApiKey.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                                .imageScale(.small)
                            Text("NOVA_ACT_API_KEY environment variable detected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Stored securely in Keychain")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if !model.novaActApiKey.isEmpty {
                    Button("Clear Saved Key") {
                        model.clearNovaActApiKey()
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 440, minHeight: 260)
            .navigationTitle("Nova Act Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enable") {
                        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            model.novaActApiKey = trimmed
                            model.saveNovaActApiKey()
                        }
                        model.allowNovaAct = true
                        model.applyPermissions()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasApiKey && model.novaActApiKey.isEmpty && !hasEnvVarKey)
                }
            }
        }
    }
}
