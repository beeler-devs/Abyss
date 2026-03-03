import Foundation
import AVFoundation

/// ElevenLabs streaming TTS implementation.
/// Streams audio chunks as they arrive and begins playback immediately.
final class ElevenLabsTTS: NSObject, TextToSpeech, @unchecked Sendable {
    private let lock = NSLock()
    private var _isSpeaking = false
    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private let fallbackSynth = AVSpeechSynthesizer()

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
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        lock.withLock { _isSpeaking = true }
        defer {
            lock.withLock {
                _isSpeaking = false
                audioPlayer = nil
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        do {
            if let apiKey, !apiKey.isEmpty {
                try await speakWithElevenLabs(normalized, apiKey: apiKey)
                return
            }

            try await speakWithSystemVoice(normalized)
        } catch {
            print("🔈 [TTS] ElevenLabs failed; falling back to system voice: \(error.localizedDescription)")
            try await speakWithSystemVoice(normalized)
        }
    }

    private func speakWithElevenLabs(_ text: String, apiKey: String) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true)

        // Build request to ElevenLabs streaming endpoint
        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream"
        guard let url = URL(string: urlString) else {
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
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw TTSError.httpError(httpResponse.statusCode)
        }

        // Collect ALL streaming audio data before playing
        var audioData = Data()
        for try await byte in bytes {
            guard isSpeaking else { break } // Stopped externally
            audioData.append(byte)
        }

        // Now play the complete audio
        if !audioData.isEmpty && isSpeaking {
            try startPlayback(data: audioData)
            
            // Wait for playback to finish
            if let player = lock.withLock({ audioPlayer }) {
                while player.isPlaying && isSpeaking {
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
                }
            }
            return
        }

        throw TTSError.playbackFailed
    }

    private func speakWithSystemVoice(_ text: String) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true)

        await MainActor.run {
            self.fallbackSynth.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.fallbackSynth.speak(utterance)
        }

        while isSpeaking {
            let stillSpeaking = await MainActor.run {
                self.fallbackSynth.isSpeaking
            }
            if !stillSpeaking {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
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
        await MainActor.run {
            self.fallbackSynth.stopSpeaking(at: .immediate)
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
