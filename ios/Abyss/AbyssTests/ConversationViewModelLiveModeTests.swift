import XCTest
@testable import Abyss

@MainActor
final class ConversationViewModelLiveModeTests: XCTestCase {

    func testActiveChatAutoStartsListeningWhenUnmuted() async {
        let mockSTT = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()
        let viewModel = ConversationViewModel(
            conductor: LocalConductorStub(),
            transcriber: mockSTT,
            tts: mockTTS
        )

        viewModel.setChatActive(true)
        await waitForCondition { mockSTT.startCallCount == 1 }

        XCTAssertTrue(mockSTT.isListening)
        XCTAssertEqual(viewModel.appState, .listening)
    }

    func testMutingStopsListeningAndBlocksAutoRestartUntilUnmuted() async {
        let mockSTT = MockSpeechTranscriber()
        let mockTTS = MockTextToSpeech()
        let viewModel = ConversationViewModel(
            conductor: LocalConductorStub(),
            transcriber: mockSTT,
            tts: mockTTS
        )

        viewModel.setChatActive(true)
        await waitForCondition { mockSTT.startCallCount == 1 }

        viewModel.setMuted(true)
        await waitForCondition { mockSTT.stopCallCount == 1 }
        XCTAssertFalse(mockSTT.isListening)

        viewModel.setChatActive(false)
        viewModel.setChatActive(true)
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(mockSTT.startCallCount, 1, "Muted chat should not auto-restart listening")

        viewModel.setMuted(false)
        await waitForCondition { mockSTT.startCallCount == 2 }
        XCTAssertTrue(mockSTT.isListening)
    }

    func testInboundIdleResumesOnlyWhenActiveAndUnmuted() async {
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
        viewModel.setChatActive(true)
        await waitForCondition { mockSTT.startCallCount == 1 }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"speaking"}"#,
            callId: "state-speaking",
            sessionId: "session-test"
        ))
        await waitForCondition { mockSTT.stopCallCount >= 1 }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"idle"}"#,
            callId: "state-idle-1",
            sessionId: "session-test"
        ))
        await waitForCondition { mockSTT.startCallCount == 2 }

        viewModel.setMuted(true)
        await waitForCondition { mockSTT.stopCallCount >= 2 }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"idle"}"#,
            callId: "state-idle-2",
            sessionId: "session-test"
        ))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(mockSTT.startCallCount, 2, "Muted chat should not auto-resume on idle")
    }

    func testInterruptStopsTTSAndReturnsToListening() async {
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
        viewModel.setChatActive(true)
        await waitForCondition { mockSTT.startCallCount == 1 }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"speaking"}"#,
            callId: "state-speaking-2",
            sessionId: "session-test"
        ))
        await waitForCondition { viewModel.appState == .speaking }

        viewModel.interruptAssistantSpeech()
        await waitForCondition { mockTTS.stopCallCount == 1 }
        await waitForCondition { viewModel.appState == .listening }
        XCTAssertGreaterThanOrEqual(mockSTT.startCallCount, 2)
    }

    private func waitForCondition(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        var waited: UInt64 = 0
        while !condition(), waited < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
            waited += pollNanoseconds
        }
    }
}
