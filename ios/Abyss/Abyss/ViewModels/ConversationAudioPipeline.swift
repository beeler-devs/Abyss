import Combine
import AVFoundation
import Foundation

/// Owns the microphone, transcription, playback interruption, and conversation audio state machine.
/// `ConversationViewModel` mirrors its published UI state, and `EventCoordinator` asks it to apply remote state changes.
@MainActor
final class ConversationAudioPipeline: ObservableObject {
    @Published private(set) var appState: AppState = .idle
    @Published private(set) var partialTranscript: String = ""

    private let transcriber: SpeechTranscriber
    private let tts: TextToSpeech
    private let transcriptFormatter: FastTranscriptFormatter
    private let eventBus: EventBus
    private let toolRouter: ToolRouter
    private let appStateStore: AppStateStore
    private let sessionId: String
    private let sendConductorEvent: @MainActor @Sendable (Event, Bool) async -> Void
    private let handleError: @MainActor @Sendable (String) async -> Void

    private let voiceActivityDetector = VoiceActivityDetector(
        config: VoiceActivityDetector.Config(
            silenceThreshold: -37.0,
            speechThreshold: -35.0,
            silenceDuration: 0.9,
            minSpeechDuration: 0.25
        )
    )

    private var recordingMode: RecordingMode = .vadAuto
    private var isChatActive = false
    private var isMuted = false
    private var isStoppingRecording = false
    private var isStartingRecording = false
    private var pendingPTTRelease = false
    private let remoteVoiceCapture: RemoteVoiceCapturing
    private var remotePlaybackPrepared = false

    init(
        transcriber: SpeechTranscriber,
        tts: TextToSpeech,
        transcriptFormatter: FastTranscriptFormatter,
        eventBus: EventBus,
        toolRouter: ToolRouter,
        appStateStore: AppStateStore,
        sessionId: String,
        remoteVoiceCapture: RemoteVoiceCapturing? = nil,
        sendConductorEvent: @escaping @MainActor @Sendable (Event, Bool) async -> Void,
        handleError: @escaping @MainActor @Sendable (String) async -> Void
    ) {
        self.transcriber = transcriber
        self.tts = tts
        self.transcriptFormatter = transcriptFormatter
        self.eventBus = eventBus
        self.toolRouter = toolRouter
        self.appStateStore = appStateStore
        self.sessionId = sessionId
        self.remoteVoiceCapture = remoteVoiceCapture ?? RemoteAudioCapture()
        self.sendConductorEvent = sendConductorEvent
        self.handleError = handleError

        configureVoicePipeline()
    }

    deinit {
        voiceActivityDetector.stopMonitoring()
        transcriber.tearDown()
        if let whisperTranscriber = transcriber as? WhisperKitSpeechTranscriber {
            whisperTranscriber.onAudioLevel = nil
        }
    }

    func preloadTranscriber() {
        guard recordingMode == .pushToTalk else { return }
        let transcriber = self.transcriber
        Task {
            await transcriber.preload()
            try? await transcriber.warmUp()
            AppLogger.audio.debug("[PTT] Transcriber preloaded and engine warmed up")
        }
    }

    func tearDownTranscriber() {
        transcriber.tearDown()
        AppLogger.audio.debug("[PTT] Transcriber torn down for inactive chat")
    }

    func updateRecordingMode(_ mode: RecordingMode) {
        guard recordingMode != mode else { return }
        let oldMode = recordingMode
        recordingMode = mode
        voiceActivityDetector.stopMonitoring()
        if mode == .pushToTalk {
            preloadTranscriber()
        } else if oldMode == .pushToTalk {
            // Switching away from PTT — tear down the warm engine
            transcriber.tearDown()
        }
        Task { await refreshLiveConversationState() }
    }

    func setChatActive(_ isActive: Bool) {
        guard isChatActive != isActive else { return }
        isChatActive = isActive
        Task { await refreshLiveConversationState() }
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        Task {
            if muted {
                await handleMuteActivated()
            } else {
                await refreshLiveConversationState()
            }
        }
    }

