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

    func testSpeakingKeepsRemoteStreamOpenForHandsFreeBargeIn() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
        XCTAssertEqual(streamEndCount(in: harness.sentEvents.events), 0)
        XCTAssertEqual(harness.pipeline.appState, .speaking)
    }

    func testAssistantPlaybackLifecycleKeepsSingleContinuousRemoteStream() async {
        let harness = makeHarness()
        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition {
            harness.remoteVoiceCapture.isStreaming && self.streamStartCount(in: harness.sentEvents.events) == 1
        }

        await harness.pipeline.applyRemoteState(.speaking)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)

        let chunk = Event.AssistantAudioChunk(
            audio: Data(repeating: 1, count: 320).base64EncodedString(),
            encoding: "pcm_s16le",
            sampleRateHertz: 24_000,
            channelCount: 1,
            liveResponseId: "live-1"
        )
        await harness.pipeline.handleAssistantAudioChunk(chunk)
        XCTAssertEqual(harness.remoteVoiceCapture.appendAssistantAudioCallCount, 1)

        await harness.pipeline.handleAssistantAudioEnd()
        await harness.pipeline.applyRemoteState(.idle)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
        XCTAssertEqual(harness.pipeline.appState, .listening)
        XCTAssertEqual(streamStartCount(in: harness.sentEvents.events), 1)
        XCTAssertEqual(streamEndCount(in: harness.sentEvents.events), 0)
        XCTAssertEqual(harness.remoteVoiceCapture.finishAssistantAudioCallCount, 1)
    }

    func testListeningDoesNotRestartAlreadyStreamingRemoteCapture() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition {
            harness.remoteVoiceCapture.isStreaming && self.streamStartCount(in: harness.sentEvents.events) == 1
        }

        await harness.pipeline.applyRemoteState(.speaking)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)

        await harness.pipeline.applyRemoteState(.listening)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
        XCTAssertEqual(harness.pipeline.appState, .listening)
        XCTAssertEqual(streamStartCount(in: harness.sentEvents.events), 1)
        XCTAssertEqual(streamEndCount(in: harness.sentEvents.events), 0)
    }

    func testHandsFreeSpeechOnsetDuringSpeakingInterruptsAssistantImmediately() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)
        harness.remoteVoiceCapture.emitInputLevel(-12.0)

        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
            && self.audioOutputInterruptedCount(in: harness.sentEvents.events) == 1
        }

        XCTAssertTrue(harness.remoteVoiceCapture.isStreaming)
        XCTAssertEqual(harness.pipeline.appState, .listening)
    }

    func testHandsFreeSpeechOnsetWhileListeningDoesNotInterruptAssistant() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.remoteVoiceCapture.stopAssistantAudioCallCount, 0)
        XCTAssertEqual(audioOutputInterruptedCount(in: harness.sentEvents.events), 0)
        XCTAssertEqual(harness.pipeline.appState, .listening)
    }

    func testHandsFreeSpeechOnsetTriggersSingleBargeInPerUtterance() async {
        let harness = makeHarness()

        harness.pipeline.updateRecordingMode(.vadAuto)
        harness.pipeline.setChatActive(true)
        await waitForCondition { harness.remoteVoiceCapture.isStreaming }

        await harness.pipeline.applyRemoteState(.speaking)
        harness.remoteVoiceCapture.emitInputLevel(-12.0)
        harness.remoteVoiceCapture.emitInputLevel(-10.0)

        await waitForCondition {
            harness.remoteVoiceCapture.stopAssistantAudioCallCount == 1
        }

        XCTAssertEqual(harness.remoteVoiceCapture.stopAssistantAudioCallCount, 1)
        XCTAssertEqual(audioOutputInterruptedCount(in: harness.sentEvents.events), 1)
    }

    func testBufferedPlaybackQueueDelaysStartUntilThreshold() {
        let queue = BufferedPCMPlaybackQueue(
            startupThresholdBytes: 8,
            scheduledChunkBytes: 4
        )

        let firstDrain = queue.enqueue(Data(count: 4), bytesPerFrame: 2)
        XCTAssertEqual(firstDrain.chunks.map(\.count), [4])
        XCTAssertFalse(firstDrain.shouldStartPlayback)

        let secondDrain = queue.enqueue(Data(count: 4), bytesPerFrame: 2)
        XCTAssertEqual(secondDrain.chunks.map(\.count), [4])
        XCTAssertTrue(secondDrain.shouldStartPlayback)
        XCTAssertTrue(queue.hasBufferedAudio)
    }

    func testBufferedPlaybackQueueFlushesTailOnFinish() {
        let queue = BufferedPCMPlaybackQueue(
            startupThresholdBytes: 32,
            scheduledChunkBytes: 8
        )

        let enqueueDrain = queue.enqueue(Data(count: 12), bytesPerFrame: 4)
        XCTAssertEqual(enqueueDrain.chunks.map(\.count), [8])
        XCTAssertFalse(enqueueDrain.shouldStartPlayback)

        let finishDrain = queue.finish(bytesPerFrame: 4)
        XCTAssertEqual(finishDrain.chunks.map(\.count), [4])
        XCTAssertTrue(finishDrain.shouldStartPlayback)
        XCTAssertTrue(queue.hasBufferedAudio)
    }

    func testBufferedPlaybackQueueResetClearsPendingPlayback() {
        let queue = BufferedPCMPlaybackQueue(
            startupThresholdBytes: 8,
            scheduledChunkBytes: 4
        )

        _ = queue.enqueue(Data(count: 8), bytesPerFrame: 2)
        XCTAssertTrue(queue.hasBufferedAudio)

        queue.reset()

        XCTAssertFalse(queue.hasBufferedAudio)
        let nextDrain = queue.enqueue(Data(count: 4), bytesPerFrame: 2)
        XCTAssertFalse(nextDrain.shouldStartPlayback)
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

    private func audioOutputInterruptedCount(in events: [Event]) -> Int {
        events.reduce(into: 0) { count, event in
            if case .audioOutputInterrupted = event.kind {
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
    private(set) var appendAssistantAudioCallCount = 0
    private(set) var finishAssistantAudioCallCount = 0
    private(set) var stopAssistantAudioCallCount = 0
    private var onInputLevel: ((Float) -> Void)?

    func start(
        onChunk: @escaping (String) -> Void,
        onInputLevel: @escaping (Float) -> Void
    ) async throws {
        isStreaming = true
        self.onInputLevel = onInputLevel
    }

    func stop() async {
        isStreaming = false
        onInputLevel = nil
    }

    func appendAssistantAudio(_ data: Data, sampleRate: Double) async throws {
        appendAssistantAudioCallCount += 1
    }

    func finishAssistantAudio() async {
        finishAssistantAudioCallCount += 1
    }

    func stopAssistantAudio() async {
        stopAssistantAudioCallCount += 1
    }

    func emitInputLevel(_ level: Float) {
        onInputLevel?(level)
    }
}

@MainActor
private final class SentEventStore {
    var events: [Event] = []
}
