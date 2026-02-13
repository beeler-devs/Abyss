import Foundation
import AVFoundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// WhisperKit-based on-device speech transcriber.
/// Streams partial transcripts while recording, returns final on stop.
final class WhisperKitSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()

    private var _isListening = false
    var isListening: Bool {
        lock.withLock { _isListening }
    }

    private var partialContinuation: AsyncStream<String>.Continuation?
    private var _partials: AsyncStream<String>?
    private var audioEngine: AVAudioEngine?
    private var accumulatedText: String = ""

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var audioBuffers: [Float] = []
    #endif

    var partials: AsyncStream<String> {
        lock.withLock {
            if let existing = _partials { return existing }
            let (stream, continuation) = AsyncStream<String>.makeStream()
            self._partials = stream
            self.partialContinuation = continuation
            return stream
        }
    }

    init() {}

    func start() async throws {
        // Request microphone permission
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)

        #if canImport(WhisperKit)
        // Initialize WhisperKit if needed
        if whisperKit == nil {
            whisperKit = try await WhisperKit(model: "base.en")
        }
        audioBuffers = []
        #endif

        // Recreate the partial stream
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lock.withLock {
            self._partials = stream
            self.partialContinuation = continuation
            self._isListening = true
            self.accumulatedText = ""
        }

        // Start the audio engine for capture
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)

            if let channelData {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                #if canImport(WhisperKit)
                self.lock.withLock {
                    self.audioBuffers.append(contentsOf: samples)
                }
                // Periodically run transcription for partials
                Task { @Sendable in
                    await self.transcribePartial()
                }
                #else
                // Without WhisperKit, emit buffer level as placeholder
                let rms = samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength)
                if rms > 0.001 {
                    self.partialContinuation?.yield("[audio level: \(String(format: "%.4f", rms))]")
                }
                #endif
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    #if canImport(WhisperKit)
    private func transcribePartial() async {
        guard let wk = whisperKit else { return }
        let samples: [Float] = lock.withLock { audioBuffers }
        guard samples.count > 16000 else { return } // Need at least ~1s of audio

        do {
            let results = try await wk.transcribe(audioArray: samples)
            if let text = results.first?.text, !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                lock.withLock { accumulatedText = trimmed }
                partialContinuation?.yield(trimmed)
            }
        } catch {
            // Partial transcription errors are non-fatal
        }
    }
    #endif

    func stop() async throws -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        lock.withLock {
            _isListening = false
        }

        #if canImport(WhisperKit)
        // Final transcription pass on all accumulated audio
        let samples: [Float] = lock.withLock { audioBuffers }
        if let wk = whisperKit, samples.count > 1600 {
            do {
                let results = try await wk.transcribe(audioArray: samples)
                if let text = results.first?.text, !text.isEmpty {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    lock.withLock { accumulatedText = trimmed }
                }
            } catch {
                // Use whatever partial we had
            }
        }
        #endif

        let finalText = lock.withLock { accumulatedText }
        partialContinuation?.finish()

        // Reset audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return finalText
    }
}
