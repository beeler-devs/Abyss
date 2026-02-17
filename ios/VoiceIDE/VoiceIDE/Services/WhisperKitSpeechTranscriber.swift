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
    private var inputSampleRate: Double = 16000
    private let targetSampleRate: Double = 16000
    private var lastPartialTime: Date = .distantPast
    private let partialInterval: TimeInterval = 3.0 // Run partials every 3 seconds
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
        #if canImport(WhisperKit)
        // Initialize WhisperKit if needed (do this first, before audio setup)
        if whisperKit == nil {
            print("📱 Initializing WhisperKit with base.en model...")
            do {
                whisperKit = try await WhisperKit(model: "base.en")
                print("✅ WhisperKit loaded successfully")
            } catch {
                print("❌ WhisperKit initialization failed: \(error)")
                print("⚠️ Continuing without transcription - audio will be captured but not transcribed")
                // Continue anyway - we can still capture audio
            }
        }
        audioBuffers = []
        #endif

        // Configure audio session for recording
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)

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
        
        // Get the input format - use the hardware's native format
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let sampleRate = inputFormat.sampleRate
        
        // If sample rate is still 0 or invalid, use a default format
        let recordingFormat: AVAudioFormat
        if sampleRate > 0 {
            recordingFormat = inputFormat
        } else {
            // Fallback to a standard format if the hardware format is invalid
            guard let fallbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ) else {
                throw NSError(domain: "AudioSetup", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not create audio format"])
            }
            recordingFormat = fallbackFormat
            print("⚠️ Using fallback audio format: 48kHz")
        }

        #if canImport(WhisperKit)
        inputSampleRate = recordingFormat.sampleRate
        print("🎤 Audio engine started. Sample rate: \(inputSampleRate) Hz")
        // Emit immediate feedback so user sees the mic is working
        partialContinuation?.yield("Listening…")
        #else
        // Without WhisperKit, still show feedback
        partialContinuation?.yield("Listening… (no transcription)")
        #endif

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)

            if let channelData {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                #if canImport(WhisperKit)
                self.lock.withLock {
                    self.audioBuffers.append(contentsOf: samples)
                }
                // Throttled: only run transcription every N seconds to avoid overwhelming WhisperKit
                let now = Date()
                let shouldTranscribe = self.lock.withLock {
                    if now.timeIntervalSince(self.lastPartialTime) >= self.partialInterval {
                        self.lastPartialTime = now
                        return true
                    }
                    return false
                }
                if shouldTranscribe {
                    Task { @Sendable in
                        await self.transcribePartial()
                    }
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
    /// Resample to 16kHz for WhisperKit (iPhone often captures at 48kHz).
    private func resampleTo16k(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard sourceRate != targetSampleRate, sourceRate > 0 else { return samples }
        let ratio = sourceRate / targetSampleRate
        let targetCount = Int(Double(samples.count) / ratio)
        guard targetCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            let srcIndex = Double(i) * ratio
            let idx = Int(srcIndex)
            if idx + 1 < samples.count {
                let t = Float(srcIndex - Double(idx))
                out[i] = samples[idx] * (1 - t) + samples[idx + 1] * t
            } else {
                out[i] = samples[min(idx, samples.count - 1)]
            }
        }
        return out
    }

    private func transcribePartial() async {
        guard let wk = whisperKit else { return }
        let samples: [Float] = lock.withLock { audioBuffers }
        // Need at least ~2s of audio at input rate for reliable transcription
        let minSamplesAtInputRate = Int(inputSampleRate * 2.0)
        guard samples.count > minSamplesAtInputRate else { return }

        let forWhisper = resampleTo16k(samples, sourceRate: inputSampleRate)
        guard forWhisper.count > 16000 else { return }

        do {
            let results = try await wk.transcribe(audioArray: forWhisper)
            if let text = results.first?.text, !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty or meaningless outputs
                if trimmed.count > 1 && trimmed != "Listening…" {
                    lock.withLock { accumulatedText = trimmed }
                    partialContinuation?.yield(trimmed)
                }
            }
        } catch {
            // Partial errors are non-fatal, skip logging to reduce console spam
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
        // Final transcription pass on all accumulated audio (resampled to 16kHz)
        let samples: [Float] = lock.withLock { audioBuffers }
        print("🎙️ Final transcription: \(samples.count) samples at \(inputSampleRate)Hz")
        
        // If we have no samples, the audio engine never captured anything
        if samples.isEmpty {
            print("⚠️ No audio captured - microphone may not be working or app didn't have permission")
            return "[No audio captured]"
        }
        
        if let wk = whisperKit, samples.count > 1600 {
            let forWhisper = resampleTo16k(samples, sourceRate: inputSampleRate)
            print("📊 Resampled to: \(forWhisper.count) samples at 16kHz")
            if forWhisper.count > 1600 {
                do {
                    let results = try await wk.transcribe(audioArray: forWhisper)
                    if let text = results.first?.text, !text.isEmpty {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("✅ Transcribed: \"\(trimmed)\"")
                        lock.withLock { accumulatedText = trimmed }
                    } else {
                        print("⚠️ WhisperKit returned empty result")
                    }
                } catch {
                    print("❌ Final transcription failed: \(error.localizedDescription)")
                    // Use whatever partial we had, or return indication we heard audio
                    if lock.withLock({ accumulatedText }).isEmpty {
                        return "[Audio recorded but transcription failed]"
                    }
                }
            }
        } else if whisperKit == nil {
            // WhisperKit failed to load, but we still captured audio
            print("⚠️ WhisperKit not available - returning sample count")
            return "[Audio recorded: \(samples.count) samples, but WhisperKit unavailable for transcription]"
        }
        #endif

        let finalText = lock.withLock { accumulatedText }
        partialContinuation?.finish()

        // Reset audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return finalText
    }
}
