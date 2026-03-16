import Foundation
import SwiftProtocol

public enum BridgeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

public struct BridgePermissions: Codable, Equatable, Sendable {
    public var allowExecRun: Bool
    public var allowWritesApplyPatch: Bool
    public var allowGitPush: Bool
    public var requireGitPushConfirmation: Bool
    public var allowClaudeRun: Bool
    public var allowNovaAct: Bool

    public init(
        allowExecRun: Bool = true,
        allowWritesApplyPatch: Bool = true,
        allowGitPush: Bool = false,
        requireGitPushConfirmation: Bool = true,
        allowClaudeRun: Bool = false,
        allowNovaAct: Bool = false
    ) {
        self.allowExecRun = allowExecRun
        self.allowWritesApplyPatch = allowWritesApplyPatch
        self.allowGitPush = allowGitPush
        self.requireGitPushConfirmation = requireGitPushConfirmation
        self.allowClaudeRun = allowClaudeRun
        self.allowNovaAct = allowNovaAct
    }
}

public struct ActiveCommandSnapshot: Equatable, Sendable {
    public let commandId: String
    public let command: String
    public let cwd: String
    public let state: BridgeExecState
    public let startedAt: String
    public let stdoutTail: String
    public let stderrTail: String

    public init(
        commandId: String,
        command: String,
        cwd: String,
        state: BridgeExecState,
        startedAt: String,
        stdoutTail: String,
        stderrTail: String
    ) {
        self.commandId = commandId
        self.command = command
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

public struct BridgeStatusSnapshot: Equatable, Sendable {
    public let connectionState: BridgeConnectionState
    public let paired: Bool
    public let pairingCode: String?
    public let deviceId: String
    public let workspaceRoot: String
    public let workspaceRoots: [String]
    public let lastExitCode: Int32?
    public let permissions: BridgePermissions
    public let activeCommand: ActiveCommandSnapshot?

    public init(
        connectionState: BridgeConnectionState,
        paired: Bool,
        pairingCode: String?,
        deviceId: String,
        workspaceRoot: String,
        workspaceRoots: [String],
        lastExitCode: Int32?,
        permissions: BridgePermissions,
        activeCommand: ActiveCommandSnapshot?
    ) {
        self.connectionState = connectionState
        self.paired = paired
        self.pairingCode = pairingCode
        self.deviceId = deviceId
        self.workspaceRoot = workspaceRoot
        self.workspaceRoots = workspaceRoots
        self.lastExitCode = lastExitCode
        self.permissions = permissions
        self.activeCommand = activeCommand
    }
}

public struct BridgeConfiguration: Sendable {
    public let serverURL: URL
    public let deviceId: String
    public var deviceName: String
    public var workspaceRoot: URL
    public var workspaceRoots: [URL]
    public var pairingCode: String?
    public var capabilities: BridgeCapabilities
    public var outputLimitBytes: Int
    public var commandOutputTailBytes: Int
    public var outputChunkBytes: Int
    public var permissions: BridgePermissions
    public var novaActApiKey: String?

    public init(
        serverURL: URL,
        deviceId: String = UUID().uuidString,
        deviceName: String,
        workspaceRoot: URL,
        workspaceRoots: [URL] = [],
        pairingCode: String? = nil,
        capabilities: BridgeCapabilities = BridgeCapabilities(),
        outputLimitBytes: Int = 24_000,
        commandOutputTailBytes: Int = 200_000,
        outputChunkBytes: Int = 4096,
        permissions: BridgePermissions = BridgePermissions(),
        novaActApiKey: String? = nil
    ) {
        self.serverURL = serverURL
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.workspaceRoot = workspaceRoot.standardizedFileURL

        var deduped = [workspaceRoot.standardizedFileURL]
        for root in workspaceRoots.map({ $0.standardizedFileURL }) where !deduped.contains(root) {
            deduped.append(root)
        }
        self.workspaceRoots = deduped

        self.pairingCode = pairingCode
        self.capabilities = capabilities
        self.outputLimitBytes = outputLimitBytes
        self.commandOutputTailBytes = commandOutputTailBytes
        self.outputChunkBytes = outputChunkBytes
        self.permissions = permissions
        self.novaActApiKey = novaActApiKey
    }
}

public struct CommandExecutionResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let cancelled: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool, cancelled: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

public enum BridgeCoreError: Error, LocalizedError {
    case invalidPayload(String)
    case unsupportedTool(String)
    case workspaceViolation(String)
    case permissionDenied(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let message):
            return "Invalid payload: \(message)"
        case .unsupportedTool(let name):
            return "Unsupported tool: \(name)"
        case .workspaceViolation(let path):
            return "Path outside allowed workspace roots: \(path)"
        case .permissionDenied(let reason):
            return "Permission denied: \(reason)"
        case .internalError(let message):
            return "Bridge internal error: \(message)"
        }
    }
}