    func interruptAssistantSpeech() {
        guard appState == .speaking else { return }
        Task { await bargeIn(reason: "button_interrupt") }
    }

    func micPressed() {
        AppLogger.audio.debug("[PTT] micPressed — mode=\(self.recordingMode.rawValue, privacy: .public) chatActive=\(self.isChatActive) listening=\(self.transcriber.isListening) isStarting=\(self.isStartingRecording) isStopping=\(self.isStoppingRecording) state=\(self.appState.rawValue, privacy: .public)")
        guard recordingMode == .pushToTalk else {
            AppLogger.audio.debug("[PTT] micPressed SKIP: not pushToTalk")
            return
        }
        guard isChatActive else {
            AppLogger.audio.debug("[PTT] micPressed SKIP: chat not active")
            return
        }
        guard !transcriber.isListening, !isStartingRecording else {
            AppLogger.audio.debug("[PTT] micPressed SKIP: already listening or starting")
            return
        }
        isStartingRecording = true
        pendingPTTRelease = false
        AppLogger.audio.debug("[PTT] micPressed — set isStartingRecording=true, launching start task")
        Task {
            defer {
                isStartingRecording = false
                AppLogger.audio.debug("[PTT] micPressed task defer — isStartingRecording=false")
            }
            if appState == .speaking {
                AppLogger.audio.debug("[PTT] micPressed — barging in (was speaking)")
                await bargeIn(reason: "ptt_barge_in")
            }
            AppLogger.audio.debug("[PTT] micPressed — calling startListeningPTT")
            await startListeningPTT()
            AppLogger.audio.debug("[PTT] micPressed — startListeningPTT returned, pendingRelease=\(self.pendingPTTRelease) transcriber.isListening=\(self.transcriber.isListening)")
            if pendingPTTRelease {
                pendingPTTRelease = false
                AppLogger.audio.debug("[PTT] micPressed — handling pending release, calling stopListeningAndProcess")
                await stopListeningAndProcess()
            }
        }
    }

    func micReleased() {
        AppLogger.audio.debug("[PTT] micReleased — mode=\(self.recordingMode.rawValue, privacy: .public) isStarting=\(self.isStartingRecording) isStopping=\(self.isStoppingRecording) listening=\(self.transcriber.isListening) state=\(self.appState.rawValue, privacy: .public)")
        guard recordingMode == .pushToTalk else {
            AppLogger.audio.debug("[PTT] micReleased SKIP: not pushToTalk")
            return
        }
        guard !isStoppingRecording else {
            AppLogger.audio.debug("[PTT] micReleased SKIP: already stopping")
            return
        }
        if isStartingRecording {
            pendingPTTRelease = true
            AppLogger.audio.debug("[PTT] micReleased — start in progress, set pendingPTTRelease=true")
            return
        }
        guard transcriber.isListening else {
            AppLogger.audio.debug("[PTT] micReleased SKIP: transcriber not listening")
            return
        }
        AppLogger.audio.debug("[PTT] micReleased — transcriber is listening, launching stop task")
        Task { await stopListeningAndProcess() }
    }

    func applyRemoteState(_ requestedState: AppState) async {
        AppLogger.audio.debug("[PTT] applyRemoteState — requested=\(requestedState.rawValue, privacy: .public) mode=\(self.recordingMode.rawValue, privacy: .public) listening=\(self.transcriber.isListening) isStarting=\(self.isStartingRecording) state=\(self.appState.rawValue, privacy: .public)")
        let effectiveState: AppState
        if isMuted && (requestedState == .listening || requestedState == .transcribing) {
            effectiveState = .idle
        } else {
            effectiveState = requestedState
        }

        let preservePTTRecording = recordingMode == .pushToTalk
            && (transcriber.isListening || isStartingRecording)
            && (appState == .listening || appState == .transcribing)
            && effectiveState != .listening
            && effectiveState != .transcribing

        guard !preservePTTRecording else {
            AppLogger.audio.debug("[PTT] applyRemoteState — preserving PTT recording, ignoring state change to \(effectiveState.rawValue, privacy: .public)")
            return
        }

        setState(effectiveState)

        switch effectiveState {
        case .idle:
            await refreshLiveConversationState()
        case .thinking, .speaking, .error:
            voiceActivityDetector.stopMonitoring()
            if recordingMode == .vadAuto {
                await stopRemoteVoiceCapture()
            } else if transcriber.isListening && !isStoppingRecording {
                await stopListeningSilently()
            }
        case .listening, .transcribing:
            await refreshLiveConversationState()
        }
    }

