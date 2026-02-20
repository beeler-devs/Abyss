import XCTest
@testable import Abyss

@MainActor
final class VoiceActivityDetectorTests: XCTestCase {

    func testSpeechStartsWhenCrossingSpeechThreshold() {
        let config = VoiceActivityDetector.Config(
            silenceThreshold: -40,
            speechThreshold: -35,
            silenceDuration: 0.08,
            minSpeechDuration: 0.01
        )
        let vad = VoiceActivityDetector(config: config)
        let started = expectation(description: "speech started")

        vad.onSpeechStarted = {
            started.fulfill()
        }

        vad.startMonitoring()
        vad.processAudioLevel(-30)

        wait(for: [started], timeout: 0.2)
        XCTAssertTrue(vad.isSpeaking)
    }

    func testSpeechEndsAfterConfiguredSilenceWindow() {
        let config = VoiceActivityDetector.Config(
            silenceThreshold: -40,
            speechThreshold: -35,
            silenceDuration: 0.08,
            minSpeechDuration: 0.0
        )
        let vad = VoiceActivityDetector(config: config)
        let ended = expectation(description: "speech ended")

        vad.onSpeechEnded = { _ in
            ended.fulfill()
        }

        vad.startMonitoring()
        vad.processAudioLevel(-25)
        vad.processAudioLevel(-60)

        wait(for: [ended], timeout: 0.4)
        XCTAssertFalse(vad.isSpeaking)
    }

    func testShortSpeechBurstDoesNotEmitSpeechEnded() {
        let config = VoiceActivityDetector.Config(
            silenceThreshold: -40,
            speechThreshold: -35,
            silenceDuration: 0.08,
            minSpeechDuration: 0.3
        )
        let vad = VoiceActivityDetector(config: config)
        let ended = expectation(description: "speech ended")
        ended.isInverted = true

        vad.onSpeechEnded = { _ in
            ended.fulfill()
        }

        vad.startMonitoring()
        vad.processAudioLevel(-20)
        vad.processAudioLevel(-70)

        wait(for: [ended], timeout: 0.25)
        XCTAssertFalse(vad.isSpeaking)
    }

    func testStopMonitoringResetsStateAndPreventsCallbacks() {
        let config = VoiceActivityDetector.Config(
            silenceThreshold: -40,
            speechThreshold: -35,
            silenceDuration: 0.08,
            minSpeechDuration: 0.0
        )
        let vad = VoiceActivityDetector(config: config)
        let ended = expectation(description: "speech ended")
        ended.isInverted = true

        vad.onSpeechEnded = { _ in
            ended.fulfill()
        }

        vad.startMonitoring()
        vad.processAudioLevel(-20)
        vad.stopMonitoring()
        vad.processAudioLevel(-60)

        wait(for: [ended], timeout: 0.2)
        XCTAssertFalse(vad.isMonitoring)
        XCTAssertFalse(vad.isSpeaking)
    }
}
