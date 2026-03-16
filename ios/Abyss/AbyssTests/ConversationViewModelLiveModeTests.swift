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

    func testMutedInboundListeningStateIsCoercedToIdle() async {
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

        viewModel.setMuted(true)
        await waitForCondition { mockSTT.stopCallCount == 1 }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"listening"}"#,
            callId: "state-listening-muted",
            sessionId: "session-test"
        ))

        await waitForCondition { viewModel.appState == .idle }
        XCTAssertEqual(viewModel.appState, .idle)
    }

    func testMutingFlushesPendingSpeechAndSendsFinalTranscriptEvent() async {
        let mockConductor = MockConductorClient()
        let mockSTT = MockSpeechTranscriber()
        mockSTT.mockFinalTranscript = "flush pending speech"
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

        viewModel.setMuted(true)
        await waitForCondition { mockSTT.stopCallCount == 1 }
        await waitForCondition {
            latestFinalTranscript(in: mockConductor.sentEvents) != nil
        }

        XCTAssertFalse(mockSTT.isListening)
        XCTAssertEqual(latestFinalTranscript(in: mockConductor.sentEvents), "Flush pending speech.")
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

    func testInterruptEmitsTTSStopBeforeAudioInterruptedEvent() async {
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

        viewModel.interruptAssistantSpeech()
        await waitForCondition {
            viewModel.eventBus.events.contains(where: {
                if case .audioOutputInterrupted = $0.kind { return true }
                return false
            })
        }

        let events = viewModel.eventBus.events
        guard let ttsStopIndex = events.firstIndex(where: {
            if case .toolCall(let call) = $0.kind { return call.name == "tts.stop" }
            return false
        }) else {
            XCTFail("Expected tts.stop event")
            return
        }

        guard let interruptedIndex = events.firstIndex(where: {
            if case .audioOutputInterrupted = $0.kind { return true }
            return false
        }) else {
            XCTFail("Expected audio.output.interrupted event")
            return
        }

        XCTAssertLessThan(ttsStopIndex, interruptedIndex)
    }

    func testInterruptedLiveDraftDoesNotFinalizeWhenStaleFinalAppendArrives() async {
        let mockConductor = MockConductorClient()
        let viewModel = ConversationViewModel(
            conductorClient: mockConductor,
            transcriber: MockSpeechTranscriber(),
            tts: MockTextToSpeech(),
            autoStartSession: true
        )

        try? await Task.sleep(nanoseconds: 80_000_000)
        viewModel.setChatActive(true)

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.appendMessage",
            arguments: encodeAppendArguments(
                role: "assistant",
                text: "Draft reply",
                isPartial: true,
                liveResponseId: "live-1"
            ),
            callId: "append-partial-live-1",
            sessionId: "session-test"
        ))
        await waitForCondition {
            viewModel.messages.count == 1 && viewModel.messages.last?.isPartial == true
        }

        mockConductor.emitInbound(Event.assistantAudioInterrupted(
            "user_interrupt",
            liveResponseId: "live-1",
            sessionId: "session-test"
        ))
        await waitForCondition {
            viewModel.messages.isEmpty && viewModel.assistantPartialSpeech.isEmpty
        }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.appendMessage",
            arguments: encodeAppendArguments(
                role: "assistant",
                text: "Draft reply",
                isPartial: false,
                liveResponseId: "live-1"
            ),
            callId: "append-final-live-1",
            sessionId: "session-test"
        ))
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testVoiceProviderFailureClearsLiveOverlayAndRestoresListening() async {
        let mockConductor = MockConductorClient()
        let viewModel = ConversationViewModel(
            conductorClient: mockConductor,
            transcriber: MockSpeechTranscriber(),
            tts: MockTextToSpeech(),
            autoStartSession: true
        )

        try? await Task.sleep(nanoseconds: 80_000_000)
        viewModel.setChatActive(true)
        await waitForCondition { viewModel.appState == .listening }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"thinking"}"#,
            callId: "state-thinking-live-fail",
            sessionId: "session-test"
        ))
        await waitForCondition { viewModel.appState == .thinking }

        mockConductor.emitInbound(Event.speechPartial(
            "Still working",
            liveResponseId: "live-fail",
            sessionId: "session-test"
        ))
        await waitForCondition { viewModel.assistantPartialSpeech == "Still working" }

        mockConductor.emitInbound(Event.error(
            code: "voice_provider_failed",
            message: "Timed out waiting for audio bytes (59 seconds).",
            sessionId: "session-test"
        ))
        await waitForCondition {
            viewModel.assistantPartialSpeech.isEmpty && viewModel.appState == .listening
        }

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.appState, .listening)
    }

    func testLiveFinalAppendFinalizesExistingDraftAndClearsLiveOverlay() async {
        let mockConductor = MockConductorClient()
        let viewModel = ConversationViewModel(
            conductorClient: mockConductor,
            transcriber: MockSpeechTranscriber(),
            tts: MockTextToSpeech(),
            autoStartSession: true
        )

        try? await Task.sleep(nanoseconds: 80_000_000)
        viewModel.setChatActive(true)
        await waitForCondition { viewModel.appState == .listening }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"thinking"}"#,
            callId: "state-thinking-live-final",
            sessionId: "session-test"
        ))
        await waitForCondition { viewModel.appState == .thinking }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.appendMessage",
            arguments: encodeAppendArguments(
                role: "assistant",
                text: "Draft reply",
                isPartial: true,
                liveResponseId: "live-final"
            ),
            callId: "append-partial-live-final",
            sessionId: "session-test"
        ))
        await waitForCondition {
            viewModel.messages.count == 1 && viewModel.messages.last?.isPartial == true
        }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.appendMessage",
            arguments: encodeAppendArguments(
                role: "assistant",
                text: "Draft reply",
                isPartial: false,
                liveResponseId: "live-final"
            ),
            callId: "append-final-live-final",
            sessionId: "session-test"
        ))
        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"idle"}"#,
            callId: "state-idle-live-final",
            sessionId: "session-test"
        ))

        await waitForCondition {
            viewModel.messages.count == 1
                && viewModel.messages.last?.isPartial == false
                && viewModel.assistantPartialSpeech.isEmpty
                && viewModel.appState == .listening
        }

        XCTAssertEqual(viewModel.messages.last?.text, "Draft reply")
        XCTAssertEqual(viewModel.messages.last?.liveResponseId, "live-final")
    }

    func testLiveInterruptButtonIgnoresLocalTTSPublisherState() {
        XCTAssertFalse(shouldShowInterruptButton(
            recordingMode: .vadAuto,
            appState: .idle,
            isTTSSpeaking: true
        ))
        XCTAssertTrue(shouldShowInterruptButton(
            recordingMode: .vadAuto,
            appState: .speaking,
            isTTSSpeaking: false
        ))
    }

    func testPTTInterruptButtonStillHonorsLocalTTSPublisherState() {
        XCTAssertTrue(shouldShowInterruptButton(
            recordingMode: .pushToTalk,
            appState: .idle,
            isTTSSpeaking: true
        ))
        XCTAssertTrue(shouldShowInterruptButton(
            recordingMode: .pushToTalk,
            appState: .speaking,
            isTTSSpeaking: false
        ))
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

    private func latestFinalTranscript(in events: [Event]) -> String? {
        for event in events.reversed() {
            if case .userAudioTranscriptFinal(let transcript) = event.kind {
                return transcript.text
            }
        }
        return nil
    }

    private func encodeAppendArguments(
        role: String,
        text: String,
        isPartial: Bool,
        liveResponseId: String
    ) -> String {
        let arguments = ConvoAppendMessageTool.Arguments(
            role: role,
            text: text,
            isPartial: isPartial,
            liveResponseId: liveResponseId
        )
        let data = try! JSONEncoder().encode(arguments)
        return String(decoding: data, as: UTF8.self)
    }
}
