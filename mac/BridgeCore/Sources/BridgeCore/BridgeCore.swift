import Foundation
import SwiftProtocol

public actor BridgeCore {
    public typealias StatusHandler = @Sendable (BridgeStatusSnapshot) -> Void
    public typealias LogHandler = @Sendable (String) -> Void

    private var config: BridgeConfiguration
    private var policy: WorkspacePolicy
    private let executor = ProcessExecutor()

    private var runTask: Task<Void, Never>?
    private var wsSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var state: BridgeConnectionState = .disconnected
    private var paired = false
    private var lastExitCode: Int32?

    private var statusHandler: StatusHandler?
    private var logHandler: LogHandler?

    private let envelopeEncoder: JSONEncoder
    private let envelopeDecoder: JSONDecoder

    public init(configuration: BridgeConfiguration) {
        self.config = configuration
        self.policy = WorkspacePolicy(workspaceRoot: configuration.workspaceRoot)

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

    public func updatePairingCode(_ pairingCode: String?) async {
        config.pairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        paired = false
        await emitStatus()
        try? await sendRegisterIfPossible()
    }

    public func updateWorkspaceRoot(_ workspaceRoot: URL) async {
        config.workspaceRoot = workspaceRoot.standardizedFileURL
        policy = WorkspacePolicy(workspaceRoot: workspaceRoot)
        await emitStatus()
    }

    public func updateDeviceName(_ deviceName: String) async {
        config.deviceName = deviceName
        try? await sendRegisterIfPossible()
    }

    public func snapshot() -> BridgeStatusSnapshot {
        BridgeStatusSnapshot(
            connectionState: state,
            paired: paired,
            pairingCode: config.pairingCode,
            deviceId: config.deviceId,
            workspaceRoot: config.workspaceRoot.path,
            lastExitCode: lastExitCode
        )
    }

    public func start() {
        guard runTask == nil else { return }
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

                // Wait for the WebSocket handshake to complete
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
                await emitStatus()

                try await sendRegisterIfPossible()

                let registerTicker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        await self?.tryRegisterFromTicker()
                    }
                }

                defer {
                    registerTicker.cancel()
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
        guard let pairingCode = config.pairingCode, !pairingCode.isEmpty else { return }

        let payload = BridgeRegisterPayload(
            pairingCode: pairingCode,
            deviceId: config.deviceId,
            deviceName: config.deviceName,
            workspaceRoot: config.workspaceRoot.path,
            capabilities: config.capabilities,
            protocolVersion: AbyssProtocol.version
        )

        try await sendEvent(type: "bridge.register", sessionId: config.deviceId, payload: payload)
    }

    private func handleInboundText(_ text: String) async throws {
        let data = Data(text.utf8)
        let envelope = try envelopeDecoder.decode(EventEnvelope.self, from: data)

        switch envelope.type {
        case "bridge.registered":
            paired = true
            await emitStatus()
        case "error":
            if let payload: [String: String] = try? decodePayloadObject(from: envelope.payload),
               payload["code"] == "pairing_code_invalid_or_expired" {
                paired = false
                await emitStatus()
            }
        case "tool.call":
            try await handleToolCall(envelope)
        default:
            break
        }
    }

    private func handleToolCall(_ envelope: EventEnvelope) async throws {
        let payload: ToolCallPayload = try decodePayload(from: envelope.payload)

        do {
            let resultText: String
            switch payload.name {
            case "bridge.exec.run":
                let args = try decodeArguments(BridgeExecRunArguments.self, json: payload.arguments)
                let cwd = try policy.resolveCWD(relativeCWD: args.cwd)
                let timeoutSec = max(1, min(args.timeoutSec ?? 60, 600))
                let result = try executor.run(
                    command: args.command,
                    cwd: cwd,
                    timeoutSec: timeoutSec,
                    outputLimitBytes: config.outputLimitBytes
                )
                lastExitCode = result.exitCode
                resultText = encodeJSONString(
                    BridgeExecRunResult(
                        exitCode: result.exitCode,
                        stdout: result.stdout,
                        stderr: result.stderr
                    )
                )
                await emitStatus()

            case "bridge.fs.readFile":
                let args = try decodeArguments(BridgeReadFileArguments.self, json: payload.arguments)
                let content = try policy.readFile(path: args.path, maxBytes: config.outputLimitBytes)
                resultText = encodeJSONString(BridgeReadFileResult(content: content))

            default:
                throw BridgeCoreError.unsupportedTool(payload.name)
            }

            try await sendEvent(
                type: "tool.result",
                sessionId: envelope.sessionId,
                payload: ToolResultPayload(callId: payload.callId, result: resultText, error: nil)
            )
        } catch {
            try await sendEvent(
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
}
