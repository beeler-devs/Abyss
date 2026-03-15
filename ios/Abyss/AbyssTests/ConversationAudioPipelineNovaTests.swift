import XCTest
@testable import Abyss

@MainActor
final class ConversationAudioPipelineNovaTests: XCTestCase {

    func testNovaVADAutoStartSendsRecordingMode() async {
        let harness = makeHarness()

        harness.pipeline.updateVoiceMode(.novaSonic)
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)

        await waitForCondition {
            harness.sentEvents.events.contains(where: {
                if case .userAudioStreamStart(let start) = $0.kind {
                    return start.recordingMode == "vad_auto"
                }
                return false
            })
        }

        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
    }

    func testNovaPushToTalkStopPadsTrailingSilenceBeforeEnd() async {
        let harness = makeHarness()

        harness.pipeline.updateVoiceMode(.novaSonic)
        harness.pipeline.updateRecordingMode(.pushToTalk)
        harness.pipeline.setChatActive(true)

        harness.pipeline.micPressed()
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }
        harness.pipeline.micReleased()

        await waitForCondition(timeoutNanoseconds: 3_000_000_000) {
            harness.sentEvents.events.contains(where: {
                if case .userAudioStreamEnd = $0.kind { return true }
                return false
            })
        }

        let startEvents = harness.sentEvents.events.compactMap { event -> Event.UserAudioStreamStart? in
            if case .userAudioStreamStart(let start) = event.kind { return start }
            return nil
        }
        XCTAssertEqual(startEvents.map(\.recordingMode), ["push_to_talk"])

        let sentKinds = harness.sentEvents.events.map(\.kind)
        guard let endIndex = sentKinds.firstIndex(where: {
            if case .userAudioStreamEnd = $0 { return true }
            return false
        }) else {
            XCTFail("Expected user.audio.stream.end event")
            return
        }

        let silenceChunks = harness.sentEvents.events[..<endIndex].compactMap { event -> Event.UserAudioStreamChunk? in
            if case .userAudioStreamChunk(let chunk) = event.kind { return chunk }
            return nil
        }
        XCTAssertEqual(silenceChunks.count, 18)
        XCTAssertEqual(Set(silenceChunks.map(\.audio)).count, 1)
        XCTAssertFalse(harness.remoteVoiceCapture.isStreaming)
    }

    func testNovaPushToTalkQueuesNextStartUntilPreviousStopFinishes() async {
        let harness = makeHarness()

        harness.pipeline.updateVoiceMode(.novaSonic)
        harness.pipeline.updateRecordingMode(.pushToTalk)
        harness.pipeline.setChatActive(true)
        harness.remoteVoiceCapture.stopDelayNanoseconds = 200_000_000

        harness.pipeline.micPressed()
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        harness.pipeline.micReleased()
        try? await Task.sleep(nanoseconds: 50_000_000)
        harness.pipeline.micPressed()

        await waitForCondition(timeoutNanoseconds: 4_000_000_000) {
            harness.sentEvents.events.filter {
                if case .userAudioStreamStart = $0.kind { return true }
                return false
            }.count == 2
        }

        let kinds = harness.sentEvents.events.map(\.kind)
        guard let firstEndIndex = kinds.firstIndex(where: {
            if case .userAudioStreamEnd = $0 { return true }
            return false
        }) else {
            XCTFail("Expected first user.audio.stream.end event")
            return
        }

        guard let secondStartIndex = kinds.lastIndex(where: {
            if case .userAudioStreamStart = $0 { return true }
            return false
        }) else {
            XCTFail("Expected second user.audio.stream.start event")
            return
        }

        XCTAssertGreaterThan(secondStartIndex, firstEndIndex)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
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
    private var onChunk: ((String) -> Void)?
    var stopDelayNanoseconds: UInt64 = 0

    func start(onChunk: @escaping (String) -> Void) async throws {
        isStreaming = true
        self.onChunk = onChunk
    }

    func stop() async {
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
        isStreaming = false
        onChunk = nil
    }
}

@MainActor
private final class SentEventStore {
    var events: [Event] = []
}
