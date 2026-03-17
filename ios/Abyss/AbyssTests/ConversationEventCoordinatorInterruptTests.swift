import XCTest
@testable import Abyss

@MainActor
final class ConversationEventCoordinatorInterruptTests: XCTestCase {

    func testHandsFreeInterruptedDraftStaysVisibleUntilTranscriptIsClassified() async {
        let harness = makeHarness()
        await seedAssistantDraft(harness, liveResponseId: "live-1", text: "Draft reply")

        await harness.coordinator.handleInboundEvent(
            Event.assistantAudioInterrupted(
                "echo_interrupt",
                liveResponseId: "live-1",
                sessionId: "session-test"
            )
        )

        XCTAssertEqual(harness.conversationStore.messages.count, 1)
        XCTAssertEqual(harness.conversationStore.messages.last?.text, "Draft reply")
        XCTAssertTrue(harness.conversationStore.messages.last?.isPartial == true)
    }

    func testLocalInterruptSuppressesTrailingAssistantEventsForActiveResponse() async {
        let harness = makeHarness()
        await seedAssistantDraft(harness, liveResponseId: "live-1", text: "Draft reply")

        harness.eventBus.emit(Event.audioOutputInterrupted(
            "local_speech_start",
            sessionId: "session-test"
        ))

        await harness.coordinator.handleInboundEvent(
            Event.speechPartial("continued output", liveResponseId: "live-1", sessionId: "session-test")
        )

        XCTAssertEqual(harness.conversationStore.messages.count, 1)
        XCTAssertEqual(harness.conversationStore.messages.last?.text, "Draft reply")
        XCTAssertEqual(harness.coordinator.assistantPartialSpeech, "")
    }

    func testHandsFreeEchoTranscriptIsDroppedAndKeepsAssistantDraft() async {
        let harness = makeHarness()
        await seedAssistantDraft(harness, liveResponseId: "live-1", text: "Draft reply")

        await harness.coordinator.handleInboundEvent(
            Event.assistantAudioInterrupted(
                "echo_interrupt",
                liveResponseId: "live-1",
                sessionId: "session-test"
            )
        )
        await harness.coordinator.handleInboundEvent(
            Event.transcriptFinal("Draft reply", sessionId: "session-test")
        )

        XCTAssertEqual(harness.conversationStore.messages.count, 1)
        XCTAssertEqual(harness.conversationStore.messages.last?.text, "Draft reply")
        XCTAssertEqual(
            harness.eventBus.events.contains(where: {
                if case .userAudioTranscriptFinal = $0.kind { return true }
                return false
            }),
            false
        )
    }

    func testHandsFreeGenuineBargeInInvalidatesAssistantDraft() async {
        let harness = makeHarness()
        await seedAssistantDraft(harness, liveResponseId: "live-1", text: "Draft reply")

        await harness.coordinator.handleInboundEvent(
            Event.assistantAudioInterrupted(
                "user_interrupt",
                liveResponseId: "live-1",
                sessionId: "session-test"
            )
        )
        await harness.coordinator.handleInboundEvent(
            Event.transcriptFinal("Stop. Use ripgrep instead.", sessionId: "session-test")
        )

        XCTAssertTrue(harness.conversationStore.messages.isEmpty)
        XCTAssertTrue(
            harness.eventBus.events.contains(where: {
                if case .userAudioTranscriptFinal = $0.kind { return true }
                return false
            })
        )
    }

    func testLocalInterruptEchoTranscriptKeepsAssistantDraft() async {
        let harness = makeHarness()
        await seedAssistantDraft(harness, liveResponseId: "live-1", text: "Draft reply")

        harness.eventBus.emit(Event.audioOutputInterrupted(
            "local_speech_start",
            sessionId: "session-test"
        ))
        await harness.coordinator.handleInboundEvent(
            Event.transcriptFinal("Draft reply", sessionId: "session-test")
        )

        XCTAssertEqual(harness.conversationStore.messages.count, 1)
        XCTAssertEqual(harness.conversationStore.messages.last?.text, "Draft reply")
        XCTAssertEqual(
            harness.eventBus.events.contains(where: {
                if case .userAudioTranscriptFinal = $0.kind { return true }
                return false
            }),
            false
        )
    }

    func testHandsFreeInterruptTimeoutKeepsAssistantDraftVisible() async {
        let harness = makeHarness()
        await seedAssistantDraft(harness, liveResponseId: "live-1", text: "Draft reply")

        await harness.coordinator.handleInboundEvent(
            Event.assistantAudioInterrupted(
                "echo_interrupt",
                liveResponseId: "live-1",
                sessionId: "session-test"
            )
        )

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(harness.conversationStore.messages.count, 1)
        XCTAssertEqual(harness.conversationStore.messages.last?.text, "Draft reply")
        XCTAssertTrue(harness.conversationStore.messages.last?.isPartial == true)
    }

    private func makeHarness() -> CoordinatorHarness {
        let eventBus = EventBus()
        let conversationStore = ConversationStore()
        let registry = ToolRegistry()
        let toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
        let audioPipeline = ConversationAudioPipeline(
            transcriber: MockSpeechTranscriber(),
            tts: MockTextToSpeech(),
            transcriptFormatter: FastTranscriptFormatter(),
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: AppStateStore(),
            sessionId: "session-test",
            remoteVoiceCapture: CoordinatorRemoteVoiceCapture(),
            sendConductorEvent: { _, _ in },
            handleError: { _ in }
        )
        audioPipeline.updateRecordingMode(.vadAuto)

        let agentManager = ConversationAgentManager(
            eventBus: eventBus,
            toolRouter: toolRouter,
            sessionId: "session-test",
            conversationMessages: { conversationStore.messages },
            sendConductorEvent: { _ in },
            shouldUseWebhookUpdates: { false },
            isUsingServerClient: { true }
        )

        let coordinator = ConversationEventCoordinator(
            conversationStore: conversationStore,
            eventBus: eventBus,
            toolRouter: toolRouter,
            audioPipeline: audioPipeline,
            agentManager: agentManager,
            sessionId: "session-test",
            sendConductorEvent: { _, _ in }
        )

        return CoordinatorHarness(
            coordinator: coordinator,
            conversationStore: conversationStore,
            eventBus: eventBus
        )
    }

    private func seedAssistantDraft(
        _ harness: CoordinatorHarness,
        liveResponseId: String,
        text: String
    ) async {
        harness.conversationStore.append(ConversationMessage(
            role: .assistant,
            text: text,
            isPartial: true,
            liveResponseId: liveResponseId
        ))
        await harness.coordinator.handleInboundEvent(
            Event.speechPartial(text, liveResponseId: liveResponseId, sessionId: "session-test")
        )
    }
}

@MainActor
private struct CoordinatorHarness {
    let coordinator: ConversationEventCoordinator
    let conversationStore: ConversationStore
    let eventBus: EventBus
}

@MainActor
private final class CoordinatorRemoteVoiceCapture: RemoteVoiceCapturing {
    var isStreaming: Bool = false
    var isAssistantAudioPlaying: Bool = false

    func start(
        onChunk: @escaping (String) -> Void,
        onInputLevel: @escaping (Float) -> Void
    ) async throws {
        isStreaming = true
    }

    func stop() async {
        isStreaming = false
    }

    func appendAssistantAudio(_ data: Data, sampleRate: Double) async throws {}

    func finishAssistantAudio() async {}

    func stopAssistantAudio() async {}
}
