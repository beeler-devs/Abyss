import AVFoundation
import Foundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// WhisperKit-based on-device speech transcriber.
/// `@unchecked Sendable` remains because `AVAudioEngine` and `WhisperKit` are not Sendable, but every mutable field
/// shared with the audio tap or async transcription tasks is protected by `lock`, and late callbacks are ignored after stop/deinit.
final class WhisperKitSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
    private let lock = NSLock()

    private var _isListening = false
    private var partialContinuation: AsyncStream<String>.Continuation?
    private var _partials: AsyncStream<String>?
    private var accumulatedText = ""
    private var _audioLevelHandler: ((Float) -> Void)?
    private var audioEngine: AVAudioEngine?
    private var isTornDown = false

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var whisperKitInitTask: Task<WhisperKit?, Never>?
    private var audioBuffers: [Float] = []
    private var inputSampleRate: Double = 16_000
    private let targetSampleRate: Double = 16_000
    private var partialTranscriptionTask: Task<Void, Never>?
    private var partialTranscriptionInFlight = false
    private var lastPartialSampleCount = 0
    private let partialDebounceNanoseconds: UInt64 = 250_000_000
    #endif

    var isListening: Bool {
        lock.withLock { _isListening }
    }

    var partials: AsyncStream<String> {
        lock.withLock {
            if let existing = _partials { return existing }
            let (stream, continuation) = AsyncStream<String>.makeStream()
            _partials = stream
            partialContinuation = continuation
            return stream
        }
    }

    var onAudioLevel: ((Float) -> Void)? {
        get {
            lock.withLock { _audioLevelHandler as ((Float) -> Void)? }
        }
        set {
            lock.withLock {
                _audioLevelHandler = newValue
            }
        }
    }

    init() {}

    deinit {
        let continuation = lock.withLock { () -> AsyncStream<String>.Continuation? in
            _isListening = false
            isTornDown = true
            #if canImport(WhisperKit)
            partialTranscriptionTask?.cancel()
            partialTranscriptionTask = nil
            whisperKitInitTask?.cancel()
            whisperKitInitTask = nil
            #endif
            return partialContinuation
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        continuation?.finish()
    }

    func preload() async {
        #if canImport(WhisperKit)
        await ensureWhisperKitLoaded()
        #endif
    }

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)

        let (stream, continuation) = AsyncStream<String>.makeStream()
        lock.withLock {
            _partials = stream
            partialContinuation = continuation
            _isListening = true
            accumulatedText = ""
            isTornDown = false
            #if canImport(WhisperKit)
            audioBuffers = []
            partialTranscriptionTask?.cancel()
            partialTranscriptionTask = nil
            partialTranscriptionInFlight = false
            lastPartialSampleCount = 0
            #endif
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let format: AVAudioFormat
        if hwFormat.sampleRate > 0 {
            format = hwFormat
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ) ?? hwFormat
            AppLogger.audio.warning("Hardware format reported 0 Hz sample rate; falling back to 48 kHz")
        }

        #if canImport(WhisperKit)
        lock.withLock {
            inputSampleRate = format.sampleRate
        }
        AppLogger.audio.debug("Audio engine started at \(format.sampleRate, privacy: .public) Hz")
        continuation.yield("Listening…")
        #else
        continuation.yield("Listening… (no transcription)")
        #endif

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            let levelDB = self.computeAudioLevelDB(from: samples)

            let snapshot = self.lock.withLock {
                (
                    isListening: self._isListening && !self.isTornDown,
                    audioLevelHandler: self._audioLevelHandler,
                    continuation: self.partialContinuation
                )
            }
            guard snapshot.isListening else { return }

            snapshot.audioLevelHandler?(levelDB)

            #if canImport(WhisperKit)
            self.lock.withLock {
                guard self._isListening && !self.isTornDown else { return }
                self.audioBuffers.append(contentsOf: samples)
            }
            self.scheduleLivePartialTranscription()
            #else
            let rms = samples.reduce(0) { $0 + $1 * $1 } / Float(frameLength)
            if rms > 0.001 {
                snapshot.continuation?.yield("[audio level: \(String(format: "%.4f", rms))]")
            }
            #endif
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        #if canImport(WhisperKit)
        Task { [weak self] in
            await self?.ensureWhisperKitLoaded()
        }
        #endif
    }

    func stop() async throws -> String {
        AppLogger.audio.debug("Stopping transcription session")

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let continuation = lock.withLock { () -> AsyncStream<String>.Continuation? in
            _isListening = false
            return partialContinuation
        }

        #if canImport(WhisperKit)
        let hadTask = lock.withLock { partialTranscriptionTask != nil }
        lock.withLock {
            partialTranscriptionTask?.cancel()
            partialTranscriptionTask = nil
        }
        if hadTask {
            AppLogger.audio.debug("Cancelled pending partial transcription task before final pass")
        }

        var waitMs = 0
        while lock.withLock({ partialTranscriptionInFlight }) && waitMs < 6_000 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitMs += 100
        }
        if waitMs >= 6_000 {
            AppLogger.audio.warning("Timed out waiting for in-flight partial transcription; using accumulated text")
        }

        let snapshot = lock.withLock {
            (
                samples: audioBuffers,
                inputRate: inputSampleRate,
                whisperLoaded: whisperKit != nil,
                accumulatedText: accumulatedText
            )
        }

        if snapshot.samples.isEmpty {
            continuation?.finish()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return snapshot.accumulatedText.isEmpty ? "[No audio captured]" : snapshot.accumulatedText
        }

        var whisperLoaded = snapshot.whisperLoaded
        if !whisperLoaded, snapshot.samples.count > 1600 {
            await ensureWhisperKitLoaded()
            whisperLoaded = lock.withLock { whisperKit != nil }
        }

        if let wk = lock.withLock({ whisperKit }), snapshot.samples.count > 1600 {
            let forWhisper = resampleTo16k(snapshot.samples, sourceRate: snapshot.inputRate)
            if forWhisper.count > 1600 {
                AppLogger.audio.debug("Running final WhisperKit pass on \(forWhisper.count, privacy: .public) samples")
                let results: [TranscriptionResult]? = await withTaskGroup(of: [TranscriptionResult]?.self) { group in
                    group.addTask { try? await wk.transcribe(audioArray: forWhisper) }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }

                if let text = results?.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    lock.withLock {
                        accumulatedText = text
                    }
                } else if results == nil {
                    AppLogger.audio.warning("Final WhisperKit transcription timed out; falling back to accumulated partial")
                }
            }
        } else if !whisperLoaded {
            AppLogger.audio.notice("WhisperKit not ready during final transcription; using accumulated partial text")
        }
        #endif

        let finalText = lock.withLock { accumulatedText }
        continuation?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return finalText
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
            AppLogger.audio.notice("Initializing WhisperKit model")
            do {
                let kit = try await WhisperKit(model: "base.en")
                AppLogger.audio.notice("WhisperKit initialized successfully")
                return kit
            } catch {
                AppLogger.audio.error("WhisperKit initialization failed: \(error.localizedDescription, privacy: .public)")
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

    private func resampleTo16k(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard sourceRate != targetSampleRate, sourceRate > 0 else { return samples }
        let ratio = sourceRate / targetSampleRate
        let targetCount = Int(Double(samples.count) / ratio)
        guard targetCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: targetCount)
        for index in 0..<targetCount {
            let sourceIndex = Double(index) * ratio
            let base = Int(sourceIndex)
            if base + 1 < samples.count {
                let t = Float(sourceIndex - Double(base))
                output[index] = samples[base] * (1 - t) + samples[base + 1] * t
            } else {
                output[index] = samples[min(base, samples.count - 1)]
            }
        }
        return output
    }

    private func transcribePartial() async {
        let snapshot = lock.withLock {
            () -> (
                whisper: WhisperKit?,
                samples: [Float],
                inputRate: Double,
                sampleCount: Int,
                continuation: AsyncStream<String>.Continuation?
            )? in
            guard _isListening, !isTornDown, !partialTranscriptionInFlight else { return nil }
            let sampleCount = audioBuffers.count
            let minNewSamples = max(Int(inputSampleRate * 0.2), 1600)
            guard sampleCount - lastPartialSampleCount >= minNewSamples else { return nil }

            partialTranscriptionInFlight = true
            return (whisperKit, audioBuffers, inputSampleRate, sampleCount, partialContinuation)
        }

        guard let snapshot else { return }
        guard let whisper = snapshot.whisper else {
            lock.withLock {
                partialTranscriptionInFlight = false
                lastPartialSampleCount = snapshot.sampleCount
            }
            return
        }

        defer {
            lock.withLock {
                partialTranscriptionInFlight = false
                lastPartialSampleCount = snapshot.sampleCount
            }
        }

        let minSamplesAtInputRate = Int(snapshot.inputRate * 0.35)
        guard snapshot.samples.count > minSamplesAtInputRate else { return }

        let forWhisper = resampleTo16k(snapshot.samples, sourceRate: snapshot.inputRate)
        guard forWhisper.count > 3200 else { return }

        do {
            let results = try await whisper.transcribe(audioArray: forWhisper)
            if let text = results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
               text.count > 1,
               text != "Listening…" {
                let shouldYield = lock.withLock { () -> Bool in
                    guard _isListening, !isTornDown else { return false }
                    accumulatedText = text
                    return true
                }
                if shouldYield {
                    snapshot.continuation?.yield(text)
                }
            }
        } catch {
            AppLogger.audio.error("Partial transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleLivePartialTranscription() {
        let shouldSchedule = lock.withLock {
            guard _isListening, !isTornDown, partialTranscriptionTask == nil else { return false }
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
}

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T {
        lock()
        defer { unlock() }
        return action()
    }
}
