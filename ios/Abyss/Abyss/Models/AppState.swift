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

/// Controls how the user triggers recording.
enum RecordingMode: String, CaseIterable {
    case vadAuto    = "vadAuto"      // VAD auto-stops on silence (default)
    case pushToTalk = "pushToTalk"   // Hold button to record, release to stop
}
