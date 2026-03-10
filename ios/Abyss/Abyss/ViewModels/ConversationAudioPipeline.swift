import Combine
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

    init(
        transcriber: SpeechTranscriber,
        tts: TextToSpeech,
        transcriptFormatter: FastTranscriptFormatter,
        eventBus: EventBus,
        toolRouter: ToolRouter,
        appStateStore: AppStateStore,
        sessionId: String,
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
        self.sendConductorEvent = sendConductorEvent
        self.handleError = handleError

        configureVoicePipeline()
    }

    deinit {
        voiceActivityDetector.stopMonitoring()
        if let whisperTranscriber = transcriber as? WhisperKitSpeechTranscriber {
            whisperTranscriber.onAudioLevel = nil
        }
    }

    func preloadTranscriber() {
        let transcriber = self.transcriber
        Task {
            await transcriber.preload()
        }
    }

    func updateRecordingMode(_ mode: RecordingMode) {
        guard recordingMode != mode else { return }
        recordingMode = mode
        if mode == .pushToTalk {
            voiceActivityDetector.stopMonitoring()
        }
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
        guard recordingMode == .pushToTalk else { return }
        guard isChatActive else { return }
        guard !transcriber.isListening, !isStartingRecording else { return }
        Task {
            if appState == .speaking {
                await bargeIn(reason: "ptt_barge_in")
            }
            await startListeningPTT()
        }
    }

    func micReleased() {
        guard recordingMode == .pushToTalk else { return }
        guard !isStoppingRecording else { return }
        guard transcriber.isListening || isStartingRecording else { return }
        Task { await stopListeningAndProcess() }
    }

    func applyRemoteState(_ requestedState: AppState) async {
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

        guard !preservePTTRecording else { return }

        setState(effectiveState)

        switch effectiveState {
        case .idle:
            await refreshLiveConversationState()
        case .thinking, .speaking, .error:
            voiceActivityDetector.stopMonitoring()
            if transcriber.isListening && !isStoppingRecording {
                await stopListeningSilently()
            }
        case .listening, .transcribing:
            break
        }
    }

    func handlePartialTranscript(_ text: String) {
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
        if canRunLiveConversation {
            guard appState != .speaking, appState != .thinking else { return }
            await startListening()
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

        if transcriber.isListening && !isStoppingRecording {
            await stopListeningAndProcess()
            return
        }

        if appState == .listening || appState == .transcribing || appState == .idle {
            setState(.idle)
        }
    }

    private func startListening() async {
        guard recordingMode == .vadAuto else { return }
        guard canRunLiveConversation else { return }
        guard !isStoppingRecording else { return }
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        partialTranscript = ""
        setState(.listening)

        let setStateEvent = Event.toolCall(
            name: ConvoSetStateTool.name,
            arguments: encode(ConvoSetStateTool.Arguments(state: AppState.listening.rawValue)),
            sessionId: sessionId
        )
        eventBus.emit(setStateEvent)
        if case .toolCall(let toolCall) = setStateEvent.kind {
            await toolRouter.dispatch(toolCall)
        }

        if transcriber.isListening {
            if !voiceActivityDetector.isMonitoring {
                voiceActivityDetector.startMonitoring()
            }
            return
        }

        let sttEvent = Event.toolCall(
            name: STTStartTool.name,
            arguments: encode(STTStartTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttEvent)
        if case .toolCall(let toolCall) = sttEvent.kind {
            let result = await toolRouter.dispatch(toolCall)
            if case .toolResult(let toolResult) = result.kind, toolResult.isError {
                await handleError(toolResult.error ?? "STT start failed")
                return
            }
        }

        if !voiceActivityDetector.isMonitoring {
            voiceActivityDetector.startMonitoring()
        }
    }

    private func startListeningPTT() async {
        guard !isStoppingRecording else { return }
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        partialTranscript = ""
        setState(.listening)

        let setStateEvent = Event.toolCall(
            name: ConvoSetStateTool.name,
            arguments: encode(ConvoSetStateTool.Arguments(state: AppState.listening.rawValue)),
            sessionId: sessionId
        )
        eventBus.emit(setStateEvent)
        if case .toolCall(let toolCall) = setStateEvent.kind {
            await toolRouter.dispatch(toolCall)
        }

        guard !transcriber.isListening else { return }

        let sttEvent = Event.toolCall(
            name: STTStartTool.name,
            arguments: encode(STTStartTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttEvent)
        if case .toolCall(let toolCall) = sttEvent.kind {
            let result = await toolRouter.dispatch(toolCall)
            if case .toolResult(let toolResult) = result.kind, toolResult.isError {
                await handleError(toolResult.error ?? "STT start failed")
            }
        }
    }

    private func stopListeningSilently() async {
        guard transcriber.isListening else { return }

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
        guard transcriber.isListening else { return }

        AppLogger.conversation.debug("Stopping recording; state=\(self.appState.rawValue, privacy: .public)")
        isStoppingRecording = true
        defer { isStoppingRecording = false }

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
        guard !normalizedTranscript.isEmpty else {
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

        let transcriptEvent = Event.transcriptFinal(normalizedTranscript, sessionId: sessionId)
        eventBus.emit(transcriptEvent)
        await sendConductorEvent(transcriptEvent, true)

        partialTranscript = ""
    }

    private func bargeIn(reason: String) async {
        voiceActivityDetector.stopMonitoring()

        let stopEvent = Event.toolCall(
            name: TTSStopTool.name,
            arguments: encode(TTSStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(stopEvent)
        if case .toolCall(let toolCall) = stopEvent.kind {
            await toolRouter.dispatch(toolCall)
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
