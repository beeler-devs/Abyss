import Foundation

/// Tool: tts.stop
/// Stops any currently playing TTS audio. Used for barge-in.
struct TTSStopTool: Tool, @unchecked Sendable {
    static let name = "tts.stop"

    struct Arguments: Codable, Sendable {
        init() {}
    }

    struct Result: Codable, Sendable {
        let stopped: Bool
    }

    private let tts: TextToSpeech

    init(tts: TextToSpeech) {
        self.tts = tts
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let wasSpeaking = tts.isSpeaking
        await tts.stop()
        return Result(stopped: wasSpeaking)
    }
}
