import Foundation

/// Tool: tts.speak
/// Speaks text using the TTS engine (ElevenLabs).
struct TTSSpeakTool: Tool, @unchecked Sendable {
    static let name = "tts.speak"

    struct Arguments: Codable, Sendable {
        let text: String
    }

    struct Result: Codable, Sendable {
        let spoken: Bool
    }

    private let tts: TextToSpeech

    init(tts: TextToSpeech) {
        self.tts = tts
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        try await tts.speak(arguments.text)
        return Result(spoken: true)
    }
}
