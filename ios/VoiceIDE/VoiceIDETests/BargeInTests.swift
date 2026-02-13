import XCTest
@testable import VoiceIDE

@MainActor
final class BargeInTests: XCTestCase {

    func testBargeInStopsTTSBeforeStartingSTT() async {
        // Set up a full tool pipeline with mocks
        let bus = EventBus()
        let registry = ToolRegistry()
        let stateStore = AppStateStore()
        let convStore = ConversationStore()
        let mockTTS = MockTextToSpeech()
        let mockSTT = MockSpeechTranscriber()

        registry.register(STTStartTool(transcriber: mockSTT, onPartial: { _ in }))
        registry.register(STTStopTool(transcriber: mockSTT))
        registry.register(TTSSpeakTool(tts: mockTTS))
        registry.register(TTSStopTool(tts: mockTTS))
        registry.register(ConvoSetStateTool(stateStore: stateStore))
        registry.register(ConvoAppendMessageTool(store: convStore))

        let router = ToolRouter(registry: registry, eventBus: bus)

        // Simulate: app is in Speaking state
        stateStore.current = .speaking

        // Simulate barge-in sequence:
        // 1. tts.stop
        // 2. convo.setState(listening)
        // 3. stt.start

        let bargeInEvents = [
            Event.toolCall(name: "tts.stop", arguments: "{}", callId: "barge-stop"),
            Event.toolCall(name: "convo.setState", arguments: "{\"state\":\"listening\"}", callId: "barge-state"),
            Event.toolCall(name: "stt.start", arguments: "{\"mode\":\"tapToToggle\"}", callId: "barge-stt"),
        ]

        await router.processEvents(bargeInEvents)

        // Verify tts.stop was called
        XCTAssertEqual(mockTTS.stopCallCount, 1, "TTS stop should be called once")

        // Verify stt.start was called
        XCTAssertEqual(mockSTT.startCallCount, 1, "STT start should be called once")

        // Verify ordering: tts.stop result appears before stt.start call
        let toolCallNames = bus.events.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.name }
            return nil
        }

        guard let ttsStopIndex = toolCallNames.firstIndex(of: "tts.stop"),
              let sttStartIndex = toolCallNames.firstIndex(of: "stt.start") else {
            XCTFail("Both tts.stop and stt.start should be in events")
            return
        }

        XCTAssertTrue(ttsStopIndex < sttStartIndex,
                       "tts.stop must be called before stt.start for barge-in")

        // State should be listening
        XCTAssertEqual(stateStore.current, .listening)
    }

    func testBargeInSequenceInEventBus() async {
        let bus = EventBus()
        let registry = ToolRegistry()
        let stateStore = AppStateStore()
        let mockTTS = MockTextToSpeech()
        let mockSTT = MockSpeechTranscriber()

        registry.register(TTSStopTool(tts: mockTTS))
        registry.register(STTStartTool(transcriber: mockSTT, onPartial: { _ in }))
        registry.register(ConvoSetStateTool(stateStore: stateStore))

        let router = ToolRouter(registry: registry, eventBus: bus)

        // Process barge-in
        let events = [
            Event.toolCall(name: "tts.stop", arguments: "{}", callId: "b1"),
            Event.toolCall(name: "convo.setState", arguments: "{\"state\":\"listening\"}", callId: "b2"),
            Event.toolCall(name: "stt.start", arguments: "{\"mode\":\"tapToToggle\"}", callId: "b3"),
        ]

        await router.processEvents(events)

        // Verify event bus has correct interleaving:
        // toolCall(tts.stop), toolResult, toolCall(setState), toolResult, toolCall(stt.start), toolResult
        XCTAssertEqual(bus.events.count, 6)

        // Verify alternating call/result pattern
        for i in stride(from: 0, to: bus.events.count, by: 2) {
            if case .toolCall = bus.events[i].kind {
                // OK
            } else {
                XCTFail("Event at index \(i) should be a tool.call")
            }

            if case .toolResult = bus.events[i + 1].kind {
                // OK
            } else {
                XCTFail("Event at index \(i + 1) should be a tool.result")
            }
        }
    }

    func testSpeakingStateTriggersTTSStop() async {
        // This tests the ViewModel logic conceptually:
        // When in speaking state and user taps mic, tts.stop should be first tool call
        let bus = EventBus()
        let registry = ToolRegistry()
        let stateStore = AppStateStore()
        let mockTTS = MockTextToSpeech()
        let mockSTT = MockSpeechTranscriber()

        registry.register(TTSStopTool(tts: mockTTS))
        registry.register(STTStartTool(transcriber: mockSTT, onPartial: { _ in }))
        registry.register(ConvoSetStateTool(stateStore: stateStore))

        let router = ToolRouter(registry: registry, eventBus: bus)

        // Simulate: state is speaking
        stateStore.current = .speaking

        // First action must be tts.stop
        let ttsStopCall = Event.ToolCall(callId: "stop-1", name: "tts.stop", arguments: "{}")
        await router.dispatch(ttsStopCall)

        XCTAssertEqual(mockTTS.stopCallCount, 1)

        // Then start listening
        let sttStartCall = Event.ToolCall(callId: "start-1", name: "stt.start", arguments: "{\"mode\":\"tapToToggle\"}")
        await router.dispatch(sttStartCall)

        XCTAssertEqual(mockSTT.startCallCount, 1)
    }
}
