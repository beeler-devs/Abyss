import Foundation

/// Protocol for text-to-speech engines.
/// Phase 1 uses ElevenLabs; swappable for other engines later.
protocol TextToSpeech: AnyObject, Sendable {
    /// Speak the given text. Streams audio as it arrives.
    func speak(_ text: String) async throws

    /// Stop any currently playing speech.
    func stop() async

    /// Whether speech is currently being played.
    var isSpeaking: Bool { get }
}
