import XCTest
@testable import Abyss

@MainActor
final class ServerConductorIntegrationTests: XCTestCase {

    func testInboundToolCallDispatchesAndSendsToolResult() async {
        let mockConductor = MockConductorClient()
        let mockSTT = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()

        let viewModel = ConversationViewModel(
            conductorClient: mockConductor,
            transcriber: mockSTT,
            tts: mockTTS,
            autoStartSession: true
        )

        // Ensure the inbound stream consumer is running.
        try? await Task.sleep(nanoseconds: 80_000_000)

        let toolCallEvent = Event.toolCall(
            name: "convo.setState",
            arguments: "{\"state\":\"thinking\"}",
            callId: "call-tool-1",
            sessionId: "session-test"
        )
        mockConductor.emitInbound(toolCallEvent)

        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(viewModel.appState, .thinking)

        let sentResult = mockConductor.sentEvents.first { event in
            if case .toolResult(let result) = event.kind {
                return result.callId == "call-tool-1"
            }
            return false
        }

        guard let sentResult else {
            XCTFail("Expected tool.result to be sent back to conductor")
            return
        }

        if case .toolResult(let result) = sentResult.kind {
            XCTAssertEqual(result.callId, "call-tool-1")
            XCTAssertNil(result.error)
        } else {
            XCTFail("Expected a tool.result event")
        }

        let timelineHasCall = viewModel.eventBus.events.contains { event in
            if case .toolCall(let call) = event.kind {
                return call.callId == "call-tool-1"
            }
            return false
        }

        XCTAssertTrue(timelineHasCall)
    }
}
