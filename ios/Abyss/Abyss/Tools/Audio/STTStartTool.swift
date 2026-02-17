import Foundation

/// Tool: stt.start
/// Starts speech-to-text recording.
struct STTStartTool: Tool, @unchecked Sendable {
    static let name = "stt.start"

    struct Arguments: Codable, Sendable {
        let mode: String // "tapToToggle" or "pressAndHold"
    }

    struct Result: Codable, Sendable {
        let started: Bool
    }

    private let transcriber: SpeechTranscriber
    private let onPartial: @MainActor @Sendable (String) -> Void

    init(transcriber: SpeechTranscriber, onPartial: @MainActor @escaping @Sendable (String) -> Void) {
        self.transcriber = transcriber
        self.onPartial = onPartial
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        try await transcriber.start()

        // Start listening for partials in background
        let partials = transcriber.partials
        let callback = onPartial
        Task { @MainActor in
            for await partial in partials {
                callback(partial)
            }
        }

        return Result(started: true)
    }
}
