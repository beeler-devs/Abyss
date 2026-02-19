import Foundation

// File-level constants so date formatters are safely accessible from Sendable closures.
private let _iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let _iso8601Basic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

protocol WebSocketTransport: AnyObject, Sendable {
    func connect() async throws
    func disconnect() async
    func send(text: String) async throws
    var inboundText: AsyncStream<String> { get }
}

final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private nonisolated(unsafe) var socketTask: URLSessionWebSocketTask?
    private nonisolated(unsafe) var receiveTask: Task<Void, Never>?

    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    var inboundText: AsyncStream<String> { stream }

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.stream = stream
        self.continuation = continuation
        super.init()
    }

    func connect() async throws {
        let task = session.webSocketTask(with: url)
        socketTask = task
        task.resume()

        receiveTask?.cancel()
        receiveTask = Task {
            await receiveLoop(task)
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        continuation.finish()
    }

    func send(text: String) async throws {
        guard let task = socketTask else {
            throw WebSocketConductorClient.Error.notConnected
        }
        // Race the actual send against a 5-second timeout so a dead/unreachable server
        // never blocks the caller indefinitely.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await task.send(.string(text)) }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw WebSocketConductorClient.Error.sendTimeout
            }
            // First to finish wins; cancel the loser.
            try await group.next()!
            group.cancelAll()
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    continuation.yield(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        continuation.yield(text)
                    }
                @unknown default:
                    continue
                }
            } catch {
                break
            }
        }

        continuation.finish()
    }
}

final class WebSocketConductorClient: ConductorClient, @unchecked Sendable {
    enum Error: LocalizedError {
        case invalidURL(String)
        case notConnected
        case encodingFailed
        case sendTimeout

        var errorDescription: String? {
            switch self {
            case .invalidURL(let raw):
                return "Invalid backend WebSocket URL: \(raw)"
            case .notConnected:
                return "WebSocket conductor is not connected"
            case .encodingFailed:
                return "Failed to encode WebSocket event payload"
            case .sendTimeout:
                return "WebSocket send timed out (server unreachable)"
            }
        }
    }

    private let backendURL: URL
    private let transportFactory: @Sendable () -> WebSocketTransport
    private let reconnectBaseDelayNs: UInt64
    private let reconnectMaxDelayNs: UInt64
    private let reconnectJitterRange: ClosedRange<Double>

    private var transport: WebSocketTransport?
    private var listenTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var reconnectAttempt: Int = 0
    private var shouldReconnect: Bool = false
    private var currentSessionId: String?
    private var currentGithubToken: String?

    private var seenInboundEventIDs: Set<String> = []
    private var seenInboundEventOrder: [String] = []
    private let maxRememberedEventIDs = 2_000

    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(_iso8601WithFractional.string(from: date))
        }
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = _iso8601WithFractional.date(from: value)
                ?? _iso8601Basic.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 timestamp: \(value)"
            )
        }
        return decoder
    }()


    var inboundEvents: AsyncStream<Event> { stream }

    init(
        backendURL: URL,
        transportFactory: (@Sendable () -> WebSocketTransport)? = nil,
        reconnectBaseDelayNs: UInt64 = 500_000_000,
        reconnectMaxDelayNs: UInt64 = 30_000_000_000,
        reconnectJitterRange: ClosedRange<Double> = 0.0...0.3
    ) {
        self.backendURL = backendURL
        self.transportFactory = transportFactory ?? { URLSessionWebSocketTransport(url: backendURL) }
        self.reconnectBaseDelayNs = reconnectBaseDelayNs
        self.reconnectMaxDelayNs = reconnectMaxDelayNs
        self.reconnectJitterRange = reconnectJitterRange

        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    convenience init(backendURLString: String) throws {
        guard let url = URL(string: backendURLString) else {
            throw Error.invalidURL(backendURLString)
        }
        self.init(backendURL: url)
    }

    func connect(sessionId: String, githubToken: String? = nil) async throws {
        currentSessionId = sessionId
        currentGithubToken = githubToken
        shouldReconnect = true

        try await openSocketAndStartListening()
        try await send(event: Event.sessionStart(sessionId: sessionId, githubToken: githubToken))
    }

    func disconnect() async {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil

        listenTask?.cancel()
        listenTask = nil

        if let transport {
            await transport.disconnect()
        }

        transport = nil
        reconnectAttempt = 0
    }

    func send(event: Event) async throws {
        guard let transport else {
            throw Error.notConnected
        }

        let outboundEvent: Event
        if event.sessionId == nil {
            outboundEvent = Event(
                id: event.id,
                timestamp: event.timestamp,
                sessionId: currentSessionId,
                kind: event.kind
            )
        } else {
            outboundEvent = event
        }

        let envelope = EventEnvelope(event: outboundEvent)
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.encodingFailed
        }

        try await transport.send(text: text)
    }

    private func openSocketAndStartListening() async throws {
        let transport = transportFactory()
        try await transport.connect()

        self.transport = transport
        reconnectAttempt = 0

        listenTask?.cancel()
        listenTask = Task { [weak self] in
            guard let self else { return }

            for await rawMessage in transport.inboundText {
                await self.handleIncoming(rawMessage)
            }

            await self.handleSocketClosed()
        }
    }

    private func handleIncoming(_ rawMessage: String) async {
        guard let data = rawMessage.data(using: .utf8) else {
            return
        }

        guard let envelope = try? decoder.decode(EventEnvelope.self, from: data) else {
            return
        }

        guard !seenInboundEventIDs.contains(envelope.id) else {
            return
        }

        seenInboundEventIDs.insert(envelope.id)
        seenInboundEventOrder.append(envelope.id)
        trimSeenEventIDsIfNeeded()

        guard let event = try? envelope.toEvent() else {
            return
        }

        continuation.yield(event)
    }

    private func trimSeenEventIDsIfNeeded() {
        while seenInboundEventOrder.count > maxRememberedEventIDs {
            let removed = seenInboundEventOrder.removeFirst()
            seenInboundEventIDs.remove(removed)
        }
    }

    private func handleSocketClosed() async {
        guard shouldReconnect else {
            return
        }
        await scheduleReconnect()
    }

    private func scheduleReconnect() async {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            self.reconnectAttempt += 1

            let capped = min(self.reconnectAttempt, 6)
            let multiplier = UInt64(pow(2.0, Double(max(0, capped - 1))))
            let exponentialDelay = min(self.reconnectMaxDelayNs, self.reconnectBaseDelayNs.saturatingMultiply(multiplier))
            let jitterSeconds = Double.random(in: self.reconnectJitterRange)
            let jitterNs = UInt64(max(0, jitterSeconds) * 1_000_000_000)
            let delayNs = min(self.reconnectMaxDelayNs, exponentialDelay &+ jitterNs)

            try? await Task.sleep(nanoseconds: delayNs)

            guard !Task.isCancelled else { return }
            guard self.shouldReconnect else { return }
            guard let sessionId = self.currentSessionId else { return }

            do {
                try await self.openSocketAndStartListening()
                let token = self.currentGithubToken
                try await self.send(event: Event.sessionStart(sessionId: sessionId, githubToken: token))
            } catch {
                await self.scheduleReconnect()
            }
        }
    }
}

private extension UInt64 {
    func saturatingMultiply(_ rhs: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
