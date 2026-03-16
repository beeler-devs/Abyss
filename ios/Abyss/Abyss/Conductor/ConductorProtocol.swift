import Foundation

/// Deterministic transcript->event engine used by the local Phase 1 stub.
protocol Conductor: Sendable {
    /// Given a finalized user transcript, produce a sequence of events
    /// (tool calls, speech events, etc.) that the ToolRouter will execute.
    func handleTranscript(_ transcript: String) async -> [Event]

    /// Handle a session start.
    func handleSessionStart() async -> [Event]
}

/// Transport-level conductor client used by Phase 2.
/// It connects to a backend (or local adapter), sends events, and yields inbound events.
protocol ConductorClient: Sendable {
    func connect(sessionId: String, githubToken: String?, gmailAccessToken: String?, gmailRefreshToken: String?, gmailTokenExpiresAt: Double?, canvasAccessToken: String?, canvasBaseURL: String?, preferences: [String: String]?, memoryUserKey: String?, bridgeWorkspaceOverrides: [Event.BridgeWorkspaceOverride]?) async throws
    func disconnect() async
    func send(event: Event) async throws
    var inboundEvents: AsyncStream<Event> { get }
}

extension ConductorClient {
    func connect(sessionId: String, githubToken: String? = nil, gmailAccessToken: String? = nil, gmailRefreshToken: String? = nil, gmailTokenExpiresAt: Double? = nil, canvasAccessToken: String? = nil, canvasBaseURL: String? = nil, preferences: [String: String]? = nil, memoryUserKey: String? = nil) async throws {
        try await connect(sessionId: sessionId, githubToken: githubToken, gmailAccessToken: gmailAccessToken, gmailRefreshToken: gmailRefreshToken, gmailTokenExpiresAt: gmailTokenExpiresAt, canvasAccessToken: canvasAccessToken, canvasBaseURL: canvasBaseURL, preferences: preferences, memoryUserKey: memoryUserKey, bridgeWorkspaceOverrides: nil)
    }
}
