import XCTest
@testable import Abyss

@MainActor
final class ConversationStoreTests: XCTestCase {

    func testUpsertStreamingMessageAccumulatesDeltaChunksIntoSinglePartial() {
        let store = ConversationStore()

        store.upsertStreamingMessage(role: .assistant, text: "First sentence.")
        store.upsertStreamingMessage(role: .assistant, text: "Second sentence.")

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.role, .assistant)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, true)
    }

    func testUpsertStreamingMessagePrefersGrowingSnapshots() {
        let store = ConversationStore()

        store.upsertStreamingMessage(role: .assistant, text: "First sentence.")
        store.upsertStreamingMessage(role: .assistant, text: "First sentence. Second sentence.")

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, true)
    }

    func testFinalizeLastPartialMessageTurnsPendingAssistantTurnWhite() {
        let store = ConversationStore()

        store.upsertStreamingMessage(role: .assistant, text: "First sentence.")
        store.upsertStreamingMessage(role: .assistant, text: "Second sentence.")
        store.finalizeLastPartialMessage(role: .assistant)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, false)
    }

    func testIdleStateFinalizesPendingAssistantSpeechWhenFinalAppendNeverArrives() async {
        let mockConductor = MockConductorClient()
        let viewModel = ConversationViewModel(
            conductorClient: mockConductor,
            transcriber: MockSpeechTranscriber(),
            tts: MockTextToSpeech(),
            autoStartSession: true
        )

        try? await Task.sleep(nanoseconds: 80_000_000)

        mockConductor.emitInbound(Event.speechPartial("First sentence."))
        await waitForCondition {
            viewModel.messages.last?.text == "First sentence." && viewModel.messages.last?.isPartial == true
        }

        mockConductor.emitInbound(Event.speechPartial("Second sentence."))
        await waitForCondition {
            viewModel.messages.last?.text == "First sentence. Second sentence."
        }

        mockConductor.emitInbound(Event.toolCall(
            name: "convo.setState",
            arguments: #"{"state":"idle"}"#,
            callId: "assistant-idle",
            sessionId: "session-test"
        ))

        await waitForCondition {
            viewModel.messages.last?.text == "First sentence. Second sentence."
                && viewModel.messages.last?.isPartial == false
                && viewModel.assistantPartialSpeech.isEmpty
        }
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
