import Foundation

/// Protocol for speech-to-text engines.
/// Phase 1 uses WhisperKit; swappable for other engines later.
protocol SpeechTranscriber: AnyObject, Sendable {
    /// Warm up model/runtime so first user transcription has no cold-start delay.
    func preload() async

    /// Begin listening and transcribing.
    func start() async throws

    /// Stop listening and return the final transcript.
    func stop() async throws -> String

    /// Stream of partial transcripts emitted while listening.
    var partials: AsyncStream<String> { get }

    /// Whether the transcriber is currently active.
    var isListening: Bool { get }
}

extension SpeechTranscriber {
    func preload() async {}
}
