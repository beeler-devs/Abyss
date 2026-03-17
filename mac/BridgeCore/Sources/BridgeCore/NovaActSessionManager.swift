import Foundation
import os

private let novaActLog = Logger(subsystem: "app.abyss.bridge", category: "NovaAct")

/// Manages a persistent Python process running the Nova Act bridge script.
/// Communicates via stdin/stdout JSON-RPC (one JSON object per line).
public actor NovaActSessionManager {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var lineBuffer: String = ""
    private var pendingContinuation: CheckedContinuation<[String: Any], Error>?
    public private(set) var isActive: Bool = false

    private let commandTimeoutSeconds: TimeInterval = 120

    public init() {}

    // MARK: - Public API

    public func start(
        url: String,
        headless: Bool,
        userDataDir: String?,
        pythonPath: String? = nil,
        scriptPath: String,
        apiKey: String? = nil
    ) async throws -> String? {
        guard !isActive else {
            throw NovaActError.sessionAlreadyActive
        }

        let resolvedPython = pythonPath ?? resolvePythonPath()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedPython)
        proc.arguments = [scriptPath]

        // Forward PATH and inject API key (app-provided key takes precedence over env var)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if let apiKey, !apiKey.isEmpty {
            env["NOVA_ACT_API_KEY"] = apiKey
        }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        // Log stderr for debugging
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    novaActLog.info("python: \(line, privacy: .public)")
                }
            }
        }

        // Set up stdout line reader
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.ingestStdout(text) }
        }

        novaActLog.info("launching Python process: \(resolvedPython) \(scriptPath)")
        try proc.run()
        isActive = true

        // Send start command
        var cmd: [String: Any] = ["cmd": "start", "url": url, "headless": headless]
        if let dir = userDataDir {
            cmd["user_data_dir"] = dir
        }

        novaActLog.info("sending start command: url=\(url) headless=\(headless)")
        let response = try await sendCommand(cmd, timeout: 120)
        guard response["ok"] as? Bool == true else {
            let error = response["error"] as? String ?? "start failed"
            novaActLog.error("start failed: \(error)")
            await cleanup()
            throw NovaActError.startFailed(error)
        }
        let pageContext = response["page_context"] as? String
        novaActLog.info("session started successfully pageContext=\(pageContext != nil)")
        return pageContext
    }

    public struct ActResponse {
        public let result: String
        public let pageContext: String?
    }

    public func act(instruction: String, schema: String?) async throws -> ActResponse {
        guard isActive else {
            throw NovaActError.noActiveSession
        }

        var cmd: [String: Any] = ["cmd": "act", "instruction": instruction]
        if let schema = schema {
            cmd["schema"] = schema
        }

        novaActLog.info("sending act command: \(instruction.prefix(120))")
        let response = try await sendCommand(cmd, timeout: commandTimeoutSeconds)
        guard response["ok"] as? Bool == true else {
            let error = response["error"] as? String ?? "act failed"
            novaActLog.error("act failed: \(error)")
            throw NovaActError.actFailed(error)
        }

        let result = response["result"] as? String ?? ""
        let pageContext = response["page_context"] as? String
        novaActLog.info("act complete, result length=\(result.count) pageContext=\(pageContext != nil)")
        return ActResponse(result: result, pageContext: pageContext)
    }

    public func stop() async throws -> Bool {
        guard isActive else { return true }

        let cmd: [String: Any] = ["cmd": "stop"]
        do {
            let response = try await sendCommand(cmd, timeout: 15)
            await cleanup()
            return response["ok"] as? Bool ?? true
        } catch {
            await cleanup()
            throw error
        }
    }

    public func forceKill() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
        isActive = false
        lineBuffer = ""

        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(throwing: NovaActError.forcedKill)
        }
    }

    // MARK: - Internal

    private func ingestStdout(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])

            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let cont = pendingContinuation {
                pendingContinuation = nil
                cont.resume(returning: json)
            }
        }
    }

    private func sendCommand(_ cmd: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let pipe = stdinPipe else {
            throw NovaActError.noActiveSession
        }

        let data = try JSONSerialization.data(withJSONObject: cmd)
        guard var jsonString = String(data: data, encoding: .utf8) else {
            throw NovaActError.serializationError
        }
        jsonString += "\n"

        pipe.fileHandleForWriting.write(jsonString.data(using: .utf8)!)

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.setPendingContinuation(continuation) }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NovaActError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func setPendingContinuation(_ continuation: CheckedContinuation<[String: Any], Error>) {
        pendingContinuation = continuation
    }

    private func cleanup() async {
        forceKill()
    }

    private func resolvePythonPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        // Check PATH first
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/python3"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return "python3" // fallback, hope it's in PATH
    }
}

public enum NovaActError: Error, LocalizedError {
    case sessionAlreadyActive
    case noActiveSession
    case startFailed(String)
    case actFailed(String)
    case timeout
    case forcedKill
    case serializationError

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive: return "Nova Act session already active"
        case .noActiveSession: return "No active Nova Act session"
        case .startFailed(let msg): return "Nova Act start failed: \(msg)"
        case .actFailed(let msg): return "Nova Act action failed: \(msg)"
        case .timeout: return "Nova Act command timed out"
        case .forcedKill: return "Nova Act session force-killed"
        case .serializationError: return "Failed to serialize command"
        }
    }
}
