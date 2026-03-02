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
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultSize(width: 640, height: 520)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)

        // Prevent windows from being destroyed on close — just hide them
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
        sender.orderOut(nil)  // Hide instead of close
        return false
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
    @Published var workspaceRootPath: String = ""
    @Published var lastExitCode: Int32?
    @Published var statusMessage: String = ""

    private var bridgeCore: BridgeCore?
    private let defaults = UserDefaults.standard

    private static let serverURLKey = "bridge.serverURL"
    private static let deviceNameKey = "bridge.deviceName"
    private static let pairingCodeKey = "bridge.pairingCode"
    private static let deviceIdKey = "bridge.deviceId"
    private static let workspaceBookmarkKey = "bridge.workspaceBookmark"
    private static let workspacePathKey = "bridge.workspacePath"

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

        if let restoredWorkspace = Self.restoreWorkspaceBookmark(from: defaults) {
            workspaceRootPath = restoredWorkspace.path
        } else {
            workspaceRootPath = defaults.string(forKey: Self.workspacePathKey) ?? FileManager.default.homeDirectoryForCurrentUser.path
        }

        bootstrapBridgeCore()
    }

    deinit {
        Task { [bridgeCore] in
            await bridgeCore?.stop()
        }
    }

    func bootstrapBridgeCore() {
        guard let url = URL(string: serverURLText) else {
            statusMessage = "Invalid server URL"
            return
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRootPath)
        let config = BridgeConfiguration(
            serverURL: url,
            deviceId: stableDeviceId,
            deviceName: deviceName,
            workspaceRoot: workspaceURL,
            pairingCode: pairingCode.isEmpty ? nil : pairingCode
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
            await core.start()
        }
    }

    func reconnect() {
        defaults.set(serverURLText, forKey: Self.serverURLKey)
        defaults.set(deviceName, forKey: Self.deviceNameKey)
        defaults.set(pairingCode, forKey: Self.pairingCodeKey)

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

    func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose a workspace root for AbyssBridge"

        if panel.runModal() != .OK || panel.url == nil {
            return
        }

        guard let selectedURL = panel.url else { return }
        workspaceRootPath = selectedURL.path
        defaults.set(workspaceRootPath, forKey: Self.workspacePathKey)

        do {
            let bookmark = try selectedURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.workspaceBookmarkKey)
        } catch {
            statusMessage = "Failed to save workspace bookmark: \(error.localizedDescription)"
        }

        Task {
            await bridgeCore?.updateWorkspaceRoot(selectedURL)
            reconnect()
        }
    }

    private func apply(snapshot: BridgeStatusSnapshot) {
        connectionState = snapshot.connectionState
        paired = snapshot.paired
        deviceId = snapshot.deviceId
        workspaceRootPath = snapshot.workspaceRoot
        lastExitCode = snapshot.lastExitCode
    }

    private static func restoreWorkspaceBookmark(from defaults: UserDefaults) -> URL? {
        guard let bookmark = defaults.data(forKey: Self.workspaceBookmarkKey) else {
            return nil
        }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }

        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}

struct BridgeStatusView: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("Server URL", model.serverURLText)
                    statusRow("Connection", model.connectionStateLabel)
                    statusRow("Paired", model.paired ? "Yes" : "No")
                    statusRow("Device ID", model.deviceId.isEmpty ? "Not assigned" : model.deviceId)
                    statusRow("Workspace Root", model.workspaceRootPath)
                    statusRow("Last Exit Code", model.lastExitCode.map(String.init) ?? "N/A")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text("Workspace")
                        Text(model.workspaceRootPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                        Spacer()
                        Button("Choose…") {
                            model.selectWorkspace()
                        }
                    }

                    HStack {
                        Button("Reconnect") {
                            model.reconnect()
                        }
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
                .frame(width: 120, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private extension BridgeAppModel {
    var connectionStateLabel: String {
        switch connectionState {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        }
    }
}
