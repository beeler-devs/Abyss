import XCTest
@testable import VoiceIDE

@MainActor
final class ToolRouterTests: XCTestCase {

    func testDispatchToRegisteredTool() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let stateStore = AppStateStore()

        registry.register(ConvoSetStateTool(stateStore: stateStore))

        let router = ToolRouter(registry: registry, eventBus: bus)

        let toolCall = Event.ToolCall(
            name: "convo.setState",
            arguments: "{\"state\":\"listening\"}"
        )

        let result = await router.dispatch(toolCall)

        // Should have emitted a tool.result event
        XCTAssertEqual(bus.events.count, 1)

        if case .toolResult(let tr) = result.kind {
            XCTAssertNil(tr.error)
            XCTAssertNotNil(tr.result)
            XCTAssertEqual(tr.callId, toolCall.callId)
        } else {
            XCTFail("Expected tool.result event")
        }

        // State should be updated
        XCTAssertEqual(stateStore.current, .listening)
    }

    func testDispatchToUnknownTool() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let router = ToolRouter(registry: registry, eventBus: bus)

        let toolCall = Event.ToolCall(name: "nonexistent.tool", arguments: "{}")
        let result = await router.dispatch(toolCall)

        if case .toolResult(let tr) = result.kind {
            XCTAssertNotNil(tr.error)
            XCTAssertTrue(tr.error!.contains("Unknown tool"))
        } else {
            XCTFail("Expected tool.result error event")
        }
    }

    func testDispatchWithInvalidArguments() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let stateStore = AppStateStore()

        registry.register(ConvoSetStateTool(stateStore: stateStore))
        let router = ToolRouter(registry: registry, eventBus: bus)

        let toolCall = Event.ToolCall(
            name: "convo.setState",
            arguments: "not valid json"
        )

        let result = await router.dispatch(toolCall)

        if case .toolResult(let tr) = result.kind {
            XCTAssertNotNil(tr.error)
        } else {
            XCTFail("Expected tool.result error event")
        }
    }

    func testConvoAppendMessageTool() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let store = ConversationStore()

        registry.register(ConvoAppendMessageTool(store: store))
        let router = ToolRouter(registry: registry, eventBus: bus)

        let toolCall = Event.ToolCall(
            name: "convo.appendMessage",
            arguments: "{\"role\":\"user\",\"text\":\"Hello world\",\"isPartial\":false}"
        )

        await router.dispatch(toolCall)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].text, "Hello world")
        XCTAssertEqual(store.messages[0].role, .user)
    }

    func testProcessEventsEmitsToolCallsAndResults() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let stateStore = AppStateStore()
        let convStore = ConversationStore()

        registry.register(ConvoSetStateTool(stateStore: stateStore))
        registry.register(ConvoAppendMessageTool(store: convStore))

        let router = ToolRouter(registry: registry, eventBus: bus)

        let events = [
            Event.toolCall(
                name: "convo.setState",
                arguments: "{\"state\":\"thinking\"}",
                callId: "call-1"
            ),
            Event.speechFinal("Test response"),
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: "{\"role\":\"assistant\",\"text\":\"Test response\",\"isPartial\":false}",
                callId: "call-2"
            ),
        ]

        await router.processEvents(events)

        // Should have: toolCall + toolResult + speechFinal + toolCall + toolResult = 5
        XCTAssertEqual(bus.events.count, 5)

        // First should be tool.call
        if case .toolCall(let tc) = bus.events[0].kind {
            XCTAssertEqual(tc.name, "convo.setState")
        } else {
            XCTFail("Expected tool.call")
        }

        // Second should be tool.result
        if case .toolResult(let tr) = bus.events[1].kind {
            XCTAssertNil(tr.error)
        } else {
            XCTFail("Expected tool.result")
        }

        // Third should be speechFinal
        if case .assistantSpeechFinal(let sf) = bus.events[2].kind {
            XCTAssertEqual(sf.text, "Test response")
        } else {
            XCTFail("Expected speechFinal")
        }
    }

    func testAgentSpawnTool() async throws {
        let bus = EventBus()
        let registry = ToolRegistry()
        let mockClient = MockCursorCloudAgentsClient()

        registry.register(AgentSpawnTool(client: mockClient))
        let router = ToolRouter(registry: registry, eventBus: bus)

        let toolCall = Event.ToolCall(
            name: "agent.spawn",
            arguments: """
            {"prompt":"Fix failing test","repository":"https://github.com/example/repo","ref":"main","autoCreatePr":true}
            """
        )

        let result = await router.dispatch(toolCall)

        XCTAssertEqual(mockClient.launchedRequests.count, 1)
        if case .toolResult(let tr) = result.kind {
            XCTAssertNil(tr.error)
            XCTAssertNotNil(tr.result)
        } else {
            XCTFail("Expected tool.result")
        }
    }

    func testAgentStatusAndCancelTools() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let mockClient = MockCursorCloudAgentsClient()

        registry.register(AgentStatusTool(client: mockClient))
        registry.register(AgentCancelTool(client: mockClient))
        let router = ToolRouter(registry: registry, eventBus: bus)

        _ = await router.dispatch(
            Event.ToolCall(name: "agent.status", arguments: "{\"id\":\"bc_test123\"}")
        )
        _ = await router.dispatch(
            Event.ToolCall(name: "agent.cancel", arguments: "{\"id\":\"bc_test123\"}")
        )

        XCTAssertEqual(mockClient.statusRequestedIDs, ["bc_test123"])
        XCTAssertEqual(mockClient.stoppedAgentIDs, ["bc_test123"])
    }
}
