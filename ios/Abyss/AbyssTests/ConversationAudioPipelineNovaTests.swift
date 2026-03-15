import XCTest
@testable import Abyss

@MainActor
final class ConversationAudioPipelineNovaTests: XCTestCase {

    func testVADAutoStartsRemoteStreamWhenChatActivates() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)

        await waitForCondition {
            harness.remoteVoiceCapture.isStreaming && self.streamStartCount(in: harness.sentEvents.events) == 1
        }

        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
        XCTAssertEqual(harness.pipeline.appState, .listening)
    }

    func testSpeakingStopsRemoteStreamAndSendsStreamEnd() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)

        await waitForCondition {
            !harness.remoteVoiceCapture.isStreaming && self.streamEndCount(in: harness.sentEvents.events) == 1
        }

        XCTAssertEqual(harness.pipeline.appState, .speaking)
    }

    func testListeningRestartsRemoteStreamAfterSpeakingStopsIt() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)
        await waitForCondition { !harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.listening)

        await waitForCondition {
            harness.remoteVoiceCapture.isStreaming && self.streamStartCount(in: harness.sentEvents.events) == 2
        }

        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
        XCTAssertEqual(harness.pipeline.appState, .listening)
    }

    private func makeHarness() -> PipelineHarness {
        let eventBus = EventBus()
        let registry = ToolRegistry()
        let toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
        let remoteVoiceCapture = MockRemoteVoiceCapture()
        let sentEvents = SentEventStore()

        let pipeline = ConversationAudioPipeline(
            transcriber: MockSpeechTranscriber(),
            tts: MockTextToSpeech(),
            transcriptFormatter: FastTranscriptFormatter(),
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: AppStateStore(),
            sessionId: "session-test",
            remoteVoiceCapture: remoteVoiceCapture,
            sendConductorEvent: { event, _ in
                sentEvents.events.append(event)
            },
            handleError: { _ in }
        )

        return PipelineHarness(
            pipeline: pipeline,
            remoteVoiceCapture: remoteVoiceCapture,
            sentEvents: sentEvents
        )
    }

    private func streamStartCount(in events: [Event]) -> Int {
        events.reduce(into: 0) { count, event in
            if case .userAudioStreamStart = event.kind {
                count += 1
            }
        }
    }

    private func streamEndCount(in events: [Event]) -> Int {
        events.reduce(into: 0) { count, event in
            if case .userAudioStreamEnd = event.kind {
                count += 1
            }
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

@MainActor
private struct PipelineHarness {
    let pipeline: ConversationAudioPipeline
    let remoteVoiceCapture: MockRemoteVoiceCapture
    let sentEvents: SentEventStore
}

@MainActor
private final class MockRemoteVoiceCapture: RemoteVoiceCapturing {
    private(set) var isStreaming = false

    func start(onChunk: @escaping (String) -> Void) async throws {
        isStreaming = true
    }

    func stop() async {
        isStreaming = false
    }
}

@MainActor
private final class SentEventStore {
    var events: [Event] = []
}
