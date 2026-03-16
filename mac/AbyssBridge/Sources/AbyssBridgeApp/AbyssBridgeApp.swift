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

        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
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

struct NovaActPrerequisite: Identifiable {
    let id: String
    let label: String
    let fixCommand: String
    var status: Status

    enum Status {
        case unchecked, checking
        case passed(String)
        case failed(String)
    }

    var isPassed: Bool {
        if case .passed = status { return true }
        return false
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
    @Published var novaActPrerequisites: [NovaActPrerequisite] = []
    @Published var novaActChecksRunning = false

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

    // MARK: - Nova Act Prerequisite Checks

    func runAllNovaActChecks() async {
        novaActChecksRunning = true
        novaActPrerequisites = [
            NovaActPrerequisite(id: "python3", label: "Python 3", fixCommand: "brew install python3", status: .checking),
            NovaActPrerequisite(id: "nova_act", label: "nova-act package", fixCommand: "python3 -m pip install nova-act", status: .checking),
            NovaActPrerequisite(id: "api_key", label: "NOVA_ACT_API_KEY", fixCommand: "export NOVA_ACT_API_KEY=\"your-key-here\"", status: .checking),
            NovaActPrerequisite(id: "chrome", label: "Google Chrome", fixCommand: "brew install --cask google-chrome", status: .checking),
        ]

        // Python check
        let pythonResult = await checkPython3()
        if let idx = novaActPrerequisites.firstIndex(where: { $0.id == "python3" }) {
            novaActPrerequisites[idx].status = pythonResult.status
        }

        // nova-act depends on Python
        if case .passed(let pythonPath) = pythonResult.status {
            let novaResult = await checkNovaActPackage(pythonPath: pythonPath)
            if let idx = novaActPrerequisites.firstIndex(where: { $0.id == "nova_act" }) {
                novaActPrerequisites[idx].status = novaResult
            }
        } else {
            if let idx = novaActPrerequisites.firstIndex(where: { $0.id == "nova_act" }) {
                novaActPrerequisites[idx].status = .failed("Requires Python 3")
            }
        }

        // API key check
        let apiKeyResult = checkApiKey()
        if let idx = novaActPrerequisites.firstIndex(where: { $0.id == "api_key" }) {
            novaActPrerequisites[idx].status = apiKeyResult
        }

        // Chrome check
        let chromeResult = checkChrome()
        if let idx = novaActPrerequisites.firstIndex(where: { $0.id == "chrome" }) {
            novaActPrerequisites[idx].status = chromeResult
        }

        novaActChecksRunning = false
    }

    private func checkPython3() async -> (status: NovaActPrerequisite.Status, path: String?) {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        // Check well-known paths first
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return (.passed(path), path)
            }
        }

        // Check PATH entries
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/python3"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return (.passed(candidate), candidate)
                }
            }
        }

        return (.failed("Not found"), nil)
    }

    private func checkNovaActPackage(pythonPath: String) async -> NovaActPrerequisite.Status {
        return await withCheckedContinuation { continuation in
            Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: pythonPath)
                proc.arguments = ["-c", "import nova_act; print(nova_act.__version__)"]

                var env = ProcessInfo.processInfo.environment
                env["PYTHONUNBUFFERED"] = "1"
                proc.environment = env

                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    if proc.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"
                        continuation.resume(returning: .passed("v\(version)"))
                    } else {
                        continuation.resume(returning: .failed("Not installed"))
                    }
                } catch {
                    continuation.resume(returning: .failed("Check failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func checkApiKey() -> NovaActPrerequisite.Status {
        if let key = ProcessInfo.processInfo.environment["NOVA_ACT_API_KEY"], !key.isEmpty {
            return .passed("Set (\(key.prefix(8))…)")
        }
        return .failed("Not set — must be set before launching app")
    }

    private func checkChrome() -> NovaActPrerequisite.Status {
        if FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") {
            return .passed("/Applications/Google Chrome.app")
        }
        return .failed("Not found")
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

    @State private var transientMessage: String? = nil
    @State private var transientTask: Task<Void, Never>? = nil
    @State private var novaActSetupConfirmed = false

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

                        Toggle(isOn: $model.allowNovaAct) {
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
                        .onChange(of: model.allowNovaAct) { oldValue, newValue in
                            if newValue && !oldValue {
                                model.showNovaActSetup = true
                                Task { await model.runAllNovaActChecks() }
                            } else {
                                model.applyPermissions()
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
            .sheet(isPresented: $model.showNovaActSetup, onDismiss: {
                if !novaActSetupConfirmed {
                    model.allowNovaAct = false
                }
                novaActSetupConfirmed = false
            }) {
                NovaActSetupSheet(model: model, confirmed: $novaActSetupConfirmed)
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
    @Binding var confirmed: Bool

    private var allPassed: Bool {
        model.novaActPrerequisites.allSatisfy(\.isPassed)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Nova Act requires Python 3, the nova-act package, an API key, and Google Chrome. Check that all prerequisites are met before enabling.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    VStack(spacing: 12) {
                        ForEach(model.novaActPrerequisites) { prereq in
                            PrerequisiteRow(prerequisite: prereq)
                        }
                    }
                    .padding(.horizontal)

                    HStack {
                        Button("Check Again") {
                            Task { await model.runAllNovaActChecks() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.novaActChecksRunning)

                        Spacer()
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Nova Act Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        confirmed = false
                        model.showNovaActSetup = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(allPassed ? "Done" : "Enable Anyway") {
                        confirmed = true
                        model.applyPermissions()
                        model.showNovaActSetup = false
                    }
                    .tint(allPassed ? nil : .orange)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

struct PrerequisiteRow: View {
    let prerequisite: NovaActPrerequisite

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(prerequisite.label)
                        .font(.body)
                    statusDetail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .failed = prerequisite.status {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prerequisite.fixCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy fix command")
                }
            }

            if case .failed = prerequisite.status {
                Text(prerequisite.fixCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch prerequisite.status {
        case .unchecked:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch prerequisite.status {
        case .unchecked:
            Text("Not checked")
        case .checking:
            Text("Checking…")
        case .passed(let detail):
            Text(detail)
        case .failed(let detail):
            Text(detail)
        }
    }
}
