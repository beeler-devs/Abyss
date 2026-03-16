import Foundation
import SwiftProtocol

public actor BridgeCore {
    public typealias StatusHandler = @Sendable (BridgeStatusSnapshot) -> Void
    public typealias LogHandler = @Sendable (String) -> Void
    public typealias GitPushConfirmationHandler = @Sendable (_ remote: String, _ branch: String) async -> Bool

    private var config: BridgeConfiguration
    private var policy: WorkspacePolicy
    private let commandManager: CommandManager

    private var runTask: Task<Void, Never>?
    private var wsSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var state: BridgeConnectionState = .disconnected
    private var paired = false
    private var lastExitCode: Int32?
    private var activeCommand: ActiveCommandSnapshot?

    private var statusHandler: StatusHandler?
    private var logHandler: LogHandler?
    private var gitPushConfirmationHandler: GitPushConfirmationHandler?

    private var callbacksInstalled = false
    private var hasRipgrep: Bool?
    private var claudeStreamStates: [String: ClaudeCLIStreamState] = [:]
    private var novaActManager: NovaActSessionManager?
    private var lastPairingErrorLogged: Date?

    private let envelopeEncoder: JSONEncoder
    private let envelopeDecoder: JSONDecoder

    public init(configuration: BridgeConfiguration) {
        self.config = configuration
        self.policy = WorkspacePolicy(workspaceRoots: configuration.workspaceRoots)
        self.commandManager = CommandManager(
            tailLimitBytes: configuration.commandOutputTailBytes,
            chunkLimitBytes: configuration.outputChunkBytes,
            timeoutCapSec: 900
        )

        self.envelopeEncoder = JSONEncoder()
        self.envelopeDecoder = JSONDecoder()

        envelopeEncoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }

        envelopeDecoder.dateDecodingStrategy = .custom { decoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let parsed = formatter.date(from: value)
                ?? ISO8601DateFormatter().date(from: value) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
    }

    public func setStatusHandler(_ handler: StatusHandler?) {
        statusHandler = handler
    }

    public func setLogHandler(_ handler: LogHandler?) {
        logHandler = handler
    }

    public func setGitPushConfirmationHandler(_ handler: GitPushConfirmationHandler?) {
        gitPushConfirmationHandler = handler
    }

    public func updatePairingCode(_ pairingCode: String?) async {
        config.pairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        paired = false
        await emitStatus()
        try? await sendRegisterIfPossible()
    }

    public func updateWorkspaceRoot(_ workspaceRoot: URL) async {
        config.workspaceRoot = workspaceRoot.standardizedFileURL
        config.workspaceRoots = withPrimaryWorkspaceRoot(config.workspaceRoot, existing: config.workspaceRoots)
        policy = WorkspacePolicy(workspaceRoots: config.workspaceRoots)
        await emitStatus()
        try? await sendRegisterIfPossible()
    }

    public func updateWorkspaceRoots(_ roots: [URL]) async {
        let normalized = roots.map { $0.standardizedFileURL }
        guard !normalized.isEmpty else {
            return
        }

        config.workspaceRoot = normalized[0]
        config.workspaceRoots = withPrimaryWorkspaceRoot(normalized[0], existing: normalized)
        policy = WorkspacePolicy(workspaceRoots: config.workspaceRoots)
        await emitStatus()
        try? await sendRegisterIfPossible()
    }

    public func updatePermissions(_ permissions: BridgePermissions) async {
        config.permissions = permissions
        await emitStatus()
        try? await sendRegisterIfPossible()
    }

    public func updateNovaActApiKey(_ key: String?) {
        config.novaActApiKey = key
    }

    public func updateDeviceName(_ deviceName: String) async {
        config.deviceName = deviceName
        try? await sendRegisterIfPossible()
    }

    public func cancelCommand(_ commandId: String) async -> Bool {
        let cancelled = await commandManager.cancel(commandId: commandId)
        await refreshActiveCommandSnapshot()
        await emitStatus()
        return cancelled
    }

    public func cancelActiveCommand() async -> Bool {
        guard let activeCommand else {
            return false
        }
        return await cancelCommand(activeCommand.commandId)
    }

    public func snapshot() -> BridgeStatusSnapshot {
        BridgeStatusSnapshot(
            connectionState: state,
            paired: paired,
            pairingCode: config.pairingCode,
            deviceId: config.deviceId,
            workspaceRoot: config.workspaceRoot.path,
            workspaceRoots: config.workspaceRoots.map(\.path),
            lastExitCode: lastExitCode,
            permissions: config.permissions,
            activeCommand: activeCommand
        )
    }

    public func start() {
        guard runTask == nil else { return }

        if !callbacksInstalled {
            callbacksInstalled = true
            Task {
                await commandManager.setOutputHandler { [weak self] output in
                    await self?.handleCommandOutput(output)
                }
                await commandManager.setFinishHandler { [weak self] completion in
                    await self?.handleCommandFinished(completion)
                }
            }
        }

        runTask = Task { [weak self] in
            await self?.connectionLoop()
        }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        state = .disconnected
        paired = false
        activeCommand = nil
        await novaActManager?.forceKill()
        novaActManager = nil
        await emitStatus()
    }

    private func connectionLoop() async {
        var reconnectAttempt = 0

        while !Task.isCancelled {
            do {
                state = .connecting
                await emitStatus()

                let sessionConfig = URLSessionConfiguration.default
                sessionConfig.timeoutIntervalForRequest = .infinity
                sessionConfig.timeoutIntervalForResource = .infinity
                let session = URLSession(configuration: sessionConfig)
                wsSession = session

                let wsTask = session.webSocketTask(with: config.serverURL)
                socket = wsTask
                wsTask.resume()

                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    wsTask.sendPing { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }

                state = .connected
                await emitLog("[connection] WebSocket connected to \(config.serverURL.absoluteString)")
                await emitStatus()

                try await sendRegisterIfPossible()

                let registerTicker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        await self?.tryRegisterFromTicker()
                    }
                }

                let keepAlivePinger = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        guard !Task.isCancelled else { break }
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                            wsTask.sendPing { error in
                                if let error {
                                    cont.resume(throwing: error)
                                } else {
                                    cont.resume()
                                }
                            }
                        }
                    }
                }

                defer {
                    registerTicker.cancel()
                    keepAlivePinger.cancel()
                }

                while !Task.isCancelled {
                    let message = try await wsTask.receive()
                    switch message {
                    case .string(let text):
                        try await handleInboundText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            try await handleInboundText(text)
                        }
                    @unknown default:
                        continue
                    }
                }

                reconnectAttempt = 0
            } catch {
                await emitLog("bridge disconnected: \(error.localizedDescription)")
            }

            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            wsSession?.invalidateAndCancel()
            wsSession = nil
            state = .disconnected
            paired = false
            await emitStatus()

            reconnectAttempt += 1
            let delaySec = min(15, max(1, reconnectAttempt))
            try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
        }
    }

    private func tryRegisterFromTicker() async {
        try? await sendRegisterIfPossible()
    }

    private func sendRegisterIfPossible() async throws {
        guard state == .connected else { return }
        guard let pairingCode = config.pairingCode, !pairingCode.isEmpty else {
            await emitLog("[pairing] skipping registration: no pairing code set")
            return
        }

        let payload = BridgeRegisterPayload(
            pairingCode: pairingCode,
            deviceId: config.deviceId,
            deviceName: config.deviceName,
            workspaceRoot: config.workspaceRoot.path,
            workspaceRoots: config.workspaceRoots.map(\.path),
            capabilities: effectiveCapabilities(),
            protocolVersion: AbyssProtocol.version
        )

        await emitLog("[pairing] sending bridge.register with code \(pairingCode)")
        try await sendEvent(type: "bridge.register", sessionId: config.deviceId, payload: payload)
    }

    private func effectiveCapabilities() -> BridgeCapabilities {
        var capabilities = config.capabilities
        capabilities.execRun = capabilities.execRun && config.permissions.allowExecRun
        capabilities.execStart = capabilities.execStart && config.permissions.allowExecRun
        capabilities.fsApplyPatch = capabilities.fsApplyPatch && config.permissions.allowWritesApplyPatch
        capabilities.gitStage = capabilities.gitStage && config.permissions.allowWritesApplyPatch
        capabilities.gitCommit = capabilities.gitCommit && config.permissions.allowWritesApplyPatch
        capabilities.gitPush = capabilities.gitPush && config.permissions.allowGitPush
        capabilities.claudeRun = capabilities.claudeRun && config.permissions.allowClaudeRun
        return capabilities
    }

    private func handleInboundText(_ text: String) async throws {
        let data = Data(text.utf8)
        let envelope = try envelopeDecoder.decode(EventEnvelope.self, from: data)

        switch envelope.type {
        case "bridge.registered":
            await emitLog("[pairing] registered successfully — paired=true")
            paired = true
            lastPairingErrorLogged = nil
            await emitStatus()
        case "error":
            if let payload: [String: String] = try? decodePayloadObject(from: envelope.payload) {
                let code = payload["code"] ?? "unknown"
                let message = payload["message"] ?? ""
                await emitLog("[error] code=\(code) message=\(message)")
                if code == "pairing_code_invalid_or_expired" {
                    if paired {
                        paired = false
                        await emitStatus()
                    }
                    let now = Date()
                    if lastPairingErrorLogged == nil || now.timeIntervalSince(lastPairingErrorLogged!) > 30 {
                        await emitLog("[pairing] code not found on server, waiting for iOS to re-register...")
                        lastPairingErrorLogged = now
                    }
                }
            }
        case "tool.call":
            // Fire-and-forget so the receive loop isn't blocked during long-running tools
            // (e.g. bridge.claude.run). The actor's re-entrancy at await points means the
            // connection loop can still call wsTask.receive() while the tool executes.
            Task { [weak self] in
                try? await self?.handleToolCall(envelope)
            }
        case "bridge.workspace.set":
            Task { [weak self] in await self?.handleWorkspaceSet(envelope) }
        default:
            break
        }
    }

    private func handleWorkspaceSet(_ envelope: EventEnvelope) async {
        guard let path = envelope.payload.objectValue?["workspacePath"]?.stringValue,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await emitLog("[workspace] bridge.workspace.set: missing or empty workspacePath")
            return
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            await emitLog("[workspace] bridge.workspace.set: path does not exist or is not a directory: \(path)")
            return
        }

        await updateWorkspaceRoot(URL(fileURLWithPath: path))
        await emitLog("[workspace] workspace updated to \(path)")
    }

    private func handleToolCall(_ envelope: EventEnvelope) async throws {
        let payload: ToolCallPayload = try decodePayload(from: envelope.payload)

        do {
            let resultText: String

            switch payload.name {
            case "bridge.exec.run":
                guard config.permissions.allowExecRun else {
                    throw BridgeCoreError.permissionDenied("exec.run disabled")
                }

                let args = try decodeArguments(BridgeExecRunArguments.self, json: payload.arguments)
                let start = try await startCommand(
                    command: args.command,
                    cwd: args.cwd,
                    env: nil,
                    timeoutSec: args.timeoutSec
                )
                guard let completion = await commandManager.waitForCompletion(commandId: start.commandId) else {
                    throw BridgeCoreError.internalError("command_not_found_after_start")
                }

                lastExitCode = completion.exitCode
                await refreshActiveCommandSnapshot()

                var stderr = completion.stderrTail
                if completion.state == .timedOut && !stderr.contains("timed out") {
                    stderr += "\nCommand timed out"
                } else if completion.state == .cancelled && !stderr.contains("cancelled") {
                    stderr += "\nCommand cancelled"
                }

                resultText = encodeJSONString(
                    BridgeExecRunResult(
                        exitCode: completion.exitCode,
                        stdout: completion.stdoutTail,
                        stderr: stderr
                    )
                )
                await emitStatus()

            case "bridge.exec.start":
                guard config.permissions.allowExecRun else {
                    throw BridgeCoreError.permissionDenied("exec.start disabled")
                }

                let args = try decodeArguments(BridgeExecStartArguments.self, json: payload.arguments)
                let started = try await startCommand(
                    command: args.command,
                    cwd: args.cwd,
                    env: args.env,
                    timeoutSec: args.timeoutSec
                )
                resultText = encodeJSONString(BridgeExecStartResult(commandId: started.commandId, startedAt: started.startedAt))
                await emitStatus()

            case "bridge.exec.cancel":
                let args = try decodeArguments(BridgeExecCancelArguments.self, json: payload.arguments)
                let cancelled = await commandManager.cancel(commandId: args.commandId)
                resultText = encodeJSONString(BridgeExecCancelResult(cancelled: cancelled))
                await refreshActiveCommandSnapshot()
                await emitStatus()

            case "bridge.exec.status":
                let args = try decodeArguments(BridgeExecStatusArguments.self, json: payload.arguments)
                let status = await commandManager.status(commandId: args.commandId)
                resultText = encodeJSONString(BridgeExecStatusResult(state: status.state, exitCode: status.exitCode))

            case "bridge.exec.output.subscribe":
                _ = try decodeArguments(BridgeExecOutputSubscribeArguments.self, json: payload.arguments)
                resultText = encodeJSONString(BridgeExecOutputSubscribeResult(subscribed: true))

            case "bridge.fs.readFile":
                let args = try decodeArguments(BridgeReadFileArguments.self, json: payload.arguments)
                let content = try policy.readFile(path: args.path, maxBytes: config.outputLimitBytes)
                resultText = encodeJSONString(BridgeReadFileResult(content: content))

            case "bridge.fs.search":
                let args = try decodeArguments(BridgeSearchArguments.self, json: payload.arguments)
                let searchResult = try searchFiles(args: args)
                resultText = encodeJSONString(searchResult)

            case "bridge.fs.readRange":
                let args = try decodeArguments(BridgeReadRangeArguments.self, json: payload.arguments)
                let content = try policy.readRange(
                    path: args.path,
                    startLine: args.startLine,
                    endLine: args.endLine,
                    maxBytes: config.outputLimitBytes
                )
                resultText = encodeJSONString(BridgeReadRangeResult(content: content))

            case "bridge.fs.applyPatch":
                guard config.permissions.allowWritesApplyPatch else {
                    throw BridgeCoreError.permissionDenied("applyPatch disabled")
                }

                let args = try decodeArguments(BridgeApplyPatchArguments.self, json: payload.arguments)
                let applyResult = try applyPatch(args)
                resultText = encodeJSONString(applyResult)

            case "bridge.git.status":
                _ = try decodeArguments(BridgeGitStatusArguments.self, json: payload.arguments)
                resultText = encodeJSONString(try gitStatus())

            case "bridge.git.diff":
                let args = try decodeArguments(BridgeGitDiffArguments.self, json: payload.arguments)
                resultText = encodeJSONString(try gitDiff(staged: args.staged ?? false))

            case "bridge.git.stage":
                guard config.permissions.allowWritesApplyPatch else {
                    throw BridgeCoreError.permissionDenied("git.stage disabled")
                }
                let args = try decodeArguments(BridgeGitStageArguments.self, json: payload.arguments)
                resultText = encodeJSONString(try gitStage(paths: args.paths))

            case "bridge.git.commit":
                guard config.permissions.allowWritesApplyPatch else {
                    throw BridgeCoreError.permissionDenied("git.commit disabled")
                }
                let args = try decodeArguments(BridgeGitCommitArguments.self, json: payload.arguments)
                resultText = encodeJSONString(try gitCommit(message: args.message))

            case "bridge.git.push":
                guard config.permissions.allowGitPush else {
                    throw BridgeCoreError.permissionDenied("git.push disabled")
                }
                let args = try decodeArguments(BridgeGitPushArguments.self, json: payload.arguments)

                if config.permissions.requireGitPushConfirmation {
                    guard let gitPushConfirmationHandler else {
                        throw BridgeCoreError.permissionDenied("git.push confirmation required")
                    }
                    let allowed = await gitPushConfirmationHandler(args.remote, args.branch)
                    guard allowed else {
                        throw BridgeCoreError.permissionDenied("git.push cancelled by user")
                    }
                }

                resultText = encodeJSONString(try gitPush(remote: args.remote, branch: args.branch))

            case "bridge.claude.run":
                let args = try decodeArguments(BridgeClaudeRunArguments.self, json: payload.arguments)
                let allowedTools = normalizedClaudeToolList(args.allowedTools)
                    ?? "Bash,Read,Edit,Write,LS,Glob,Grep,MultiEdit"

                func shellEscape(_ str: String) -> String {
                    return "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }

                let maxTurns = max(1, min(args.maxTurns ?? 30, 100))
                let command = "claude -p \(shellEscape(args.prompt)) --allowedTools \(shellEscape(allowedTools)) --permission-mode acceptEdits --output-format stream-json --max-turns \(maxTurns)"

                let start = try await startCommand(
                    command: command,
                    cwd: args.cwd,
                    env: nil,
                    timeoutSec: args.timeoutSec ?? 660
                )
                claudeStreamStates[start.commandId] = ClaudeCLIStreamState()
                await emitClaudeCommandBinding(commandId: start.commandId)
                guard let completion = await commandManager.waitForCompletion(commandId: start.commandId) else {
                    claudeStreamStates.removeValue(forKey: start.commandId)
                    throw BridgeCoreError.internalError("command_not_found_after_start")
                }

                lastExitCode = completion.exitCode
                await refreshActiveCommandSnapshot()
                await emitStatus()

                let claudeOutput = completion.stdoutTail.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = consumeClaudeCLIResult(commandId: start.commandId, fallbackOutput: claudeOutput)
                let fallbackError = completion.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)

                if completion.exitCode != 0 || parsed?.isError == true {
                    let errorMsg = firstNonEmptyString([
                        parsed?.result,
                        fallbackError,
                        claudeOutput,
                    ]) ?? "claude exited with code \(completion.exitCode)"
                    throw BridgeCoreError.internalError(errorMsg)
                }

                let resultString = firstNonEmptyString([parsed?.result, claudeOutput]) ?? ""
                resultText = encodeJSONString(BridgeClaudeRunResult(result: resultString, sessionId: parsed?.sessionId))

            case "bridge.nova.start":
                guard config.permissions.allowNovaAct else {
                    throw BridgeCoreError.permissionDenied("novaAct disabled")
                }
                let novaAlreadyActive = await novaActManager?.isActive ?? false
                guard novaActManager == nil || !novaAlreadyActive else {
                    throw BridgeCoreError.internalError("Nova Act session already active")
                }
                let args = try decodeArguments(BridgeNovaStartArguments.self, json: payload.arguments)

                let scriptPath: String
                if let bundledScript = Bundle.module.url(forResource: "nova_act_bridge", withExtension: "py", subdirectory: "Resources") {
                    scriptPath = bundledScript.path
                } else {
                    throw BridgeCoreError.internalError("nova_act_bridge.py not found in bundle")
                }

                let manager = NovaActSessionManager()
                try await manager.start(
                    url: args.url,
                    headless: args.headless ?? true,
                    userDataDir: args.userDataDir,
                    scriptPath: scriptPath,
                    apiKey: config.novaActApiKey
                )
                novaActManager = manager
                resultText = encodeJSONString(BridgeNovaStartResult(started: true))

            case "bridge.nova.act":
                guard config.permissions.allowNovaAct else {
                    throw BridgeCoreError.permissionDenied("novaAct disabled")
                }
                let novaActActive = await novaActManager?.isActive ?? false
                guard let manager = novaActManager, novaActActive else {
                    throw BridgeCoreError.internalError("No active Nova Act session. Call bridge.nova.start first.")
                }
                let args = try decodeArguments(BridgeNovaActArguments.self, json: payload.arguments)
                let actResult = try await manager.act(instruction: args.instruction, schema: args.schema)
                resultText = encodeJSONString(BridgeNovaActResult(result: actResult, success: true))

            case "bridge.nova.stop":
                if let manager = novaActManager {
                    let _ = try await manager.stop()
                    novaActManager = nil
                }
                resultText = encodeJSONString(BridgeNovaStopResult(stopped: true))

            default:
                throw BridgeCoreError.unsupportedTool(payload.name)
            }

            try? await sendEvent(
                type: "tool.result",
                sessionId: envelope.sessionId,
                payload: ToolResultPayload(callId: payload.callId, result: resultText, error: nil)
            )
        } catch {
            // Use try? so a closed WebSocket doesn't propagate back and kill the connection loop.
            try? await sendEvent(
                type: "tool.result",
                sessionId: envelope.sessionId,
                payload: ToolResultPayload(
                    callId: payload.callId,
                    result: nil,
                    error: error.localizedDescription
                )
            )
        }
    }

    private func startCommand(command: String, cwd: String?, env: [String: String]?, timeoutSec: Int?) async throws -> CommandStart {
        let cwdURL = try policy.resolveCWD(relativeCWD: cwd)
        let timeout = max(1, min(timeoutSec ?? 60, 900))

        if let maskedEnv = maskedEnvironmentForLog(env), !maskedEnv.isEmpty {
            await emitLog("exec.start command=\(command) cwd=\(cwdURL.path) env=\(maskedEnv)")
        } else {
            await emitLog("exec.start command=\(command) cwd=\(cwdURL.path)")
        }

        let started = try await commandManager.start(command: command, cwd: cwdURL, env: env, timeoutSec: timeout)
        await refreshActiveCommandSnapshot()
        return started
    }

    private func handleCommandOutput(_ output: CommandOutput) async {
        if output.stream == "stdout" {
            ingestClaudeCLIOutput(commandId: output.commandId, chunk: output.chunk, isFinal: output.isFinal)
        }

        try? await sendEvent(
            type: "bridge.exec.output",
            sessionId: config.deviceId,
            payload: BridgeExecOutputEventPayload(
                deviceId: config.deviceId,
                commandId: output.commandId,
                stream: output.stream,
                chunk: output.chunk,
                isFinal: output.isFinal
            )
        )

        await refreshActiveCommandSnapshot()
        await emitStatus()
    }

    private func handleCommandFinished(_ completion: CommandCompletion) async {
        lastExitCode = completion.exitCode

        try? await sendEvent(
            type: "bridge.exec.finished",
            sessionId: config.deviceId,
            payload: BridgeExecFinishedEventPayload(
                deviceId: config.deviceId,
                commandId: completion.commandId,
                exitCode: completion.exitCode,
                stdoutTail: completion.stdoutTail,
                stderrTail: completion.stderrTail
            )
        )

        await refreshActiveCommandSnapshot()
        await emitStatus()
    }

    private func emitClaudeCommandBinding(commandId: String) async {
        try? await sendEvent(
            type: "bridge.exec.output",
            sessionId: config.deviceId,
            payload: BridgeExecOutputEventPayload(
                deviceId: config.deviceId,
                commandId: commandId,
                stream: "stdout",
                chunk: "",
                isFinal: false
            )
        )
    }

    private func ingestClaudeCLIOutput(commandId: String, chunk: String, isFinal: Bool) {
        guard var state = claudeStreamStates[commandId] else {
            return
        }

        state.ingest(chunk: chunk, isFinal: isFinal)
        claudeStreamStates[commandId] = state
    }

    private func consumeClaudeCLIResult(commandId: String, fallbackOutput: String) -> ClaudeCLIResult? {
        if var state = claudeStreamStates.removeValue(forKey: commandId) {
            state.finalize()
            if let result = state.lastResult {
                return result
            }
        }

        return parseClaudeCLIResult(from: fallbackOutput)
    }

    private func refreshActiveCommandSnapshot() async {
        activeCommand = await commandManager.activeCommandSnapshot()
    }

    private func searchFiles(args: BridgeSearchArguments) throws -> BridgeSearchResult {
        let root = try policy.resolveSearchRoot(args.root)
        let maxResults = max(1, min(args.maxResults ?? 50, 500))

        if hasRipgrep == nil {
            hasRipgrep = (try? runProcess(executable: "/usr/bin/env", arguments: ["rg", "--version"], cwd: root, timeoutSec: 2).exitCode == 0) ?? false
        }

        if hasRipgrep == true {
            return try searchWithRipgrep(args: args, root: root, maxResults: maxResults)
        }

        return try searchFallback(args: args, root: root, maxResults: maxResults)
    }

    private func searchWithRipgrep(args: BridgeSearchArguments, root: URL, maxResults: Int) throws -> BridgeSearchResult {
        var cmdArgs = [
            "--line-number",
            "--no-heading",
            "--color",
            "never",
            "--fixed-strings",
            "--max-count",
            String(maxResults),
        ]

        if let globs = args.globs {
            for glob in globs where !glob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cmdArgs.append("--glob")
                cmdArgs.append(glob)
            }
        }

        cmdArgs.append(args.query)
        cmdArgs.append(".")

        let outcome = try runProcess(executable: "/usr/bin/env", arguments: ["rg"] + cmdArgs, cwd: root, timeoutSec: 20)
        if outcome.exitCode != 0 && !outcome.stdout.isEmpty == false {
            throw BridgeCoreError.internalError(outcome.stderr.isEmpty ? "fs.search failed" : outcome.stderr)
        }

        let lines = outcome.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        var matches: [BridgeSearchMatch] = []

        for rawLine in lines {
            guard matches.count < maxResults else { break }
            let line = String(rawLine)
            let firstColon = line.firstIndex(of: ":")
            guard let firstColon else { continue }
            let secondColon = line[line.index(after: firstColon)...].firstIndex(of: ":")
            guard let secondColon else { continue }

            let path = String(line[..<firstColon])
            let lineNumberString = String(line[line.index(after: firstColon)..<secondColon])
            guard let lineNumber = Int(lineNumberString), lineNumber > 0 else { continue }
            let snippet = String(line[line.index(after: secondColon)...])

            if policy.isDenied(relativePath: path) {
                continue
            }

            matches.append(BridgeSearchMatch(path: path, line: lineNumber, snippet: snippet))
        }

        return BridgeSearchResult(matches: matches)
    }

    private func searchFallback(args: BridgeSearchArguments, root: URL, maxResults: Int) throws -> BridgeSearchResult {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return BridgeSearchResult(matches: [])
        }

        var matches: [BridgeSearchMatch] = []

        for case let fileURL as URL in enumerator {
            guard matches.count < maxResults else { break }

            let relative = policy.relativePath(for: fileURL) ?? ""
            if relative.isEmpty || policy.isDenied(relativePath: relative) {
                continue
            }

            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains(args.query) {
                    matches.append(BridgeSearchMatch(path: relative, line: index + 1, snippet: String(line)))
                    if matches.count >= maxResults {
                        break
                    }
                }
            }
        }

        return BridgeSearchResult(matches: matches)
    }

    private func applyPatch(_ args: BridgeApplyPatchArguments) throws -> BridgeApplyPatchResult {
        let constraints = args.constraints
        let maxDiffLines = max(1, constraints?.maxDiffLines ?? 2_000)
        let diffLines = args.unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false)
        if diffLines.count > maxDiffLines {
            return BridgeApplyPatchResult(
                applied: false,
                filesChanged: [],
                reason: "diff exceeds maxDiffLines=\(maxDiffLines)"
            )
        }

        let filesChanged = parsePatchedFiles(from: args.unifiedDiff)
        if filesChanged.isEmpty {
            return BridgeApplyPatchResult(applied: false, filesChanged: [], reason: "no patch files detected")
        }

        if let allowed = constraints?.allowedPaths, !allowed.isEmpty {
            for changed in filesChanged {
                if !pathAllowedByConstraint(changed, allowedPaths: allowed) {
                    return BridgeApplyPatchResult(
                        applied: false,
                        filesChanged: filesChanged,
                        reason: "path not allowed by constraints: \(changed)"
                    )
                }
            }
        }

        for path in filesChanged {
            _ = try policy.resolve(relativePath: path, forWrite: true)
        }

        let outcome = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "apply", "--recount", "--whitespace=nowarn", "--"],
            cwd: config.workspaceRoot,
            stdin: args.unifiedDiff,
            timeoutSec: 20
        )

        if outcome.exitCode != 0 {
            return BridgeApplyPatchResult(
                applied: false,
                filesChanged: filesChanged,
                reason: outcome.stderr.isEmpty ? "git apply failed" : truncate(outcome.stderr, maxBytes: config.outputLimitBytes)
            )
        }

        return BridgeApplyPatchResult(applied: true, filesChanged: filesChanged, reason: nil)
    }

    private func parsePatchedFiles(from diff: String) -> [String] {
        var files: [String] = []

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("diff --git ") {
                let parts = line.split(separator: " ")
                if let last = parts.last {
                    let candidate = String(last)
                    let normalized = normalizePatchPath(candidate)
                    if !normalized.isEmpty && !files.contains(normalized) {
                        files.append(normalized)
                    }
                }
            }

            if line.hasPrefix("+++ ") {
                let value = String(line.dropFirst(4))
                if value == "/dev/null" { continue }
                let normalized = normalizePatchPath(value)
                if !normalized.isEmpty && !files.contains(normalized) {
                    files.append(normalized)
                }
            }
        }

        return files
    }

    private func normalizePatchPath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            path = String(path.dropFirst(2))
        }
        if path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        return path
    }

    private func pathAllowedByConstraint(_ changedPath: String, allowedPaths: [String]) -> Bool {
        for allowedRaw in allowedPaths {
            let allowed = normalizePatchPath(allowedRaw)
            if allowed.isEmpty {
                continue
            }
            if changedPath == allowed || changedPath.hasPrefix(allowed + "/") {
                return true
            }
        }
        return false
    }

    private func gitStatus() throws -> BridgeGitStatusResult {
        let outcome = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", config.workspaceRoot.path, "status", "--porcelain=1", "--branch"],
            cwd: config.workspaceRoot,
            timeoutSec: 10
        )

        guard outcome.exitCode == 0 else {
            throw BridgeCoreError.internalError(outcome.stderr.isEmpty ? "git status failed" : outcome.stderr)
        }

        let lines = outcome.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var branch = "HEAD"
        var changed = Set<String>()
        var staged = Set<String>()

        for line in lines {
            if line.hasPrefix("## ") {
                let rest = String(line.dropFirst(3))
                branch = rest.split(separator: ".").first.map(String.init) ?? rest
                continue
            }

            guard line.count >= 4 else { continue }
            let statusX = line[line.startIndex]
            let statusY = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }

            changed.insert(path)
            if statusX != " " && statusX != "?" {
                staged.insert(path)
            }
            if statusY != " " {
                changed.insert(path)
            }
        }

        return BridgeGitStatusResult(
            branch: branch,
            changedFiles: changed.sorted(),
            stagedFiles: staged.sorted()
        )
    }

    private func gitDiff(staged: Bool) throws -> BridgeGitDiffResult {
        var args = ["git", "-C", config.workspaceRoot.path, "diff"]
        if staged {
            args.append("--staged")
        }

        let outcome = try runProcess(
            executable: "/usr/bin/env",
            arguments: args,
            cwd: config.workspaceRoot,
            timeoutSec: 15
        )

        guard outcome.exitCode == 0 else {
            throw BridgeCoreError.internalError(outcome.stderr.isEmpty ? "git diff failed" : outcome.stderr)
        }

        let maxBytes = max(config.outputLimitBytes, 32_000)
        let fullData = Data(outcome.stdout.utf8)
        if fullData.count <= maxBytes {
            return BridgeGitDiffResult(diff: outcome.stdout, truncated: false, tail: nil)
        }

        let headData = fullData.prefix(maxBytes)
        let tailCount = min(24_000, fullData.count)
        let tailData = fullData.suffix(tailCount)

        return BridgeGitDiffResult(
            diff: String(decoding: headData, as: UTF8.self) + "\n...[truncated]",
            truncated: true,
            tail: String(decoding: tailData, as: UTF8.self)
        )
    }

    private func gitStage(paths: [String]) throws -> BridgeGitStageResult {
        guard !paths.isEmpty else {
            throw BridgeCoreError.invalidPayload("paths must not be empty")
        }

        var validated: [String] = []
        for path in paths {
            let resolved = try policy.resolve(relativePath: path, forWrite: true)
            guard let relative = policy.relativePath(for: resolved), relative != "." else {
                throw BridgeCoreError.workspaceViolation(path)
            }
            validated.append(relative)
        }

        let outcome = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", config.workspaceRoot.path, "add", "--"] + validated,
            cwd: config.workspaceRoot,
            timeoutSec: 15
        )

        guard outcome.exitCode == 0 else {
            throw BridgeCoreError.internalError(outcome.stderr.isEmpty ? "git add failed" : outcome.stderr)
        }

        return BridgeGitStageResult(staged: validated)
    }

    private func gitCommit(message: String) throws -> BridgeGitCommitResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeCoreError.invalidPayload("commit message must not be empty")
        }

        let commit = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", config.workspaceRoot.path, "commit", "-m", trimmed],
            cwd: config.workspaceRoot,
            timeoutSec: 20
        )

        guard commit.exitCode == 0 else {
            throw BridgeCoreError.internalError(commit.stderr.isEmpty ? "git commit failed" : commit.stderr)
        }

        let shaResult = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", config.workspaceRoot.path, "rev-parse", "HEAD"],
            cwd: config.workspaceRoot,
            timeoutSec: 10
        )

        guard shaResult.exitCode == 0 else {
            throw BridgeCoreError.internalError(shaResult.stderr.isEmpty ? "git rev-parse failed" : shaResult.stderr)
        }

        let sha = shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeGitCommitResult(commitSha: sha)
    }

    private func gitPush(remote: String, branch: String) throws -> BridgeGitPushResult {
        let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemote.isEmpty, !normalizedBranch.isEmpty else {
            throw BridgeCoreError.invalidPayload("remote and branch are required")
        }

        let outcome = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", config.workspaceRoot.path, "push", normalizedRemote, normalizedBranch],
            cwd: config.workspaceRoot,
            timeoutSec: 60
        )

        guard outcome.exitCode == 0 else {
            throw BridgeCoreError.internalError(outcome.stderr.isEmpty ? "git push failed" : outcome.stderr)
        }

        return BridgeGitPushResult(pushed: true)
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        cwd: URL,
        stdin: String? = nil,
        timeoutSec: Int
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            if let data = stdin.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        let timeout = max(1, timeoutSec)
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        if group.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + .seconds(1))
            throw BridgeCoreError.internalError("process timeout")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        return (process.terminationStatus, stdout, stderr)
    }

    private func maskedEnvironmentForLog(_ env: [String: String]?) -> [String: String]? {
        guard let env else {
            return nil
        }

        var masked: [String: String] = [:]
        for (key, value) in env {
            let lower = key.lowercased()
            if lower.contains("token") || lower.contains("secret") || lower.contains("password") || lower.contains("key") {
                masked[key] = "***redacted***"
            } else {
                masked[key] = truncate(value, maxBytes: 64)
            }
        }
        return masked
    }

    private func sendEvent<T: Encodable>(type: String, sessionId: String, payload: T) async throws {
        guard let socket else {
            throw BridgeCoreError.internalError("socket_not_connected")
        }

        let payloadValue = try encodeJSONValue(payload)
        let envelope = EventEnvelope(
            id: UUID().uuidString,
            type: type,
            timestamp: Date(),
            sessionId: sessionId,
            protocolVersion: AbyssProtocol.version,
            payload: payloadValue
        )

        let data = try envelopeEncoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeCoreError.internalError("event_encoding_failed")
        }

        try await socket.send(.string(text))
    }

    private func emitStatus() async {
        statusHandler?(snapshot())
    }

    private func emitLog(_ message: String) async {
        logHandler?(message)
    }

    private func decodePayload<T: Decodable>(from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func decodePayloadObject<T: Decodable>(from value: JSONValue) throws -> T {
        return try decodePayload(from: value)
    }

    private func decodeArguments<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encodeJSONString<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func encodeJSONValue<T: Encodable>(_ payload: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func withPrimaryWorkspaceRoot(_ primary: URL, existing: [URL]) -> [URL] {
        var deduped: [URL] = [primary.standardizedFileURL]
        for root in existing.map({ $0.standardizedFileURL }) where !deduped.contains(root) {
            deduped.append(root)
        }
        return deduped
    }
}

struct ClaudeCLIResult: Decodable, Sendable {
    let type: String?
    let result: String?
    let sessionId: String?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, result
        case sessionId = "session_id"
        case isError = "is_error"
    }
}

