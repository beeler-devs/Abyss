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
            requireGitPushConfirmation: requireGitPushConfirmation
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Server URL", model.serverURLText)
                    statusRow("Connection", model.connectionStateLabel)
                    statusRow("Paired", model.paired ? "Yes" : "No")
                    statusRow("Online", model.onlineLabel)
                    statusRow("Device ID", model.deviceId.isEmpty ? "Not assigned" : model.deviceId)
                    statusRow("Selected Workspace", model.selectedWorkspacePath)
                    statusRow("Last Exit Code", model.lastExitCode.map(String.init) ?? "N/A")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Workspaces") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Active Workspace", selection: $model.selectedWorkspaceId) {
                        ForEach(model.workspaces) { workspace in
                            Text(workspace.path).tag(workspace.id)
                        }
                    }
                    .onChange(of: model.selectedWorkspaceId) { _ in
                        model.reconnect()
                    }

                    HStack {
                        Button("Add…") { model.addWorkspace() }
                        Button("Remove Selected") { model.removeSelectedWorkspace() }
                            .disabled(model.workspaces.count <= 1)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.workspaces) { workspace in
                                Text(workspace.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
            }

            GroupBox("Pairing") {
                HStack(spacing: 12) {
                    Text(model.pairingCode.isEmpty ? "(not generated)" : model.pairingCode)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .frame(minWidth: 120, alignment: .leading)

                    Button("Generate Pairing Code") {
                        model.generatePairingCode()
                    }
                    Button("Copy Code") {
                        model.copyPairingCode()
                    }
                    .disabled(model.pairingCode.isEmpty)
                }
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Allow command execution", isOn: $model.allowExecRun)
                        .onChange(of: model.allowExecRun) { _ in model.applyPermissions() }
                    Toggle("Allow writes / applyPatch / git stage+commit", isOn: $model.allowWritesApplyPatch)
                        .onChange(of: model.allowWritesApplyPatch) { _ in model.applyPermissions() }
                    Toggle("Allow git push", isOn: $model.allowGitPush)
                        .onChange(of: model.allowGitPush) { _ in model.applyPermissions() }
                    Toggle("Require confirmation for git push", isOn: $model.requireGitPushConfirmation)
                        .onChange(of: model.requireGitPushConfirmation) { _ in model.applyPermissions() }
                }
            }

            GroupBox("Active Command") {
                VStack(alignment: .leading, spacing: 8) {
                    if let active = model.activeCommand {
                        statusRow("Command ID", active.commandId)
                        statusRow("State", active.state.rawValue)
                        statusRow("CWD", active.cwd)
                        statusRow("Started", active.startedAt)

                        Text(active.command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("stdout / stderr tail")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            Text(active.stdoutTail + (active.stderrTail.isEmpty ? "" : "\n\n[stderr]\n" + active.stderrTail))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120, maxHeight: 180)

                        Button("Cancel Active Command") {
                            model.cancelActiveCommand()
                        }
                    } else {
                        Text("No active command")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Configuration") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Server")
                        TextField("ws://localhost:8080/ws", text: $model.serverURLText)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Device Name")
                        TextField("My Mac", text: $model.deviceName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("Reconnect") { model.reconnect() }
                        Spacer()
                    }
                }
            }

            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .frame(width: 140, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
