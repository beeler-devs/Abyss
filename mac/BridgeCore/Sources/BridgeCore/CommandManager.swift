import Foundation
import Darwin
import SwiftProtocol

public struct CommandStart: Sendable {
    public let commandId: String
    public let startedAt: String

    public init(commandId: String, startedAt: String) {
        self.commandId = commandId
        self.startedAt = startedAt
    }
}

public struct CommandStatus: Sendable {
    public let state: BridgeExecState
    public let exitCode: Int32?

    public init(state: BridgeExecState, exitCode: Int32?) {
        self.state = state
        self.exitCode = exitCode
    }
}

public struct CommandOutput: Sendable {
    public let commandId: String
    public let stream: String
    public let chunk: String
    public let isFinal: Bool

    public init(commandId: String, stream: String, chunk: String, isFinal: Bool) {
        self.commandId = commandId
        self.stream = stream
        self.chunk = chunk
        self.isFinal = isFinal
    }
}

public struct CommandCompletion: Sendable {
    public let commandId: String
    public let state: BridgeExecState
    public let exitCode: Int32
    public let stdoutTail: String
    public let stderrTail: String

    public init(commandId: String, state: BridgeExecState, exitCode: Int32, stdoutTail: String, stderrTail: String) {
        self.commandId = commandId
        self.state = state
        self.exitCode = exitCode
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

public actor CommandManager {
    public typealias OutputHandler = @Sendable (CommandOutput) async -> Void
    public typealias FinishHandler = @Sendable (CommandCompletion) async -> Void

    private final class Runtime {
        let commandId: String
        let command: String
        let cwd: URL
        let startedAt: Date
        let process: Process
        let stdoutPipe: Pipe
        let stderrPipe: Pipe

        var state: BridgeExecState = .running
        var exitCode: Int32?
        var cancelRequested = false
        var timedOut = false

        var stdoutTail: RollingTailBuffer
        var stderrTail: RollingTailBuffer

        var waiters: [CheckedContinuation<CommandCompletion, Never>] = []
        var timeoutTask: Task<Void, Never>?
        var forceKillTask: Task<Void, Never>?

        init(commandId: String, command: String, cwd: URL, process: Process, stdoutPipe: Pipe, stderrPipe: Pipe, startedAt: Date, tailBytes: Int) {
            self.commandId = commandId
            self.command = command
            self.cwd = cwd
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.startedAt = startedAt
            self.stdoutTail = RollingTailBuffer(maxBytes: tailBytes)
            self.stderrTail = RollingTailBuffer(maxBytes: tailBytes)
        }
    }

    private let iso8601: ISO8601DateFormatter
    private let tailLimitBytes: Int
    private let chunkLimitBytes: Int
    private let timeoutCapSec: Int

    private var outputHandler: OutputHandler?
    private var finishHandler: FinishHandler?

    private var runningById: [String: Runtime] = [:]
    private var completedById: [String: CommandCompletion] = [:]
    private var completionOrder: [String] = []

    public init(
        tailLimitBytes: Int = 200_000,
        chunkLimitBytes: Int = 4096,
        timeoutCapSec: Int = 900
    ) {
        self.tailLimitBytes = max(4_096, tailLimitBytes)
        self.chunkLimitBytes = max(512, chunkLimitBytes)
        self.timeoutCapSec = max(1, timeoutCapSec)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601 = formatter
    }

    public func setOutputHandler(_ handler: OutputHandler?) {
        outputHandler = handler
    }

    public func setFinishHandler(_ handler: FinishHandler?) {
        finishHandler = handler
    }

    public func start(
        command: String,
        cwd: URL,
        env: [String: String]?,
        timeoutSec: Int?
    ) throws -> CommandStart {
        let commandId = UUID().uuidString
        let startedAt = Date()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in env {
                merged[key] = value
            }
            process.environment = merged
        }

        let runtime = Runtime(
            commandId: commandId,
            command: command,
            cwd: cwd,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            startedAt: startedAt,
            tailBytes: tailLimitBytes
        )
        runningById[commandId] = runtime

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.handleOutputChunk(commandId: commandId, stream: "stdout", data: data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.handleOutputChunk(commandId: commandId, stream: "stderr", data: data) }
        }

        process.terminationHandler = { [weak self] terminated in
            Task {
                await self?.handleTermination(commandId: commandId, terminationStatus: terminated.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            runningById.removeValue(forKey: commandId)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let effectiveTimeout = max(1, min(timeoutSec ?? 60, timeoutCapSec))
        runtime.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout) * 1_000_000_000)
            await self?.handleTimeout(commandId: commandId)
        }

        return CommandStart(commandId: commandId, startedAt: iso8601.string(from: startedAt))
    }

