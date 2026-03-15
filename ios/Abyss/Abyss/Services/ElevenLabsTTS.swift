import AVFoundation
import Combine
import Foundation

/// ElevenLabs streaming TTS implementation.
/// Audio starts once a small PCM buffer is available, and additional chunks are scheduled as they arrive.
final class ElevenLabsTTS: NSObject, TextToSpeech, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _isSpeaking = false
    private let speakingSubject = CurrentValueSubject<Bool, Never>(false)
    private let fallbackSynth = AVSpeechSynthesizer()
    private var _systemVoiceContinuation: CheckedContinuation<Void, Never>?
    private var elevenLabsDisabledForSession = false
    private var didLogElevenLabsDisableReason = false

    var voiceId: String
    var modelId: String

    private var apiKey: String? {
        Config.elevenLabsAPIKey
    }

    var isSpeaking: Bool {
        lock.withLock { _isSpeaking }
    }

    var isSpeakingPublisher: AnyPublisher<Bool, Never> {
        speakingSubject.eraseToAnyPublisher()
    }

    init(voiceId: String = "21m00Tcm4TlvDq8ikWAM", modelId: String = "eleven_turbo_v2_5") {
        self.voiceId = voiceId
        self.modelId = modelId
        super.init()
        fallbackSynth.delegate = self
    }

    func speak(_ text: String) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        await stop()
        lock.withLock { _isSpeaking = true }
        speakingSubject.send(true)

        defer {
            lock.withLock { _isSpeaking = false }
            speakingSubject.send(false)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        do {
            let shouldTryElevenLabs = lock.withLock { !elevenLabsDisabledForSession }
            if let apiKey, !apiKey.isEmpty, shouldTryElevenLabs {
                try await speakWithElevenLabs(normalized, apiKey: apiKey)
                return
            }
            try await speakWithSystemVoice(normalized)
        } catch {
            handleElevenLabsFailure(error)
            try await speakWithSystemVoice(normalized)
        }
    }

    func stop() async {
        lock.withLock { _isSpeaking = false }
        speakingSubject.send(false)

        await MainActor.run {
            if StreamingPCMPlayer.shared.hasActivePlaybackSession {
                StreamingPCMPlayer.shared.stop()
            }
            if fallbackSynth.isSpeaking || fallbackSynth.isPaused {
                fallbackSynth.stopSpeaking(at: .immediate)
            }
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleElevenLabsFailure(_ error: Error) {
        if case TTSError.httpError(let code) = error, code == 401 || code == 403 {
            let shouldLog = lock.withLock { () -> Bool in
                elevenLabsDisabledForSession = true
                if didLogElevenLabsDisableReason {
                    return false
                }
                didLogElevenLabsDisableReason = true
                return true
            }
            if shouldLog {
                AppLogger.audio.warning(
                    "ElevenLabs authorization failed (HTTP \(code, privacy: .public)); using system voice for the rest of this app session"
                )
            }
            return
        }

        AppLogger.audio.error("ElevenLabs playback failed; falling back to system voice: \(error.localizedDescription, privacy: .public)")
    }

    private func speakWithElevenLabs(_ text: String, apiKey: String) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true)

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")
        components?.queryItems = [URLQueryItem(name: "output_format", value: "pcm_44100")]
        guard let url = components?.url else {
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw TTSError.httpError(httpResponse.statusCode)
        }

        try await MainActor.run {
            try StreamingPCMPlayer.shared.prepareForPlayback(sampleRate: 44_100)
        }

        var chunkBuffer = Data()
        var sawAudio = false
        do {
            for try await byte in bytes {
                guard isSpeaking else {
                    throw CancellationError()
                }
                chunkBuffer.append(byte)
                if chunkBuffer.count >= StreamingPCMPlayer.networkChunkBytes {
                    sawAudio = true
                    let chunk = chunkBuffer
                    chunkBuffer.removeAll(keepingCapacity: true)
                    try await MainActor.run {
                        try StreamingPCMPlayer.shared.append(chunk)
                    }
                }
            }
        } catch {
            await MainActor.run {
                StreamingPCMPlayer.shared.fail(error)
            }
            throw error
        }

        if !chunkBuffer.isEmpty {
            sawAudio = true
            let trailingChunk = chunkBuffer
            try await MainActor.run {
                try StreamingPCMPlayer.shared.append(trailingChunk)
            }
        }

        guard sawAudio else {
            await MainActor.run {
                StreamingPCMPlayer.shared.stop()
            }
            throw TTSError.playbackFailed
        }

        do {
            await MainActor.run {
                StreamingPCMPlayer.shared.finishReceivingAudio()
            }
            try await StreamingPCMPlayer.shared.waitForPlaybackToFinish()
        } catch {
            await MainActor.run {
                StreamingPCMPlayer.shared.stop()
            }
            throw error
        }
    }

    private func speakWithSystemVoice(_ text: String) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try session.setActive(true)

        // Use the delegate to suspend until the utterance finishes or is cancelled.
        // We arm the continuation BEFORE calling speak() (inside the same main-thread
        // block) so there is no window where didFinish can fire before we're waiting.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else { continuation.resume(); return }
                // Stop any previous utterance first; its didCancel fires here (on main),
                // before we arm _systemVoiceContinuation, so it is harmlessly a no-op.
                self.fallbackSynth.stopSpeaking(at: .immediate)
                // Now arm the continuation and start the new utterance.
                self.lock.withLock { self._systemVoiceContinuation = continuation }
                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                self.fallbackSynth.speak(utterance)
            }
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumeSystemVoiceContinuation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumeSystemVoiceContinuation()
    }

    private func resumeSystemVoiceContinuation() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = _systemVoiceContinuation
            _systemVoiceContinuation = nil
            return c
        }
        continuation?.resume()
    }
}

