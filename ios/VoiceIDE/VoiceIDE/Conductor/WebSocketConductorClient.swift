import Foundation

/// WebSocket-based conductor client for Phase 2.
/// Connects to the cloud conductor backend over WebSocket, sending events
/// and receiving tool calls / speech events in real-time.
final class WebSocketConductorClient: NSObject, ConductorClient, URLSessionWebSocketDelegate, @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var _isConnected = false
    private var sessionId: String = ""
    private var inboundContinuation: AsyncStream<Event>.Continuation?
    private var _inboundEvents: AsyncStream<Event>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let baseReconnectDelay: TimeInterval = 1.0

    var isConnected: Bool {
        lock.withLock { _isConnected }
    }

    var inboundEvents: AsyncStream<Event> {
        lock.withLock {
            if let existing = _inboundEvents { return existing }
            let (stream, continuation) = AsyncStream<Event>.makeStream()
            _inboundEvents = stream
            inboundContinuation = continuation
            return stream
        }
    }

    private let backendURL: String

    // MARK: - Init

    init(backendURL: String? = nil) {
        self.backendURL = backendURL ?? Config.backendWebSocketURL
        super.init()
    }

    // MARK: - ConductorClient

    func connect(sessionId: String) async throws {
        self.sessionId = sessionId
        reconnectAttempts = 0

        // Ensure we have a fresh inbound stream
        lock.withLock {
            if _inboundEvents == nil {
                let (stream, continuation) = AsyncStream<Event>.makeStream()
                _inboundEvents = stream
                inboundContinuation = continuation
            }
        }

        try await establishConnection()
    }

    func disconnect() async {
        lock.withLock { _isConnected = false }
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        lock.withLock {
            inboundContinuation?.finish()
            inboundContinuation = nil
            _inboundEvents = nil
        }
    }

    func send(event: Event) async throws {
        guard let task = webSocketTask, isConnected else {
            throw WebSocketError.notConnected
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)

        guard let json = String(data: data, encoding: .utf8) else {
            throw WebSocketError.encodingFailed
        }

        try await task.send(.string(json))
    }

    // MARK: - Connection Management

    private func establishConnection() async throws {
        guard var urlComponents = URLComponents(string: backendURL) else {
            throw WebSocketError.invalidURL
        }

        // Add sessionId as query parameter
        urlComponents.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId)
        ]

        guard let url = urlComponents.url else {
            throw WebSocketError.invalidURL
        }

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
        self.urlSession = session

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task

        task.resume()

        // Wait briefly for connection to establish
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        lock.withLock { _isConnected = true }
        reconnectAttempts = 0

        // Start receiving messages
        receiveMessages()
    }

    private func receiveMessages() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                // Continue receiving
                self.receiveMessages()

            case .failure(let error):
                let wasConnected = self.lock.withLock {
                    let was = self._isConnected
                    self._isConnected = false
                    return was
                }

                if wasConnected {
                    // Emit error event
                    self.lock.withLock {
                        self.inboundContinuation?.yield(
                            Event.error(code: "ws_error", message: error.localizedDescription)
                        )
                    }

                    // Attempt reconnection
                    Task { await self.attemptReconnect() }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let event = try decoder.decode(Event.self, from: data)
            lock.withLock {
                inboundContinuation?.yield(event)
            }
        } catch {
            // Try to emit as error event
            lock.withLock {
                inboundContinuation?.yield(
                    Event.error(code: "decode_error", message: "Failed to decode server event: \(error.localizedDescription)")
                )
            }
        }
    }

    // MARK: - Reconnection

    private func attemptReconnect() async {
        guard reconnectAttempts < maxReconnectAttempts else {
            lock.withLock {
                inboundContinuation?.yield(
                    Event.error(code: "reconnect_failed", message: "Max reconnection attempts reached")
                )
            }
            return
        }

        reconnectAttempts += 1
        let delay = baseReconnectDelay * pow(2.0, Double(reconnectAttempts - 1))

        // Wait before reconnecting (exponential backoff)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        do {
            try await establishConnection()
        } catch {
            await attemptReconnect()
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.withLock { _isConnected = true }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.withLock { _isConnected = false }
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case notConnected
    case invalidURL
    case encodingFailed
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket is not connected"
        case .invalidURL: return "Invalid WebSocket URL"
        case .encodingFailed: return "Failed to encode event to JSON"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