    public func cancel(commandId: String, graceMs: Int = 1500) -> Bool {
        guard let runtime = runningById[commandId], runtime.process.isRunning else {
            return false
        }

        runtime.cancelRequested = true
        _ = kill(runtime.process.processIdentifier, SIGINT)

        runtime.forceKillTask?.cancel()
        runtime.forceKillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(100, graceMs)) * 1_000_000)
            await self?.forceKill(commandId: commandId)
        }

        return true
    }

    public func status(commandId: String) -> CommandStatus {
        if let runtime = runningById[commandId] {
            return CommandStatus(state: runtime.state, exitCode: runtime.exitCode)
        }
        if let completion = completedById[commandId] {
            return CommandStatus(state: completion.state, exitCode: completion.exitCode)
        }
        return CommandStatus(state: .failed, exitCode: nil)
    }

    public func waitForCompletion(commandId: String) async -> CommandCompletion? {
        if let completion = completedById[commandId] {
            return completion
        }

        guard let runtime = runningById[commandId] else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            runtime.waiters.append(continuation)
        }
    }

    public func activeCommandSnapshot() -> ActiveCommandSnapshot? {
        let runtimes = runningById.values
        guard let runtime = runtimes.max(by: { $0.startedAt < $1.startedAt }) else {
            return nil
        }

        return ActiveCommandSnapshot(
            commandId: runtime.commandId,
            command: runtime.command,
            cwd: runtime.cwd.path,
            state: runtime.state,
            startedAt: iso8601.string(from: runtime.startedAt),
            stdoutTail: runtime.stdoutTail.text,
            stderrTail: runtime.stderrTail.text
        )
    }

    private func handleOutputChunk(commandId: String, stream: String, data: Data) async {
        guard let runtime = runningById[commandId] else {
            return
        }

        if stream == "stdout" {
            runtime.stdoutTail.append(data)
        } else {
            runtime.stderrTail.append(data)
        }

        guard let outputHandler else {
            return
        }

        var remaining = data
        while !remaining.isEmpty {
            let prefix = remaining.prefix(chunkLimitBytes)
            remaining.removeFirst(prefix.count)
            let chunk = String(decoding: prefix, as: UTF8.self)
            if !chunk.isEmpty {
                await outputHandler(CommandOutput(commandId: commandId, stream: stream, chunk: chunk, isFinal: false))
            }
        }
    }

    private func handleTimeout(commandId: String) async {
        guard let runtime = runningById[commandId], runtime.process.isRunning else {
            return
        }

        runtime.timedOut = true
        runtime.state = .timedOut
        _ = kill(runtime.process.processIdentifier, SIGINT)

        runtime.forceKillTask?.cancel()
        runtime.forceKillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.forceKill(commandId: commandId)
        }
    }

    private func forceKill(commandId: String) async {
        guard let runtime = runningById[commandId], runtime.process.isRunning else {
            return
        }

        _ = kill(runtime.process.processIdentifier, SIGKILL)
    }

    private func handleTermination(commandId: String, terminationStatus: Int32) async {
        guard let runtime = runningById[commandId] else {
            return
        }

        runtime.timeoutTask?.cancel()
        runtime.forceKillTask?.cancel()

        runtime.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        runtime.stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdoutRemaining = runtime.stdoutPipe.fileHandleForReading.availableData
        if !stdoutRemaining.isEmpty {
            runtime.stdoutTail.append(stdoutRemaining)
        }

        let stderrRemaining = runtime.stderrPipe.fileHandleForReading.availableData
        if !stderrRemaining.isEmpty {
            runtime.stderrTail.append(stderrRemaining)
        }

        let finalState: BridgeExecState
        if runtime.timedOut {
            finalState = .timedOut
        } else if runtime.cancelRequested {
            finalState = .cancelled
        } else if terminationStatus == 0 {
            finalState = .finished
        } else {
            finalState = .failed
        }

        runtime.state = finalState
        runtime.exitCode = terminationStatus

        let completion = CommandCompletion(
            commandId: commandId,
            state: finalState,
            exitCode: terminationStatus,
            stdoutTail: runtime.stdoutTail.text,
            stderrTail: runtime.stderrTail.text
        )

        completedById[commandId] = completion
        completionOrder.append(commandId)
        trimCompletionCacheIfNeeded()

        let waiters = runtime.waiters
        runtime.waiters.removeAll()

        runningById.removeValue(forKey: commandId)

        for waiter in waiters {
            waiter.resume(returning: completion)
        }

        if let finishHandler {
            await finishHandler(completion)
        }
    }

    private func trimCompletionCacheIfNeeded() {
        let maxEntries = 300
        guard completionOrder.count > maxEntries else {
            return
        }

        let overflow = completionOrder.count - maxEntries
        for _ in 0..<overflow {
            let commandId = completionOrder.removeFirst()
            completedById.removeValue(forKey: commandId)
        }
    }
}

private struct RollingTailBuffer {
    let maxBytes: Int
    private(set) var data = Data()
    private(set) var droppedBytes = 0

    init(maxBytes: Int) {
        self.maxBytes = max(1024, maxBytes)
    }

    mutating func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }

        if incoming.count >= maxBytes {
            droppedBytes += data.count + (incoming.count - maxBytes)
            data = Data(incoming.suffix(maxBytes))
            return
        }

        let overflow = (data.count + incoming.count) - maxBytes
        if overflow > 0 {
            droppedBytes += overflow
            data.removeFirst(overflow)
        }
        data.append(incoming)
    }

    var text: String {
        let value = String(decoding: data, as: UTF8.self)
        if droppedBytes > 0 {
            return "...[truncated \(droppedBytes) bytes]\n" + value
        }
        return value
    }
}
