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

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }
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
    public let workspaceRoots: [String]?
    public let capabilities: BridgeCapabilities
    public let protocolVersion: Int

    public init(
        pairingCode: String,
        deviceId: String,
        deviceName: String,
        workspaceRoot: String,
        workspaceRoots: [String]? = nil,
        capabilities: BridgeCapabilities,
        protocolVersion: Int = AbyssProtocol.version
    ) {
        self.pairingCode = pairingCode
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.workspaceRoot = workspaceRoot
        self.workspaceRoots = workspaceRoots
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
    }
}

public struct BridgeCapabilities: Codable, Sendable {
    public var execRun: Bool
    public var readFile: Bool
    public var execStart: Bool
    public var execCancel: Bool
    public var execStatus: Bool
    public var execOutputEvents: Bool
    public var fsSearch: Bool
    public var fsReadRange: Bool
    public var fsApplyPatch: Bool
    public var gitStatus: Bool
    public var gitDiff: Bool
    public var gitStage: Bool
    public var gitCommit: Bool
    public var gitPush: Bool
    public var claudeRun: Bool
    public var novaAct: Bool

    public init(
        execRun: Bool = true,
        readFile: Bool = true,
        execStart: Bool = true,
        execCancel: Bool = true,
        execStatus: Bool = true,
        execOutputEvents: Bool = true,
        fsSearch: Bool = true,
        fsReadRange: Bool = true,
        fsApplyPatch: Bool = true,
        gitStatus: Bool = true,
        gitDiff: Bool = true,
        gitStage: Bool = true,
        gitCommit: Bool = true,
        gitPush: Bool = true,
        claudeRun: Bool = true,
        novaAct: Bool = true
    ) {
        self.execRun = execRun
        self.readFile = readFile
        self.execStart = execStart
        self.execCancel = execCancel
        self.execStatus = execStatus
        self.execOutputEvents = execOutputEvents
        self.fsSearch = fsSearch
        self.fsReadRange = fsReadRange
        self.fsApplyPatch = fsApplyPatch
        self.gitStatus = gitStatus
        self.gitDiff = gitDiff
        self.gitStage = gitStage
        self.gitCommit = gitCommit
        self.gitPush = gitPush
        self.claudeRun = claudeRun
        self.novaAct = novaAct
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

public struct BridgeExecStartArguments: Codable, Sendable {
    public let deviceId: String?
    public let command: String
    public let cwd: String?
    public let env: [String: String]?
    public let timeoutSec: Int?

    public init(
        deviceId: String? = nil,
        command: String,
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeoutSec: Int? = nil
    ) {
        self.deviceId = deviceId
        self.command = command
        self.cwd = cwd
        self.env = env
        self.timeoutSec = timeoutSec
    }
}

public struct BridgeExecStartResult: Codable, Sendable {
    public let commandId: String
    public let startedAt: String

    public init(commandId: String, startedAt: String) {
        self.commandId = commandId
        self.startedAt = startedAt
    }
}

public struct BridgeExecCancelArguments: Codable, Sendable {
    public let deviceId: String?
    public let commandId: String

    public init(deviceId: String? = nil, commandId: String) {
        self.deviceId = deviceId
        self.commandId = commandId
    }
}

public struct BridgeExecCancelResult: Codable, Sendable {
    public let cancelled: Bool

    public init(cancelled: Bool) {
        self.cancelled = cancelled
    }
}

public struct BridgeExecStatusArguments: Codable, Sendable {
    public let deviceId: String?
    public let commandId: String

    public init(deviceId: String? = nil, commandId: String) {
        self.deviceId = deviceId
        self.commandId = commandId
    }
}

public enum BridgeExecState: String, Codable, Sendable {
    case running
    case finished
    case failed
    case cancelled
    case timedOut = "timed_out"
}

public struct BridgeExecStatusResult: Codable, Sendable {
    public let state: BridgeExecState
    public let exitCode: Int32?

    public init(state: BridgeExecState, exitCode: Int32?) {
        self.state = state
        self.exitCode = exitCode
    }
}

public struct BridgeExecOutputSubscribeArguments: Codable, Sendable {
    public let deviceId: String?
    public let commandId: String

    public init(deviceId: String? = nil, commandId: String) {
        self.deviceId = deviceId
        self.commandId = commandId
    }
}

public struct BridgeExecOutputSubscribeResult: Codable, Sendable {
    public let subscribed: Bool

    public init(subscribed: Bool) {
        self.subscribed = subscribed
    }
}

public struct BridgeExecOutputEventPayload: Codable, Sendable {
    public let deviceId: String
    public let commandId: String
    public let stream: String
    public let chunk: String
    public let isFinal: Bool

    public init(deviceId: String, commandId: String, stream: String, chunk: String, isFinal: Bool) {
        self.deviceId = deviceId
        self.commandId = commandId
        self.stream = stream
        self.chunk = chunk
        self.isFinal = isFinal
    }
}

public struct BridgeExecFinishedEventPayload: Codable, Sendable {
    public let deviceId: String
    public let commandId: String
    public let exitCode: Int32
    public let stdoutTail: String
    public let stderrTail: String

    public init(deviceId: String, commandId: String, exitCode: Int32, stdoutTail: String, stderrTail: String) {
        self.deviceId = deviceId
        self.commandId = commandId
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
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

public struct BridgeSearchArguments: Codable, Sendable {
    public let deviceId: String?
    public let query: String
    public let root: String?
    public let globs: [String]?
    public let maxResults: Int?

    public init(
        deviceId: String? = nil,
        query: String,
        root: String? = nil,
        globs: [String]? = nil,
        maxResults: Int? = nil
    ) {
        self.deviceId = deviceId
        self.query = query
        self.root = root
        self.globs = globs
        self.maxResults = maxResults
    }
}

public struct BridgeSearchMatch: Codable, Sendable {
    public let path: String
    public let line: Int
    public let snippet: String

    public init(path: String, line: Int, snippet: String) {
        self.path = path
        self.line = line
        self.snippet = snippet
    }
}

public struct BridgeSearchResult: Codable, Sendable {
    public let matches: [BridgeSearchMatch]

    public init(matches: [BridgeSearchMatch]) {
        self.matches = matches
    }
}

public struct BridgeReadRangeArguments: Codable, Sendable {
    public let deviceId: String?
    public let path: String
    public let startLine: Int
    public let endLine: Int

    public init(deviceId: String? = nil, path: String, startLine: Int, endLine: Int) {
        self.deviceId = deviceId
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct BridgeReadRangeResult: Codable, Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

public struct BridgeApplyPatchConstraints: Codable, Sendable {
    public let allowedPaths: [String]?
    public let noReformat: Bool?
    public let maxDiffLines: Int?

    public init(allowedPaths: [String]? = nil, noReformat: Bool? = nil, maxDiffLines: Int? = nil) {
        self.allowedPaths = allowedPaths
        self.noReformat = noReformat
        self.maxDiffLines = maxDiffLines
    }
}

public struct BridgeApplyPatchArguments: Codable, Sendable {
    public let deviceId: String?
    public let unifiedDiff: String
    public let constraints: BridgeApplyPatchConstraints?

    public init(deviceId: String? = nil, unifiedDiff: String, constraints: BridgeApplyPatchConstraints? = nil) {
        self.deviceId = deviceId
        self.unifiedDiff = unifiedDiff
        self.constraints = constraints
    }
}

public struct BridgeApplyPatchResult: Codable, Sendable {
    public let applied: Bool
    public let filesChanged: [String]
    public let reason: String?

    public init(applied: Bool, filesChanged: [String], reason: String? = nil) {
        self.applied = applied
        self.filesChanged = filesChanged
        self.reason = reason
    }
}

public struct BridgeGitStatusArguments: Codable, Sendable {
    public let deviceId: String?

    public init(deviceId: String? = nil) {
        self.deviceId = deviceId
    }
}

public struct BridgeGitStatusResult: Codable, Sendable {
    public let branch: String
    public let changedFiles: [String]
    public let stagedFiles: [String]

    public init(branch: String, changedFiles: [String], stagedFiles: [String]) {
        self.branch = branch
        self.changedFiles = changedFiles
        self.stagedFiles = stagedFiles
    }
}

public struct BridgeGitDiffArguments: Codable, Sendable {
    public let deviceId: String?
    public let staged: Bool?

    public init(deviceId: String? = nil, staged: Bool? = nil) {
        self.deviceId = deviceId
        self.staged = staged
    }
}

public struct BridgeGitDiffResult: Codable, Sendable {
    public let diff: String
    public let truncated: Bool?
    public let tail: String?

    public init(diff: String, truncated: Bool? = nil, tail: String? = nil) {
        self.diff = diff
        self.truncated = truncated
        self.tail = tail
    }
}

public struct BridgeGitStageArguments: Codable, Sendable {
    public let deviceId: String?
    public let paths: [String]

    public init(deviceId: String? = nil, paths: [String]) {
        self.deviceId = deviceId
        self.paths = paths
    }
}

public struct BridgeGitStageResult: Codable, Sendable {
    public let staged: [String]

    public init(staged: [String]) {
        self.staged = staged
    }
}

public struct BridgeGitCommitArguments: Codable, Sendable {
    public let deviceId: String?
    public let message: String

    public init(deviceId: String? = nil, message: String) {
        self.deviceId = deviceId
        self.message = message
    }
}

public struct BridgeGitCommitResult: Codable, Sendable {
    public let commitSha: String

    public init(commitSha: String) {
        self.commitSha = commitSha
    }
}

public struct BridgeGitPushArguments: Codable, Sendable {
    public let deviceId: String?
    public let remote: String
    public let branch: String

    public init(deviceId: String? = nil, remote: String, branch: String) {
        self.deviceId = deviceId
        self.remote = remote
        self.branch = branch
    }
}

public struct BridgeGitPushResult: Codable, Sendable {
    public let pushed: Bool

    public init(pushed: Bool) {
        self.pushed = pushed
    }
}

public struct BridgeClaudeRunArguments: Codable, Sendable {
    public let deviceId: String?
    public let prompt: String
    public let cwd: String?
    public let timeoutSec: Int?
    public let allowedTools: String?
    public let maxTurns: Int?

    public init(deviceId: String? = nil, prompt: String, cwd: String? = nil, timeoutSec: Int? = nil, allowedTools: String? = nil, maxTurns: Int? = nil) {
        self.deviceId = deviceId
        self.prompt = prompt
        self.cwd = cwd
        self.timeoutSec = timeoutSec
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
    }
}

public struct BridgeClaudeRunResult: Codable, Sendable {
    public let result: String
    public let sessionId: String?

    public init(result: String, sessionId: String? = nil) {
        self.result = result
        self.sessionId = sessionId
    }
}

// MARK: - Nova Act

public struct BridgeNovaStartArguments: Codable, Sendable {
    public let deviceId: String?
    public let url: String
    public let headless: Bool?
    public let userDataDir: String?

    public init(deviceId: String? = nil, url: String, headless: Bool? = nil, userDataDir: String? = nil) {
        self.deviceId = deviceId
        self.url = url
        self.headless = headless
        self.userDataDir = userDataDir
    }
}

public struct BridgeNovaStartResult: Codable, Sendable {
    public let started: Bool

    public init(started: Bool) {
        self.started = started
    }
}

public struct BridgeNovaActArguments: Codable, Sendable {
    public let deviceId: String?
    public let instruction: String
    public let schema: String?

    public init(deviceId: String? = nil, instruction: String, schema: String? = nil) {
        self.deviceId = deviceId
        self.instruction = instruction
        self.schema = schema
    }
}

public struct BridgeNovaActResult: Codable, Sendable {
    public let result: String
    public let success: Bool
    public let pageContext: String?

    public init(result: String, success: Bool, pageContext: String? = nil) {
        self.result = result
        self.success = success
        self.pageContext = pageContext
    }
}

public struct BridgeNovaStopArguments: Codable, Sendable {
    public let deviceId: String?

    public init(deviceId: String? = nil) {
        self.deviceId = deviceId
    }
}

public struct BridgeNovaStopResult: Codable, Sendable {
    public let stopped: Bool

    public init(stopped: Bool) {
        self.stopped = stopped
    }
}
