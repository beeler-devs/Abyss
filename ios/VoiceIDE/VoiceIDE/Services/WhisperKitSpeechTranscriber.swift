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
    private var whisperKitInitTask: Task<WhisperKit?, Never>?
    private var audioBuffers: [Float] = []
    private var inputSampleRate: Double = 16000
    private let targetSampleRate: Double = 16000
    private var partialTranscriptionTask: Task<Void, Never>?
    private var partialTranscriptionInFlight = false
    private var lastPartialSampleCount = 0
    private let partialDebounceNanoseconds: UInt64 = 250_000_000
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

    func preload() async {
        #if canImport(WhisperKit)
        await ensureWhisperKitLoaded()
        #endif
    }

    func start() async throws {
        // Request microphone permission
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)

        #if canImport(WhisperKit)
        // Ensure the model is ready (or attempted) before recording starts.
        await ensureWhisperKitLoaded()
        audioBuffers = []
        partialTranscriptionTask?.cancel()
        partialTranscriptionTask = nil
        partialTranscriptionInFlight = false
        lastPartialSampleCount = 0
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

        #if canImport(WhisperKit)
        inputSampleRate = format.sampleRate
        print("🎤 Audio engine started. Sample rate: \(inputSampleRate) Hz")
        // Emit immediate feedback so user sees the mic is working
        partialContinuation?.yield("Listening…")
        #else
        // Without WhisperKit, still show feedback
        partialContinuation?.yield("Listening… (no transcription)")
        #endif

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
                self.scheduleLivePartialTranscription()
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
    private func ensureWhisperKitLoaded() async {
        if lock.withLock({ whisperKit != nil }) {
            return
        }

        if let existingTask = lock.withLock({ whisperKitInitTask }) {
            _ = await existingTask.value
            return
        }

        let loadTask = Task<WhisperKit?, Never> {
            print("📱 Initializing WhisperKit with base.en model...")
            do {
                let kit = try await WhisperKit(model: "base.en")
                print("✅ WhisperKit loaded successfully")
                return kit
            } catch {
                print("❌ WhisperKit initialization failed: \(error)")
                print("⚠️ Continuing without transcription - audio will be captured but not transcribed")
                return nil
            }
        }

        lock.withLock {
            whisperKitInitTask = loadTask
        }

        let loadedKit = await loadTask.value
        lock.withLock {
            if let loadedKit {
                whisperKit = loadedKit
            }
            whisperKitInitTask = nil
        }
    }

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
        let snapshot: (samples: [Float], sampleRate: Double, sampleCount: Int)? = lock.withLock {
            guard _isListening, !partialTranscriptionInFlight else { return nil }
            let sampleCount = audioBuffers.count
            let minNewSamples = max(Int(inputSampleRate * 0.2), 1600)
            guard sampleCount - lastPartialSampleCount >= minNewSamples else { return nil }

            partialTranscriptionInFlight = true
            return (audioBuffers, inputSampleRate, sampleCount)
        }
        guard let snapshot else { return }
        defer {
            lock.withLock {
                partialTranscriptionInFlight = false
                lastPartialSampleCount = snapshot.sampleCount
            }
        }

        let samples = snapshot.samples
        // Allow early partials so transcript feels live while user is speaking.
        let minSamplesAtInputRate = Int(snapshot.sampleRate * 0.35)
        guard samples.count > minSamplesAtInputRate else { return }

        let forWhisper = resampleTo16k(samples, sourceRate: snapshot.sampleRate)
        guard forWhisper.count > 3200 else { return }

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

    private func scheduleLivePartialTranscription() {
        let shouldSchedule = lock.withLock {
            guard partialTranscriptionTask == nil else { return false }
            return true
        }
        guard shouldSchedule else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.partialDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.transcribePartial()
            self.lock.withLock {
                self.partialTranscriptionTask = nil
            }
        }

        lock.withLock {
            partialTranscriptionTask = task
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
        lock.withLock {
            partialTranscriptionTask?.cancel()
            partialTranscriptionTask = nil
        }
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
