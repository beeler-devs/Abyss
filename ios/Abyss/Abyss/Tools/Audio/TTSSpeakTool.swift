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
    private let isMuted: @MainActor @Sendable () -> Bool

    init(tts: TextToSpeech, isMuted: @escaping @MainActor @Sendable () -> Bool = { false }) {
        self.tts = tts
        self.isMuted = isMuted
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        guard !isMuted() else {
            return Result(spoken: false)
        }
        try await tts.speak(arguments.text)
        return Result(spoken: true)
    }
}
