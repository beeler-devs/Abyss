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

    func testPendingSpawnCardAnchorsToKickoffAssistantMessageAndStartsExpanded() async {
        var messages: [ConversationMessage] = []
        let manager = makeAgentManager(messages: { messages })

        manager.handleEventStream(Event.toolCall(
            name: AgentSpawnTool.name,
            arguments: encode(AgentSpawnTool.Arguments(
                prompt: "Fix flaky tests",
                repository: "https://github.com/acme/repo",
                ref: "main",
                prUrl: nil,
                model: nil,
                autoCreatePr: false,
                openAsCursorGithubApp: nil,
                skipReviewerRequest: nil,
                branchName: nil,
                autoBranch: nil
            )),
            callId: "spawn-1"
        ))

        let kickoffMessage = ConversationMessage(role: .assistant, text: "Starting a Cursor cloud agent.")
        messages.append(kickoffMessage)

        manager.handleEventStream(Event.toolCall(
            name: ConvoAppendMessageTool.name,
            arguments: encode(ConvoAppendMessageTool.Arguments(
                role: ConversationMessage.Role.assistant.rawValue,
                text: kickoffMessage.text,
                isPartial: false
            )),
            callId: "append-assistant-1"
        ))
        manager.handleEventStream(Event.toolResult(
            callId: "append-assistant-1",
            result: encode(ConvoAppendMessageTool.Result(messageId: kickoffMessage.id.uuidString))
        ))

        guard let card = manager.cards.first else {
            XCTFail("Expected pending spawn card")
            return
        }

        XCTAssertEqual(card.anchorMessageID, kickoffMessage.id)
        XCTAssertTrue(card.isExpanded)
    }

    func testStatusOnlyCardAnchorsToLatestAssistantMessage() async {
        let assistantMessage = ConversationMessage(role: .assistant, text: "I started a review.")
        let manager = makeAgentManager(messages: { [assistantMessage] })

        manager.handleEventStream(Event.agentStatus(
            "RUNNING",
            detail: "Agent started",
            agentId: "agent-1",
            summary: "Working through checks"
        ))

        XCTAssertEqual(manager.cards.first?.anchorMessageID, assistantMessage.id)
    }

    func testStatusOnlyCardFallsBackToTranscriptEndWhenNoAssistantMessageExists() async {
        let manager = makeAgentManager(messages: { [] })

        manager.handleEventStream(Event.agentStatus(
            "RUNNING",
            detail: "Agent started",
            agentId: "agent-2",
            summary: "Working through checks"
        ))

        XCTAssertNil(manager.cards.first?.anchorMessageID)
    }

    func testTogglingOuterExpansionPreservesConversationDisclosureState() async {
        let assistantMessage = ConversationMessage(role: .assistant, text: "Working on it.")
        let manager = makeAgentManager(messages: { [assistantMessage] })

        manager.handleEventStream(Event.agentStatus(
            "RUNNING",
            detail: "Agent started",
            agentId: "agent-3",
            summary: "Working through checks"
        ))

        guard let cardID = manager.cards.first?.id else {
            XCTFail("Expected agent card")
            return
        }

        manager.toggleConversationExpanded(cardID: cardID)
        manager.toggleCardExpanded(cardID: cardID)

        guard let card = manager.cards.first else {
            XCTFail("Expected agent card after toggles")
            return
        }

        XCTAssertFalse(card.isExpanded)
        XCTAssertTrue(card.isConversationExpanded)
    }

    func testCardOrderRemainsStableAcrossMultipleAgentUpdates() async {
        var messages = [ConversationMessage(role: .assistant, text: "First kickoff.")]
        let manager = makeAgentManager(messages: { messages })

        manager.handleEventStream(Event.agentStatus(
            "RUNNING",
            detail: "First agent started",
            agentId: "agent-1",
            summary: "First run"
        ))

        messages.append(ConversationMessage(role: .assistant, text: "Second kickoff."))
        manager.handleEventStream(Event.agentStatus(
            "RUNNING",
            detail: "Second agent started",
            agentId: "agent-2",
            summary: "Second run"
        ))

        manager.handleEventStream(Event.agentStatus(
            "FINISHED",
            detail: "First agent finished",
            agentId: "agent-1",
            summary: "First run complete"
        ))

        XCTAssertEqual(manager.cards.compactMap(\.agentId), ["agent-1", "agent-2"])
    }

    private func makeAgentManager(
        messages: @escaping @MainActor @Sendable () -> [ConversationMessage]
    ) -> ConversationAgentManager {
        let eventBus = EventBus()
        let toolRouter = ToolRouter(registry: ToolRegistry(), eventBus: eventBus)

        return ConversationAgentManager(
            eventBus: eventBus,
            toolRouter: toolRouter,
            sessionId: "session-test",
            conversationMessages: messages,
            sendConductorEvent: { _ in },
            shouldUseWebhookUpdates: { false },
            isUsingServerClient: { false }
        )
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
