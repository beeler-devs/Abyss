import XCTest
@testable import Abyss

@MainActor
final class PTTRaceConditionTests: XCTestCase {

    /// Reproduces the bug where a quick tap (press + immediate release)
    /// fails to stop recording because `isStartingRecording` wasn't set
    /// synchronously in `micPressed()`.
    func testQuickTapReleaseSendsTranscript() async {
        let transcriber = MockSpeechTranscriber()
        let eventBus = EventBus()
        let registry = ToolRegistry()
        let toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
        var sentEvents: [Event] = []

        let pipeline = ConversationAudioPipeline(
            transcriber: transcriber,
            tts: MockTextToSpeech(),
            transcriptFormatter: FastTranscriptFormatter(),
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: AppStateStore(),
            sessionId: "session-ptt-race",
            sendConductorEvent: { event, _ in
                sentEvents.append(event)
            },
            handleError: { _ in }
        )

        pipeline.updateRecordingMode(.pushToTalk)
        pipeline.setChatActive(true)

        // Simulate quick tap: press and immediately release
        // before the Task in micPressed() can execute
        pipeline.micPressed()
        pipeline.micReleased()

        // Give async work time to complete
        try? await Task.sleep(nanoseconds: 500_000_000)

        // The transcriber should have been started AND stopped
        XCTAssertEqual(transcriber.startCallCount, 1, "Transcriber should have started once")
        XCTAssertEqual(transcriber.stopCallCount, 1, "Transcriber should have stopped once (release was not lost)")

        // A final transcript event should have been sent to the conductor
        let transcriptEvents = sentEvents.filter {
            if case .userAudioTranscriptFinal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(transcriptEvents.count, 1, "Should have sent exactly one transcript")
    }

    /// Verifies that normal hold-and-release PTT still works.
    func testHoldAndReleaseSendsTranscript() async {
        let transcriber = MockSpeechTranscriber()
        let eventBus = EventBus()
        let registry = ToolRegistry()
        let toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
        var sentEvents: [Event] = []

        let pipeline = ConversationAudioPipeline(
            transcriber: transcriber,
            tts: MockTextToSpeech(),
            transcriptFormatter: FastTranscriptFormatter(),
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: AppStateStore(),
            sessionId: "session-ptt-hold",
            sendConductorEvent: { event, _ in
                sentEvents.append(event)
            },
            handleError: { _ in }
        )

        pipeline.updateRecordingMode(.pushToTalk)
        pipeline.setChatActive(true)

        pipeline.micPressed()

        // Wait for recording to actually start
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(transcriber.isListening, "Transcriber should be listening after hold")

        pipeline.micReleased()

        // Wait for processing
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(transcriber.stopCallCount, 1)

        let transcriptEvents = sentEvents.filter {
            if case .userAudioTranscriptFinal = $0.kind { return true }
            return false
        }
        XCTAssertEqual(transcriptEvents.count, 1)
    }
}
