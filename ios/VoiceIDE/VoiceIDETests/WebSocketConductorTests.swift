import XCTest
@testable import VoiceIDE

// MARK: - Mock ConductorClient

final class MockConductorClient: ConductorClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _isConnected = false
    private var inboundContinuation: AsyncStream<Event>.Continuation?
    private var _inboundEvents: AsyncStream<Event>?

    var connectCallCount = 0
    var disconnectCallCount = 0
    var sentEvents: [Event] = []
    var lastSessionId: String?

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

    func connect(sessionId: String) async throws {
        lock.withLock {
            _isConnected = true
            connectCallCount += 1
            lastSessionId = sessionId
        }
        // Initialize stream if needed
        _ = inboundEvents
    }

    func disconnect() async {
        lock.withLock {
            _isConnected = false
            disconnectCallCount += 1
            inboundContinuation?.finish()
        }
    }

    func send(event: Event) async throws {
        lock.withLock {
            sentEvents.append(event)
        }
    }

    /// Simulate receiving an event from the server
    func simulateInbound(_ event: Event) {
        lock.withLock {
            inboundContinuation?.yield(event)
        }
    }

    func simulateDisconnect() {
        lock.withLock {
            _isConnected = false
            inboundContinuation?.finish()
        }
    }
}

// MARK: - Tests

@MainActor
final class WebSocketConductorTests: XCTestCase {

    /// Test that inbound tool.call from server triggers ToolRouter and produces tool.result
    func testInboundToolCallTriggersToolRouterAndProducesResult() async {
        let mockClient = MockConductorClient()
        let mockTranscriber = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()

        let vm = ConversationViewModel(
            conductorClient: mockClient,
            transcriber: mockTranscriber,
            tts: mockTTS
        )

        // Connect
        try? await mockClient.connect(sessionId: "test-session")

        // Start inbound event loop manually
        let inboundTask = Task {
            for await event in mockClient.inboundEvents {
                await vm.handleInboundEvent(event)
            }
        }

        // Small delay for setup
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Simulate server sending a tool.call for convo.setState
        let toolCallEvent = Event.toolCall(
            name: "convo.setState",
            arguments: "{\"state\":\"thinking\"}",
            callId: "server-call-1"
        )
        mockClient.simulateInbound(toolCallEvent)

        // Wait for processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Check that the event was emitted to the EventBus
        let toolCalls = vm.eventBus.events.filter {
            if case .toolCall = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(toolCalls.count, 1)

        // Check that tool.result was generated
        let toolResults = vm.eventBus.events.filter {
            if case .toolResult = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(toolResults.count, 1)

        // Check that tool.result was sent back to the server
        let sentResults = mockClient.sentEvents.filter {
            if case .toolResult = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(sentResults.count, 1)

        // Verify the state was actually changed
        XCTAssertEqual(vm.appStateStore.current, .thinking)

        inboundTask.cancel()
    }

    /// Test that inbound assistant.speech.partial events are emitted to EventBus
    func testInboundSpeechPartialEmittedToEventBus() async {
        let mockClient = MockConductorClient()
        let mockTranscriber = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()

        let vm = ConversationViewModel(
            conductorClient: mockClient,
            transcriber: mockTranscriber,
            tts: mockTTS
        )

        // Simulate server sending speech partial
        let speechEvent = Event.speechPartial("Hello, I am")
        await vm.handleInboundEvent(speechEvent)

        let speechPartials = vm.eventBus.events.filter {
            if case .assistantSpeechPartial = $0.kind { return true }
            return false
        }
        XCTAssertEqual(speechPartials.count, 1)
    }

    /// Test that inbound error events surface to the UI
    func testInboundErrorEventSurfacesToUI() async {
        let mockClient = MockConductorClient()
        let mockTranscriber = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()

        let vm = ConversationViewModel(
            conductorClient: mockClient,
            transcriber: mockTranscriber,
            tts: mockTTS
        )

        let errorEvent = Event.error(code: "bedrock_error", message: "Model failed")
        await vm.handleInboundEvent(errorEvent)

        XCTAssertEqual(vm.errorMessage, "Model failed")
        XCTAssertTrue(vm.showError)
    }

    /// Test that ToolRouter handles unknown tool gracefully
    func testUnknownToolCallReturnsError() async {
        let mockClient = MockConductorClient()
        let mockTranscriber = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()

        let vm = ConversationViewModel(
            conductorClient: mockClient,
            transcriber: mockTranscriber,
            tts: mockTTS
        )

        let toolCallEvent = Event.toolCall(
            name: "nonexistent.tool",
            arguments: "{}",
            callId: "call-unknown"
        )
        await vm.handleInboundEvent(toolCallEvent)

        // Should have emitted tool.result with error
        let errors = vm.eventBus.events.filter {
            if case .toolResult(let tr) = $0.kind { return tr.isError }
            return false
        }
        XCTAssertEqual(errors.count, 1)
    }
}
