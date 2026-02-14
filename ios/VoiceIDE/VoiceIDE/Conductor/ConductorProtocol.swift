import Foundation

/// Protocol for the conductor — the "brain" that decides what tool calls to make.
/// Phase 1: LocalConductorStub (deterministic, no network).
/// Phase 2: WebSocketConductorClient (connects to a Nova-powered backend).
protocol Conductor: Sendable {
    /// Given a finalized user transcript, produce a sequence of events
    /// (tool calls, speech events, etc.) that the ToolRouter will execute.
    func handleTranscript(_ transcript: String) async -> [Event]

    /// Handle a session start.
    func handleSessionStart() async -> [Event]
}

/// Phase 2 conductor protocol — event-driven, bidirectional streaming.
/// Replaces the batch-return Conductor with a real-time WebSocket connection.
protocol ConductorClient: AnyObject, Sendable {
    /// Connect to the backend with the given session ID.
    func connect(sessionId: String) async throws

    /// Disconnect from the backend.
    func disconnect() async

    /// Send an event to the backend.
    func send(event: Event) async throws

    /// Async stream of inbound events from the server.
    var inboundEvents: AsyncStream<Event> { get }

    /// Whether the client is currently connected.
    var isConnected: Bool { get }
}
