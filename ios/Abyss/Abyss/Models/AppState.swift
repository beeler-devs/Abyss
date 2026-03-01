import Foundation

/// The top-level state of the voice agent app.
enum AppState: String, Codable, CaseIterable, Sendable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
    case error
}
