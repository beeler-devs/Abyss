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

    func testAgentStatusWithRunAndPrLinksUpdatesAgentCard() async {
        let mockConductor = MockConductorClient()
        let mockSTT = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()

        let viewModel = ConversationViewModel(
            conductorClient: mockConductor,
            transcriber: mockSTT,
            tts: mockTTS,
            autoStartSession: true
        )

        try? await Task.sleep(nanoseconds: 80_000_000)

        mockConductor.emitInbound(Event.agentStatus(
            "RUNNING",
            detail: "Agent started",
            sessionId: "session-test",
            agentId: "agent-xyz",
            summary: "Running browser checks",
            runUrl: "https://cursor.example/runs/agent-xyz",
            prUrl: "https://github.com/acme/repo/pull/77",
            branchName: "agent/webqa-branch",
            webhookDriven: true
        ))

        try? await Task.sleep(nanoseconds: 120_000_000)

        guard let card = viewModel.agentProgressCards.first else {
            XCTFail("Expected agent card to be created from agent.status event")
            return
        }

        XCTAssertEqual(card.agentId, "agent-xyz")
        XCTAssertEqual(card.agentURL, "https://cursor.example/runs/agent-xyz")
        XCTAssertEqual(card.prURL, "https://github.com/acme/repo/pull/77")
        XCTAssertEqual(card.branchName, "agent/webqa-branch")
    }
}
