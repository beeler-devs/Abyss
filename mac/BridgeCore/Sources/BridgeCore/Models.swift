import Foundation
import SwiftProtocol

public enum BridgeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

public struct BridgeStatusSnapshot: Equatable, Sendable {
    public let connectionState: BridgeConnectionState
    public let paired: Bool
    public let pairingCode: String?
    public let deviceId: String
    public let workspaceRoot: String
    public let lastExitCode: Int32?

    public init(
        connectionState: BridgeConnectionState,
        paired: Bool,
        pairingCode: String?,
        deviceId: String,
        workspaceRoot: String,
        lastExitCode: Int32?
    ) {
        self.connectionState = connectionState
        self.paired = paired
        self.pairingCode = pairingCode
        self.deviceId = deviceId
        self.workspaceRoot = workspaceRoot
        self.lastExitCode = lastExitCode
    }
}

public struct BridgeConfiguration: Sendable {
    public let serverURL: URL
    public let deviceId: String
    public var deviceName: String
    public var workspaceRoot: URL
    public var pairingCode: String?
    public var capabilities: BridgeCapabilities
    public var outputLimitBytes: Int

    public init(
        serverURL: URL,
        deviceId: String = UUID().uuidString,
        deviceName: String,
        workspaceRoot: URL,
        pairingCode: String? = nil,
        capabilities: BridgeCapabilities = BridgeCapabilities(execRun: true, readFile: true),
        outputLimitBytes: Int = 24_000
    ) {
        self.serverURL = serverURL
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.workspaceRoot = workspaceRoot
        self.pairingCode = pairingCode
        self.capabilities = capabilities
        self.outputLimitBytes = outputLimitBytes
    }
}

public struct CommandExecutionResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum BridgeCoreError: Error, LocalizedError {
    case invalidPayload(String)
    case unsupportedTool(String)
    case workspaceViolation(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let message):
            return "Invalid payload: \(message)"
        case .unsupportedTool(let name):
            return "Unsupported tool: \(name)"
        case .workspaceViolation(let path):
            return "Path outside workspace root: \(path)"
        case .internalError(let message):
            return "Bridge internal error: \(message)"
        }
    }
}
