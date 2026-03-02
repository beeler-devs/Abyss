import Foundation

public enum AbyssProtocol {
    public static let version = 1
}

public struct EventEnvelope: Codable, Sendable {
    public let id: String
    public let type: String
    public let timestamp: Date
    public let sessionId: String
    public let protocolVersion: Int
    public let payload: JSONValue

    public init(
        id: String,
        type: String,
        timestamp: Date = Date(),
        sessionId: String,
        protocolVersion: Int = AbyssProtocol.version,
        payload: JSONValue
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.protocolVersion = protocolVersion
        self.payload = payload
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct BridgePairRequestPayload: Codable, Sendable {
    public let pairingCode: String
    public let deviceName: String?

    public init(pairingCode: String, deviceName: String?) {
        self.pairingCode = pairingCode
        self.deviceName = deviceName
    }
}

public struct BridgeRegisterPayload: Codable, Sendable {
    public let pairingCode: String
    public let deviceId: String
    public let deviceName: String
    public let workspaceRoot: String
    public let capabilities: BridgeCapabilities
    public let protocolVersion: Int

    public init(
        pairingCode: String,
        deviceId: String,
        deviceName: String,
        workspaceRoot: String,
        capabilities: BridgeCapabilities,
        protocolVersion: Int = AbyssProtocol.version
    ) {
        self.pairingCode = pairingCode
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.workspaceRoot = workspaceRoot
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
    }
}

public struct BridgeCapabilities: Codable, Sendable {
    public let execRun: Bool
    public let readFile: Bool

    public init(execRun: Bool = true, readFile: Bool = true) {
        self.execRun = execRun
        self.readFile = readFile
    }
}

public struct ToolCallPayload: Codable, Sendable {
    public let callId: String
    public let name: String
    public let arguments: String

    public init(callId: String, name: String, arguments: String) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResultPayload: Codable, Sendable {
    public let callId: String
    public let result: String?
    public let error: String?

    public init(callId: String, result: String?, error: String?) {
        self.callId = callId
        self.result = result
        self.error = error
    }
}

public struct BridgeExecRunArguments: Codable, Sendable {
    public let deviceId: String?
    public let command: String
    public let cwd: String?
    public let timeoutSec: Int?

    public init(deviceId: String? = nil, command: String, cwd: String? = nil, timeoutSec: Int? = nil) {
        self.deviceId = deviceId
        self.command = command
        self.cwd = cwd
        self.timeoutSec = timeoutSec
    }
}

public struct BridgeExecRunResult: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct BridgeReadFileArguments: Codable, Sendable {
    public let deviceId: String?
    public let path: String

    public init(deviceId: String? = nil, path: String) {
        self.deviceId = deviceId
        self.path = path
    }
}

public struct BridgeReadFileResult: Codable, Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}
