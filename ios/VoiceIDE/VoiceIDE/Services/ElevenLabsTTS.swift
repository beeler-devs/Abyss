import Foundation
import AVFoundation

/// ElevenLabs streaming TTS implementation.
/// Streams audio chunks as they arrive and begins playback immediately.
final class ElevenLabsTTS: NSObject, TextToSpeech, @unchecked Sendable {
    private let lock = NSLock()
    private var _isSpeaking = false
    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?

    var voiceId: String
    var modelId: String

    private var apiKey: String? {
        Config.elevenLabsAPIKey
    }

    var isSpeaking: Bool {
        lock.withLock { _isSpeaking }
    }

    init(voiceId: String = "21m00Tcm4TlvDq8ikWAM", modelId: String = "eleven_turbo_v2_5") {
        self.voiceId = voiceId
        self.modelId = modelId
        super.init()
    }

    func speak(_ text: String) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw TTSError.missingAPIKey
        }

        lock.withLock { _isSpeaking = true }

        // Set up audio session for playback
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true)

        // Build request to ElevenLabs streaming endpoint
        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream"
        guard let url = URL(string: urlString) else {
            lock.withLock { _isSpeaking = false }
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Stream the response
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            lock.withLock { _isSpeaking = false }
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            lock.withLock { _isSpeaking = false }
            throw TTSError.httpError(httpResponse.statusCode)
        }

        // Collect streaming audio data
        var audioData = Data()
        for try await byte in bytes {
            guard isSpeaking else { break } // Stopped externally
            audioData.append(byte)

            // Start playback once we have a reasonable chunk (~8KB)
            if audioData.count > 8192 && audioPlayer == nil {
                try startPlayback(data: audioData)
            }
        }

        // Play any remaining data if we haven't started yet (short responses)
        if audioPlayer == nil && !audioData.isEmpty && isSpeaking {
            try startPlayback(data: audioData)
        }

        // Wait for playback to finish
        if let player = lock.withLock({ audioPlayer }) {
            while player.isPlaying && isSpeaking {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
            }
        }

        lock.withLock {
            _isSpeaking = false
            audioPlayer = nil
        }

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startPlayback(data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        player.play()
        lock.withLock {
            self.audioPlayer = player
        }
    }

    func stop() async {
        lock.withLock {
            _isSpeaking = false
            audioPlayer?.stop()
            audioPlayer = nil
        }
        playbackTask?.cancel()
        playbackTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum TTSError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ElevenLabs API key is not configured. Add it to Secrets.xcconfig or Secrets.plist."
        case .invalidURL:
            return "Invalid ElevenLabs URL."
        case .invalidResponse:
            return "Invalid response from ElevenLabs."
        case .httpError(let code):
            return "ElevenLabs HTTP error: \(code)"
        case .playbackFailed:
            return "Audio playback failed."
        }
    }
}
