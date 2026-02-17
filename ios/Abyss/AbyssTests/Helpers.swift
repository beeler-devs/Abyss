import Foundation
@testable import Abyss

// MARK: - Mock SpeechTranscriber

final class MockSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _isListening = false
    var isListening: Bool {
        lock.withLock { _isListening }
    }

    var startCallCount = 0
    var stopCallCount = 0
    var mockFinalTranscript = "Hello test"
    private var continuation: AsyncStream<String>.Continuation?
    private var _partials: AsyncStream<String>?

    var partials: AsyncStream<String> {
        lock.withLock {
            if let existing = _partials { return existing }
            let (stream, cont) = AsyncStream<String>.makeStream()
            self._partials = stream
            self.continuation = cont
            return stream
        }
    }

    func start() async throws {
        lock.withLock {
            _isListening = true
            startCallCount += 1
        }
        // Recreate partials stream
        let (stream, cont) = AsyncStream<String>.makeStream()
        lock.withLock {
            self._partials = stream
            self.continuation = cont
        }
    }

    func stop() async throws -> String {
        lock.withLock {
            _isListening = false
            stopCallCount += 1
        }
        continuation?.finish()
        return mockFinalTranscript
    }

    func emitPartial(_ text: String) {
        continuation?.yield(text)
    }
}

// MARK: - Mock TextToSpeech

final class MockTextToSpeech: TextToSpeech, @unchecked Sendable {
    private let lock = NSLock()
    private var _isSpeaking = false
    var isSpeaking: Bool {
        lock.withLock { _isSpeaking }
    }

    var speakCallCount = 0
    var stopCallCount = 0
    var lastSpokenText: String?

    func speak(_ text: String) async throws {
        lock.withLock {
            _isSpeaking = true
            speakCallCount += 1
            lastSpokenText = text
        }
        // Simulate short speaking duration
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        lock.withLock { _isSpeaking = false }
    }

    func stop() async {
        lock.withLock {
            _isSpeaking = false
            stopCallCount += 1
        }
    }
}

// MARK: - Mock Cursor Cloud Agents

final class MockCursorCloudAgentsClient: CursorCloudAgentsProviding, @unchecked Sendable {
    var launchedRequests: [CursorLaunchAgentRequest] = []
    var statusRequestedIDs: [String] = []
    var stoppedAgentIDs: [String] = []
    var followUpCalls: [(id: String, prompt: String)] = []
    var listCallCount = 0

    var nextAgent = CursorAgent(
        id: "bc_test123",
        name: "Test Agent",
        status: "RUNNING",
        source: .init(repository: "https://github.com/example/repo", ref: "main"),
        target: .init(
            branchName: "cursor/test-branch",
            url: "https://cursor.com/agents?id=bc_test123",
            prUrl: nil,
            autoCreatePr: false,
            openAsCursorGithubApp: false,
            skipReviewerRequest: false
        ),
        summary: nil,
        createdAt: "2026-02-15T00:00:00Z"
    )

    func listAgents(limit: Int?, cursor: String?, prURL: String?) async throws -> CursorListAgentsResponse {
        listCallCount += 1
        return CursorListAgentsResponse(agents: [nextAgent], nextCursor: nil)
    }

    func agentStatus(id: String) async throws -> CursorAgent {
        statusRequestedIDs.append(id)
        return nextAgent
    }

    func launchAgent(request: CursorLaunchAgentRequest) async throws -> CursorAgent {
        launchedRequests.append(request)
        return nextAgent
    }

    func addFollowUp(agentID: String, prompt: CursorFollowUpRequest) async throws -> CursorIDOnlyResponse {
        followUpCalls.append((id: agentID, prompt: prompt.prompt.text))
        return CursorIDOnlyResponse(id: agentID)
    }

    func stopAgent(id: String) async throws -> CursorIDOnlyResponse {
        stoppedAgentIDs.append(id)
        return CursorIDOnlyResponse(id: id)
    }

    func deleteAgent(id: String) async throws -> CursorIDOnlyResponse {
        CursorIDOnlyResponse(id: id)
    }

    func apiKeyInfo() async throws -> CursorAPIKeyInfo {
        CursorAPIKeyInfo(apiKeyName: "Test Key", createdAt: "2026-02-15T00:00:00Z", userEmail: "test@example.com")
    }

    func models() async throws -> CursorModelsResponse {
        CursorModelsResponse(models: ["gpt-5.2"])
    }

    func repositories() async throws -> CursorRepositoriesResponse {
        CursorRepositoriesResponse(repositories: [])
    }
}