struct ClaudeCLIStreamState: Sendable {
    var lineBuffer = ""
    var lastResult: ClaudeCLIResult?

    mutating func ingest(chunk: String, isFinal: Bool) {
        let combined = lineBuffer + chunk
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        lineBuffer = lines.last.map(String.init) ?? ""

        if lines.count > 1 {
            for line in lines.dropLast() {
                handleLine(String(line))
            }
        }

        if isFinal {
            finalize()
        }
    }

    mutating func finalize() {
        if !lineBuffer.isEmpty {
            handleLine(lineBuffer)
            lineBuffer = ""
        }
    }

    private mutating func handleLine(_ line: String) {
        guard let event = parseClaudeCLIEvent(from: line), event.type == "result" else {
            return
        }
        lastResult = event
    }
}

func parseClaudeCLIEvent(from line: String) -> ClaudeCLIResult? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
        return nil
    }

    return try? JSONDecoder().decode(ClaudeCLIResult.self, from: data)
}

/// Parses stream-json output from `claude --output-format stream-json`.
/// Each line is a separate JSON object; we keep the last `"type":"result"` event.
func parseClaudeCLIResult(from output: String) -> ClaudeCLIResult? {
    guard !output.isEmpty else { return nil }
    var latestResult: ClaudeCLIResult?
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let event = parseClaudeCLIEvent(from: String(line)),
              event.type == "result" else { continue }
        latestResult = event
    }
    return latestResult
}

func firstNonEmptyString(_ candidates: [String?]) -> String? {
    for candidate in candidates {
        guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            continue
        }
        return value
    }
    return nil
}

func normalizedClaudeToolList(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let tools = raw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !tools.isEmpty else {
        return nil
    }

    return tools.joined(separator: ",")
}
