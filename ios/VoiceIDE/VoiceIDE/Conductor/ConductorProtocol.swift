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
