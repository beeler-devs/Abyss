import SwiftUI
import AppKit
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
        case .connected: return "connected"
        case .connecting: return "connecting"
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
            persistWorkspaces()
            reconnect()
        } catch {
            statusMessage = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }
    }

    func removeSelectedWorkspace() {
        guard let selected = selectedWorkspace else { return }
        workspaces.removeAll { $0.id == selected.id }

        if workspaces.isEmpty {
            let fallback = WorkspaceRecord(path: FileManager.default.homeDirectoryForCurrentUser.path, bookmarkData: nil)
            workspaces = [fallback]
            selectedWorkspaceId = fallback.id
        } else if !workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            selectedWorkspaceId = workspaces[0].id
        }

        persistWorkspaces()
        reconnect()
    }

    func applyPermissions() {
        defaults.set(allowExecRun, forKey: Self.allowExecRunKey)
        defaults.set(allowWritesApplyPatch, forKey: Self.allowWritesApplyPatchKey)
        defaults.set(allowGitPush, forKey: Self.allowGitPushKey)
        defaults.set(requireGitPushConfirmation, forKey: Self.requireGitPushConfirmationKey)
        defaults.set(allowClaudeRun, forKey: Self.allowClaudeRunKey)

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
            permissions: currentPermissions()
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
            allowClaudeRun: allowClaudeRun
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
}

struct BridgeStatusView: View {
    @ObservedObject var model: BridgeAppModel

    private var connectionDotColor: Color {
        switch model.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return Color(nsColor: .systemGray)
        }
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
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Workspace") {
                        Text(model.selectedWorkspacePath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Last Exit Code") {
                        Text(model.lastExitCode.map(String.init) ?? "N/A")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Workspaces") {
                    Picker("Active Workspace", selection: $model.selectedWorkspaceId) {
                        ForEach(model.workspaces) { workspace in
                            Text(workspace.path).tag(workspace.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.selectedWorkspaceId) {
                        model.reconnect()
                    }

                    HStack(spacing: 8) {
                        Button("Add Workspace…") { model.addWorkspace() }
                        Button("Remove Selected") { model.removeSelectedWorkspace() }
                            .disabled(model.workspaces.count <= 1)
                        Spacer()
                    }

                    ForEach(model.workspaces) { workspace in
                        Text(workspace.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }

                Section("Pairing") {
                    LabeledContent("Code") {
                        Text(model.pairingCode.isEmpty ? "—" : model.pairingCode)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Generate Code") { model.generatePairingCode() }
                        Button("Copy") { model.copyPairingCode() }
                            .disabled(model.pairingCode.isEmpty)
                        Spacer()
                    }
                }

                Section("Permissions") {
                    Toggle("Allow command execution", isOn: $model.allowExecRun)
                        .onChange(of: model.allowExecRun) { model.applyPermissions() }
                    Toggle("Allow writes / apply patch / git stage+commit", isOn: $model.allowWritesApplyPatch)
                        .onChange(of: model.allowWritesApplyPatch) { model.applyPermissions() }
                    Toggle("Allow git push", isOn: $model.allowGitPush)
                        .onChange(of: model.allowGitPush) { model.applyPermissions() }
                    Toggle("Require git push confirmation", isOn: $model.requireGitPushConfirmation)
                        .onChange(of: model.requireGitPushConfirmation) { model.applyPermissions() }
                    Toggle("Allow Claude Code (bridge.claude.run)", isOn: $model.allowClaudeRun)
                        .onChange(of: model.allowClaudeRun) { model.applyPermissions() }
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
                        .buttonStyle(.glass)
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
                    LabeledContent("Server") {
                        TextField("ws://localhost:8080/ws", text: $model.serverURLText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                    }
                    LabeledContent("Device Name") {
                        TextField("My Mac", text: $model.deviceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Text("Abyss Bridge")
                            .font(.headline)
                            .fontWeight(.semibold)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(connectionDotColor)
                                .frame(width: 7, height: 7)
                            Text(model.connectionStateLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 6) {
                        if model.pairingCode.isEmpty {
                            Button("Get Pairing Code") { model.generatePairingCode() }
                                .buttonStyle(.glassProminent)
                        }
                        Button("", systemImage: "arrow.clockwise") {
                            model.reconnect()
                        }
                        .buttonStyle(.glass)
                    }
                }
            }

            if model.connectionState == .connected && !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }
}
