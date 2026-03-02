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
    private var _audioLevelHandler: ((Float) -> Void)?

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

    var onAudioLevel: ((Float) -> Void)? {
        get { lock.withLock { _audioLevelHandler } }
        set { lock.withLock { _audioLevelHandler = newValue } }
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

        // Use inputFormat (not outputFormat) to get the actual hardware capture format.
        // If the sample rate is invalid (e.g. 0 Hz before session activation), fall back to 48kHz mono.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let format: AVAudioFormat
        if hwFormat.sampleRate > 0 {
            format = hwFormat
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ) ?? hwFormat
            print("⚠️ Hardware format had 0 Hz sample rate — using 48kHz fallback")
        }

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
                let levelDB = self.computeAudioLevelDB(from: samples)
                let audioLevelHandler = self.lock.withLock { self._audioLevelHandler }
                audioLevelHandler?(levelDB)
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

        #if canImport(WhisperKit)
        // Warm the model in parallel so first-turn speech capture is never blocked on load.
        Task { [weak self] in
            guard let self else { return }
            await self.ensureWhisperKitLoaded()
        }
        #endif
    }

    private func computeAudioLevelDB(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160.0 }
        let sumSquares = samples.reduce(Float.zero) { $0 + ($1 * $1) }
        let rms = sqrt(sumSquares / Float(samples.count))
        guard rms > 0 else { return -160.0 }
        return max(-160.0, 20.0 * log10(rms))
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
        guard let wk = whisperKit else {
            print("🔍 [PARTIAL] transcribePartial() — no WhisperKit, skipping")
            return
        }
        let snapshot: (samples: [Float], sampleRate: Double, sampleCount: Int)? = lock.withLock {
            guard _isListening, !partialTranscriptionInFlight else {
                // Don't spam; this fires often and the guard is expected to fail sometimes
                return nil
            }
            let sampleCount = audioBuffers.count
            let minNewSamples = max(Int(inputSampleRate * 0.2), 1600)
            guard sampleCount - lastPartialSampleCount >= minNewSamples else { return nil }

            partialTranscriptionInFlight = true
            return (audioBuffers, inputSampleRate, sampleCount)
        }
        guard let snapshot else { return }
        print("🔍 [PARTIAL] transcribePartial() ENTER — bufferCount=\(snapshot.sampleCount) at \(snapshot.sampleRate)Hz")
        defer {
            lock.withLock {
                partialTranscriptionInFlight = false
                lastPartialSampleCount = snapshot.sampleCount
            }
            print("🔍 [PARTIAL] transcribePartial() DONE — inFlight cleared")
        }

        let samples = snapshot.samples
        // Allow early partials so transcript feels live while user is speaking.
        let minSamplesAtInputRate = Int(snapshot.sampleRate * 0.35)
        guard samples.count > minSamplesAtInputRate else {
            print("🔍 [PARTIAL] skipping — too few samples (\(samples.count) < \(minSamplesAtInputRate))")
            return
        }

        let forWhisper = resampleTo16k(samples, sourceRate: snapshot.sampleRate)
        guard forWhisper.count > 3200 else {
            print("🔍 [PARTIAL] skipping — resampled too small (\(forWhisper.count))")
            return
        }

        print("🔍 [PARTIAL] calling wk.transcribe — \(forWhisper.count) samples @16kHz")
        do {
            let results = try await wk.transcribe(audioArray: forWhisper)
            let rawText = results.first?.text ?? "nil"
            print("🔍 [PARTIAL] wk.transcribe returned — text='\(rawText)'")
            if let text = results.first?.text, !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty or meaningless outputs
                if trimmed.count > 1 && trimmed != "Listening…" {
                    lock.withLock { accumulatedText = trimmed }
                    partialContinuation?.yield(trimmed)
                }
            }
        } catch {
            print("🔍 [PARTIAL] wk.transcribe THREW: \(error)")
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
        let engineRunning = audioEngine != nil
        let listeningNow = lock.withLock { _isListening }
        print("🛑 [STOP-1] stop() ENTER — isListening=\(listeningNow), audioEngine=\(engineRunning)")

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        print("🛑 [STOP-2] audio engine torn down (removeTap + stop)")

        lock.withLock {
            _isListening = false
        }

        #if canImport(WhisperKit)
        let hadTask = lock.withLock { partialTranscriptionTask != nil }
        lock.withLock {
            partialTranscriptionTask?.cancel()
            partialTranscriptionTask = nil
        }
        print("🛑 [STOP-2b] partial task cancelled (had task=\(hadTask))")

        // Wait for any in-flight partial transcription to finish before running the final pass.
        // WhisperKit is not safe to call concurrently — a concurrent call causes a hang/deadlock.
        let inFlightAtStart = lock.withLock { partialTranscriptionInFlight }
        print("🛑 [STOP-3] partial wait — partialTranscriptionInFlight=\(inFlightAtStart) at entry")
        var waitMs = 0
        while lock.withLock({ partialTranscriptionInFlight }) && waitMs < 6000 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            waitMs += 100
            if waitMs % 1000 == 0 {
                print("🛑 [STOP-3-POLL] still waiting for partial… \(waitMs)ms elapsed")
            }
        }
        let timedOutWaiting = waitMs >= 6000
        print("🛑 [STOP-4] partial wait done — waited \(waitMs)ms, timedOut=\(timedOutWaiting)")
        if timedOutWaiting {
            print("⚠️ [STOP-4-WARN] timed out waiting for in-flight partial — proceeding with accumulated text")
        }

        // Final transcription pass on all accumulated audio (resampled to 16kHz)
        let samples: [Float] = lock.withLock { audioBuffers }
        var whisperLoaded = lock.withLock { whisperKit != nil }
        print("🛑 [STOP-4b] snapshot — samples=\(samples.count) at \(inputSampleRate)Hz, whisperKitLoaded=\(whisperLoaded)")

        // If we have no samples, the audio engine never captured anything
        if samples.isEmpty {
            print("⚠️ [STOP-4c] NO audio captured — returning early")
            let finalText = lock.withLock { accumulatedText }
            partialContinuation?.finish()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🛑 [STOP-7] stop() returning (no audio) — '\(finalText)'")
            return finalText.isEmpty ? "[No audio captured]" : finalText
        }

        if !whisperLoaded, samples.count > 1600 {
            print("🛑 [STOP-4d] WhisperKit not ready yet — waiting for model load before final pass")
            await ensureWhisperKitLoaded()
            whisperLoaded = lock.withLock { whisperKit != nil }
            print("🛑 [STOP-4e] WhisperKit load wait done — whisperKitLoaded=\(whisperLoaded)")
        }

        if let wk = whisperKit, samples.count > 1600 {
            let forWhisper = resampleTo16k(samples, sourceRate: inputSampleRate)
            print("🛑 [STOP-5] starting final WhisperKit transcription — \(forWhisper.count) samples @16kHz (8s timeout)")
            if forWhisper.count > 1600 {
                // Race WhisperKit against an 8-second timeout so we never hang in .transcribing.
                let results: [TranscriptionResult]? = await withTaskGroup(
                    of: [TranscriptionResult]?.self
                ) { group in
                    group.addTask { try? await wk.transcribe(audioArray: forWhisper) }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }

                if let results {
                    if let text = results.first?.text, !text.isEmpty {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("🛑 [STOP-6] final transcription DONE — '\(trimmed)'")
                        lock.withLock { accumulatedText = trimmed }
                    } else {
                        print("🛑 [STOP-6] final transcription returned EMPTY result")
                    }
                } else {
                    print("🛑 [STOP-6] final transcription TIMED OUT (8s) — using accumulated partial")
                }
            } else {
                print("🛑 [STOP-5-SKIP] resampled count \(forWhisper.count) too small — skipping inference")
            }
        } else if whisperKit == nil {
            print("🛑 [STOP-5-SKIP] WhisperKit not loaded — skipping final transcription")
        } else {
            print("🛑 [STOP-5-SKIP] samples.count \(samples.count) <= 1600 — skipping final transcription")
        }
        #endif

        let finalText = lock.withLock { accumulatedText }
        partialContinuation?.finish()

        // Reset audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        print("🛑 [STOP-7] stop() returning '\(finalText)'")
        return finalText
    }
}