    func handlePartialTranscript(_ text: String) {
        guard recordingMode == .pushToTalk else { return }
        guard !isPlaceholderTranscript(text) else { return }
        partialTranscript = text
        eventBus.emit(Event.transcriptPartial(text, sessionId: sessionId))

        if appState == .listening {
            setState(.transcribing)
        }
    }

    private var canRunLiveConversation: Bool {
        isChatActive && !isMuted
    }

    private var shouldStreamRemoteVoiceCapture: Bool {
        canRunLiveConversation
            && recordingMode == .vadAuto
            && appState != .thinking
            && appState != .speaking
            && appState != .error
    }

    private func configureVoicePipeline() {
        voiceActivityDetector.onSpeechStarted = { [weak self] in
            guard let self else { return }
            guard self.canRunLiveConversation else { return }

            if self.appState == .idle || self.appState == .transcribing {
                self.setState(.listening)
            }
        }

        voiceActivityDetector.onSpeechEnded = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.recordingMode == .vadAuto else { return }
                guard self.canRunLiveConversation else { return }
                guard self.transcriber.isListening else { return }
                guard !self.isStoppingRecording else { return }
                await self.stopListeningAndProcess()
            }
        }

        if let whisperTranscriber = transcriber as? WhisperKitSpeechTranscriber {
            whisperTranscriber.onAudioLevel = { [weak self] level in
                self?.voiceActivityDetector.processAudioLevel(level)
            }
        }
    }

    private func refreshLiveConversationState() async {
        if recordingMode == .vadAuto {
            if transcriber.isListening && !isStoppingRecording {
                await stopListeningSilently()
            }
            await refreshRemoteVoiceConversationState()
            return
        }

        await stopRemoteVoiceCapture()

        if canRunLiveConversation {
            if appState != .speaking && appState != .thinking && !transcriber.isListening && !isStartingRecording {
                setState(.idle)
            }
            return
        }

        voiceActivityDetector.stopMonitoring()

        if transcriber.isListening && !isStoppingRecording {
            await stopListeningSilently()
        }

        if appState != .speaking && appState != .thinking {
            setState(.idle)
        }
    }

    private func handleMuteActivated() async {
        voiceActivityDetector.stopMonitoring()

        if recordingMode == .vadAuto {
            await stopRemoteVoiceCapture()
            if appState == .listening || appState == .transcribing || appState == .idle {
                setState(.idle)
            }
            return
        }

        if transcriber.isListening && !isStoppingRecording {
            await stopListeningAndProcess()
            return
        }

        if appState == .listening || appState == .transcribing || appState == .idle {
            setState(.idle)
        }
    }

    private func startListeningPTT() async {
        AppLogger.audio.debug("[PTT] startListeningPTT — mode=\(self.recordingMode.rawValue, privacy: .public) isStopping=\(self.isStoppingRecording)")
        guard recordingMode == .pushToTalk else {
            AppLogger.audio.debug("[PTT] startListeningPTT SKIP: not pushToTalk")
            return
        }
        guard !isStoppingRecording else {
            AppLogger.audio.debug("[PTT] startListeningPTT SKIP: currently stopping")
            return
        }

        partialTranscript = ""
        setState(.listening)
        AppLogger.audio.debug("[PTT] startListeningPTT — state set to listening, dispatching convo.setState")

        let setStateEvent = Event.toolCall(
            name: ConvoSetStateTool.name,
            arguments: encode(ConvoSetStateTool.Arguments(state: AppState.listening.rawValue)),
            sessionId: sessionId
        )
        eventBus.emit(setStateEvent)
        if case .toolCall(let toolCall) = setStateEvent.kind {
            await toolRouter.dispatch(toolCall)
        }

        guard !transcriber.isListening else {
            AppLogger.audio.debug("[PTT] startListeningPTT — transcriber already listening, skipping STT start")
            return
        }

        AppLogger.audio.debug("[PTT] startListeningPTT — dispatching stt.start")
        let sttEvent = Event.toolCall(
            name: STTStartTool.name,
            arguments: encode(STTStartTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttEvent)
        if case .toolCall(let toolCall) = sttEvent.kind {
            let result = await toolRouter.dispatch(toolCall)
            if case .toolResult(let toolResult) = result.kind, toolResult.isError {
                AppLogger.audio.error("[PTT] startListeningPTT — STT start FAILED: \(toolResult.error ?? "unknown", privacy: .public)")
                await handleError(toolResult.error ?? "STT start failed")
            } else {
                AppLogger.audio.debug("[PTT] startListeningPTT — STT started OK, transcriber.isListening=\(self.transcriber.isListening)")
            }
        }
    }

    private func stopListeningSilently() async {
        AppLogger.audio.debug("[PTT] stopListeningSilently — mode=\(self.recordingMode.rawValue, privacy: .public) listening=\(self.transcriber.isListening)")
        guard recordingMode == .pushToTalk else { return }
        guard transcriber.isListening else { return }

        AppLogger.audio.debug("[PTT] stopListeningSilently — stopping transcriber without processing")
        isStoppingRecording = true
        defer { isStoppingRecording = false }

        let stopEvent = Event.toolCall(
            name: STTStopTool.name,
            arguments: encode(STTStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(stopEvent)
        if case .toolCall(let toolCall) = stopEvent.kind {
            _ = await toolRouter.dispatch(toolCall)
        }
        partialTranscript = ""
    }

    private func stopListeningAndProcess() async {
        AppLogger.audio.debug("[PTT] stopListeningAndProcess — mode=\(self.recordingMode.rawValue, privacy: .public) listening=\(self.transcriber.isListening) isStopping=\(self.isStoppingRecording) state=\(self.appState.rawValue, privacy: .public)")
        guard recordingMode == .pushToTalk else {
            AppLogger.audio.debug("[PTT] stopListeningAndProcess SKIP: not pushToTalk")
            return
        }
        guard transcriber.isListening else {
            AppLogger.audio.debug("[PTT] stopListeningAndProcess SKIP: transcriber not listening")
            return
        }

        AppLogger.audio.debug("[PTT] stopListeningAndProcess — proceeding with stop")
        isStoppingRecording = true
        defer {
            isStoppingRecording = false
            AppLogger.audio.debug("[PTT] stopListeningAndProcess defer — isStopping=false")
        }

        voiceActivityDetector.stopMonitoring()
        setState(.transcribing)

        let setTranscribingEvent = Event.toolCall(
            name: ConvoSetStateTool.name,
            arguments: encode(ConvoSetStateTool.Arguments(state: AppState.transcribing.rawValue)),
            sessionId: sessionId
        )
        eventBus.emit(setTranscribingEvent)
        if case .toolCall(let toolCall) = setTranscribingEvent.kind {
            await toolRouter.dispatch(toolCall)
        }

        let sttStopEvent = Event.toolCall(
            name: STTStopTool.name,
            arguments: encode(STTStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttStopEvent)

        var finalTranscript = partialTranscript
        if case .toolCall(let toolCall) = sttStopEvent.kind {
            let result = await toolRouter.dispatch(toolCall)
            if case .toolResult(let toolResult) = result.kind {
                if toolResult.isError {
                    AppLogger.audio.error("STT stop failed: \(toolResult.error ?? "unknown", privacy: .public)")
                } else if let json = toolResult.result,
                          let decoded = try? JSONDecoder().decode(STTStopTool.Result.self, from: Data(json.utf8)) {
                    finalTranscript = decoded.finalTranscript
                } else {
                    AppLogger.audio.warning("STT stop result could not be decoded")
                }
            }
        }

        if isPlaceholderTranscript(finalTranscript) {
            finalTranscript = ""
        }

        if finalTranscript.isEmpty {
            let fallback = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isPlaceholderTranscript(fallback), !fallback.isEmpty {
                finalTranscript = fallback
            }
        }

        let normalizedTranscript = transcriptFormatter.normalizeForAgent(finalTranscript)
        AppLogger.audio.debug("[PTT] stopListeningAndProcess — finalTranscript='\(finalTranscript, privacy: .public)' normalized='\(normalizedTranscript, privacy: .public)'")
        guard !normalizedTranscript.isEmpty else {
            AppLogger.audio.debug("[PTT] stopListeningAndProcess — empty transcript, resetting to idle")
            let resetEvent = Event.toolCall(
                name: ConvoSetStateTool.name,
                arguments: encode(ConvoSetStateTool.Arguments(state: AppState.idle.rawValue)),
                sessionId: sessionId
            )
            eventBus.emit(resetEvent)
            if case .toolCall(let toolCall) = resetEvent.kind {
                await toolRouter.dispatch(toolCall)
            }
            setState(.idle)
            partialTranscript = ""
            await refreshLiveConversationState()
            return
        }

        AppLogger.audio.debug("[PTT] stopListeningAndProcess — sending transcript to conductor: '\(normalizedTranscript, privacy: .public)'")
        let transcriptEvent = Event.transcriptFinal(normalizedTranscript, sessionId: sessionId)
        eventBus.emit(transcriptEvent)
        await sendConductorEvent(transcriptEvent, true)
        AppLogger.audio.debug("[PTT] stopListeningAndProcess — transcript sent, done")

        partialTranscript = ""
    }

    private func bargeIn(reason: String) async {
        voiceActivityDetector.stopMonitoring()

        if recordingMode == .pushToTalk {
            let stopEvent = Event.toolCall(
                name: TTSStopTool.name,
                arguments: encode(TTSStopTool.Arguments()),
                sessionId: sessionId
            )
            eventBus.emit(stopEvent)
            if case .toolCall(let toolCall) = stopEvent.kind {
                await toolRouter.dispatch(toolCall)
            }
        } else {
            await stopRemoteAssistantAudio()
        }

        let interruptedEvent = Event.audioOutputInterrupted(reason, sessionId: sessionId)
        eventBus.emit(interruptedEvent)
        Task {
            await sendConductorEvent(interruptedEvent, false)
        }

        await refreshLiveConversationState()
    }

    private func setState(_ state: AppState) {
        appStateStore.current = state
        appState = state
    }

    func handleAssistantAudioChunk(_ chunk: Event.AssistantAudioChunk) async {
        guard recordingMode == .vadAuto else { return }
        guard let data = Data(base64Encoded: chunk.audio), !data.isEmpty else { return }
        if remoteVoiceCapture.isStreaming {
            await stopRemoteVoiceCapture()
        }
        do {
            if !remotePlaybackPrepared {
                try await MainActor.run {
                    try StreamingPCMPlayer.shared.prepareForPlayback(sampleRate: Double(chunk.sampleRateHertz))
                }
                remotePlaybackPrepared = true
            }
            try await MainActor.run {
                try StreamingPCMPlayer.shared.append(data)
            }
        } catch {
            await handleError(error.localizedDescription)
        }
    }

    func handleAssistantAudioEnd() async {
        guard recordingMode == .vadAuto, remotePlaybackPrepared else { return }
        await MainActor.run {
            StreamingPCMPlayer.shared.finishReceivingAudio()
        }
        remotePlaybackPrepared = false
    }

    func handleAssistantAudioInterrupted() async {
        guard recordingMode == .vadAuto else { return }
        await stopRemoteAssistantAudio()
    }

    private func refreshRemoteVoiceConversationState() async {
        if shouldStreamRemoteVoiceCapture {
            await startRemoteVoiceCapture()
            return
        }

        await stopRemoteVoiceCapture()
        if !canRunLiveConversation && appState != .speaking && appState != .thinking {
            setState(.idle)
        }
    }

    private func startRemoteVoiceCapture() async {
        guard shouldStreamRemoteVoiceCapture else { return }
        guard !remoteVoiceCapture.isStreaming else { return }
        do {
            partialTranscript = ""
            setState(.listening)
            let startEvent = Event.userAudioStreamStart(sessionId: sessionId)
            eventBus.emit(startEvent)
            await sendConductorEvent(startEvent, true)
            try await remoteVoiceCapture.start(onChunk: { [weak self] base64Chunk in
                guard let self else { return }
                Task { @MainActor in
                    let chunkEvent = Event.userAudioStreamChunk(audio: base64Chunk, sessionId: self.sessionId)
                    self.eventBus.emit(chunkEvent)
                    await self.sendConductorEvent(chunkEvent, false)
                }
            })
        } catch {
            await handleError(error.localizedDescription)
        }
    }

    private func stopRemoteVoiceCapture() async {
        guard remoteVoiceCapture.isStreaming else { return }
        await remoteVoiceCapture.stop()

        // Send trailing silence so Nova Sonic's server-side VAD detects
        // end-of-speech. Sent inline (before the end event) to avoid a gap
        // between real audio and silence that could cause false barge-in.
        let silenceData = Data(repeating: 0, count: 3200) // 100ms at 16kHz/16-bit/mono
        let silenceBase64 = silenceData.base64EncodedString()
        for _ in 0..<10 {
            let chunkEvent = Event.userAudioStreamChunk(audio: silenceBase64, sessionId: sessionId)
            eventBus.emit(chunkEvent)
            await sendConductorEvent(chunkEvent, false)
        }

        let endEvent = Event.userAudioStreamEnd(sessionId: sessionId)
        eventBus.emit(endEvent)
        await sendConductorEvent(endEvent, false)
    }

    private func stopRemoteAssistantAudio() async {
        remotePlaybackPrepared = false
        await MainActor.run {
            StreamingPCMPlayer.shared.stop()
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func isPlaceholderTranscript(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalized.isEmpty
            || normalized.hasPrefix("listening")
            || normalized.hasPrefix("[audio level")
            || normalized == "[no audio captured]"
    }
}

@MainActor
protocol RemoteVoiceCapturing: AnyObject {
    var isStreaming: Bool { get }
    func start(onChunk: @escaping (String) -> Void) async throws
    func stop() async
}

@MainActor
private final class RemoteAudioCapture: RemoteVoiceCapturing {
    private let targetSampleRate: Double = 16_000
    private let emissionChunkBytes = 3_200

    private var engine: AVAudioEngine?
    private var onChunk: ((String) -> Void)?
    private var pendingPCM = Data()
    private(set) var isStreaming = false

    func start(onChunk: @escaping (String) -> Void) async throws {
        guard !isStreaming else { return }
        self.onChunk = onChunk

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }

            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            let resampled = self.resampleTo16k(samples: samples, sourceRate: format.sampleRate)
            guard !resampled.isEmpty else { return }

            var chunk = Data(capacity: resampled.count * 2)
            for sample in resampled {
                let clamped = max(-1.0, min(1.0, sample))
                var intSample = Int16(clamped * Float(Int16.max))
                withUnsafeBytes(of: &intSample) { chunk.append(contentsOf: $0) }
            }

            Task { @MainActor in
                self.pendingPCM.append(chunk)
                self.flushIfNeeded()
            }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        self.isStreaming = true
    }

    func stop() async {
        guard isStreaming else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        flushRemaining()
        pendingPCM.removeAll(keepingCapacity: false)
        isStreaming = false
        onChunk = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func flushIfNeeded() {
        guard pendingPCM.count >= emissionChunkBytes else { return }
        let chunk = pendingPCM.prefix(emissionChunkBytes)
        pendingPCM.removeFirst(emissionChunkBytes)
        onChunk?(Data(chunk).base64EncodedString())
    }

    private func flushRemaining() {
        guard !pendingPCM.isEmpty else { return }
        onChunk?(pendingPCM.base64EncodedString())
    }

    private func resampleTo16k(samples: [Float], sourceRate: Double) -> [Float] {
        guard sourceRate > 0, sourceRate != targetSampleRate else { return samples }
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
}
