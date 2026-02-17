import Foundation

/// Tool: stt.stop
/// Stops speech-to-text recording and returns the final transcript.
struct STTStopTool: Tool, @unchecked Sendable {
    static let name = "stt.stop"

    struct Arguments: Codable, Sendable {
        // No arguments needed
        init() {}
    }

    struct Result: Codable, Sendable {
        let finalTranscript: String
    }

    private let transcriber: SpeechTranscriber

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let transcript = try await transcriber.stop()
        return Result(finalTranscript: transcript)
    }
}
