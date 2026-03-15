import Foundation

/// Protocol for speech-to-text engines.
/// Phase 1 uses WhisperKit; swappable for other engines later.
protocol SpeechTranscriber: AnyObject, Sendable {
    /// Warm up model/runtime so first user transcription has no cold-start delay.
    func preload() async

    /// Prepare the audio engine so subsequent start/stop cycles are near-instant.
    /// Called once when the pipeline is set up; the engine stays warm until teardown.
    func warmUp() async throws

    /// Begin listening and transcribing (engine must already be warm).
    func start() async throws

    /// Stop listening and return the final transcript. Engine stays warm for next press.
    func stop() async throws -> String

    /// Tear down the audio engine and release hardware resources.
    func tearDown()

    /// Stream of partial transcripts emitted while listening.
    var partials: AsyncStream<String> { get }

    /// Whether the transcriber is currently active.
    var isListening: Bool { get }

    /// Whether the audio engine is warmed up and ready for instant start.
    var isWarmedUp: Bool { get }
}

extension SpeechTranscriber {
    func preload() async {}
    func warmUp() async throws {}
    func tearDown() {}
    var isWarmedUp: Bool { false }
}