@MainActor
final class StreamingPCMPlayer {
    static let shared = StreamingPCMPlayer()
    nonisolated static let networkChunkBytes = 8_192

    private let startupThresholdBytes = 16_384
    private let scheduledChunkBytes = 8_192

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var pendingAudio = Data()
    private var scheduledBufferCount = 0
    private var playbackStarted = false
    private var finishedReceivingAudio = false
    private var playbackError: Error?
    private var completionContinuation: CheckedContinuation<Void, Error>?

    private init() {}

    var hasActivePlaybackSession: Bool {
        engine != nil || playerNode != nil || completionContinuation != nil || !pendingAudio.isEmpty || scheduledBufferCount > 0
    }

    func prepareForPlayback(sampleRate: Double) throws {
        stop()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TTSError.playbackFailed
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()

        self.engine = engine
        self.playerNode = playerNode
        self.format = format
        pendingAudio.removeAll(keepingCapacity: true)
        scheduledBufferCount = 0
        playbackStarted = false
        finishedReceivingAudio = false
        playbackError = nil
    }

    func append(_ data: Data) throws {
        guard playbackError == nil else {
            throw playbackError ?? TTSError.playbackFailed
        }
        guard !data.isEmpty else { return }
        pendingAudio.append(data)
        scheduleAvailableBuffers(force: false)
    }

    func finishReceivingAudio() {
        finishedReceivingAudio = true
        scheduleAvailableBuffers(force: true)
        completeIfNeeded()
    }

    func fail(_ error: Error) {
        playbackError = error
        stop()
    }

    func waitForPlaybackToFinish() async throws {
        if let playbackError {
            throw playbackError
        }
        if finishedReceivingAudio && scheduledBufferCount == 0 && pendingAudio.isEmpty {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            completionContinuation = continuation
            completeIfNeeded()
        }
    }

    func stop() {
        let continuation = completionContinuation
        let playbackError = playbackError
        completionContinuation = nil

        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        format = nil
        pendingAudio.removeAll(keepingCapacity: false)
        scheduledBufferCount = 0
        playbackStarted = false
        finishedReceivingAudio = false

        if let playbackError {
            continuation?.resume(throwing: playbackError)
        } else {
            continuation?.resume()
        }
    }

    private func scheduleAvailableBuffers(force: Bool) {
        guard let format, let playerNode else { return }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }

        while pendingAudio.count >= scheduledChunkBytes || (force && pendingAudio.count >= bytesPerFrame) {
            let targetBytes = min(pendingAudio.count, scheduledChunkBytes)
            let bufferBytes = targetBytes - (targetBytes % bytesPerFrame)
            guard bufferBytes >= bytesPerFrame else { break }

            let chunk = pendingAudio.prefix(bufferBytes)
            pendingAudio.removeFirst(bufferBytes)

            let frameCount = UInt32(bufferBytes / bytesPerFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let channelData = buffer.int16ChannelData?[0] else {
                playbackError = TTSError.playbackFailed
                completeIfNeeded()
                return
            }

            buffer.frameLength = frameCount
            chunk.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    memcpy(channelData, baseAddress, bufferBytes)
                }
            }

            scheduledBufferCount += 1
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.handleBufferPlaybackFinished()
                }
            }
        }

        if !playbackStarted && shouldStartPlayback {
            playerNode.play()
            playbackStarted = true
        }
    }

    private var shouldStartPlayback: Bool {
        let bufferedBytes = pendingAudio.count + scheduledBufferCount * scheduledChunkBytes
        return scheduledBufferCount > 0 && (bufferedBytes >= startupThresholdBytes || finishedReceivingAudio)
    }

    private func handleBufferPlaybackFinished() {
        scheduledBufferCount = max(0, scheduledBufferCount - 1)
        scheduleAvailableBuffers(force: finishedReceivingAudio)
        completeIfNeeded()
    }

    private func completeIfNeeded() {
        if let playbackError {
            let continuation = completionContinuation
            completionContinuation = nil
            continuation?.resume(throwing: playbackError)
            return
        }

        guard finishedReceivingAudio, scheduledBufferCount == 0, pendingAudio.isEmpty else { return }
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume()
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

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T {
        lock()
        defer { unlock() }
        return action()
    }
}
