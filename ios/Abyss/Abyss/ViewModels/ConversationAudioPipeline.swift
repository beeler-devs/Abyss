import Combine
import AVFoundation
import Foundation

/// Owns the microphone, transcription, playback interruption, and conversation audio state machine.
/// `ConversationViewModel` mirrors its published UI state, and `EventCoordinator` asks it to apply remote state changes.
@MainActor
final class ConversationAudioPipeline: ObservableObject {
    @Published private(set) var appState: AppState = .idle
    @Published private(set) var partialTranscript: String = ""

    var isHandsFreeLiveConversationMode: Bool {
        recordingMode == .vadAuto
    }

    private let transcriber: SpeechTranscriber
    private let tts: TextToSpeech
    private let transcriptFormatter: FastTranscriptFormatter
    private let eventBus: EventBus
    private let toolRouter: ToolRouter
    private let appStateStore: AppStateStore
    private let sessionId: String
    private let sendConductorEvent: @MainActor @Sendable (Event, Bool) async -> Void
    private let handleError: @MainActor @Sendable (String) async -> Void
    private let isTTSMuted: @MainActor @Sendable () -> Bool

    private final class PendingRemoteStreamStart {
        var hasAnnouncedStart = false
        var bufferedChunks: [String] = []
    }

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
    private var remoteCaptureTransitionInFlight = false
    private var pendingRemoteCaptureReconcile = false
    private var handsFreeBargeInInFlight = false
    private var currentPlayingLiveResponseId: String?
    private var rejectedLiveResponseId: String?
    private let remoteVoiceCapture: RemoteVoiceCapturing

    init(
        transcriber: SpeechTranscriber,
        tts: TextToSpeech,
        transcriptFormatter: FastTranscriptFormatter,
        eventBus: EventBus,
        toolRouter: ToolRouter,
        appStateStore: AppStateStore,
        sessionId: String,
        remoteVoiceCapture: RemoteVoiceCapturing? = nil,
        isTTSMuted: @escaping @MainActor @Sendable () -> Bool = { false },
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
        self.isTTSMuted = isTTSMuted
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
        guard recordingMode == .pushToTalk, isChatActive else { return }
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
        guard appState == .speaking || tts.isSpeaking else { return }
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
        case .thinking, .speaking:
            // vadAuto: keep VAD monitoring so it can trigger bargeIn() when
            // the user speaks during assistant playback. Nova Sonic native
            // barge-in is unreliable when echo cancellation doesn't fully
            // suppress the assistant audio, so the iOS VAD is the primary
            // barge-in trigger.
            if recordingMode != .vadAuto {
                voiceActivityDetector.stopMonitoring()
            }
            if recordingMode == .pushToTalk && transcriber.isListening && !isStoppingRecording {
                await stopListeningSilently()
            }
        case .error:
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
        // Keep hands-free mode duplex so the server can detect genuine barge-in.
        canRunLiveConversation
            && recordingMode == .vadAuto
            && appState != .error
    }

    private func configureVoicePipeline() {
        voiceActivityDetector.onSpeechStarted = { [weak self] in
            guard let self else { return }
            guard self.canRunLiveConversation else { return }

            // Trigger bargeIn when assistant audio is active — either the state
            // is .speaking (audio still being generated) OR the state went to
            // .idle but buffered audio is still playing from the queue.
            let shouldBargeIn = self.recordingMode == .vadAuto
                && (self.appState == .speaking
                    || (self.appState == .idle && self.remoteVoiceCapture.isAssistantAudioPlaying))
            if shouldBargeIn {
                guard !self.handsFreeBargeInInFlight else {
                    AppLogger.audio.debug("[BARGE-IN] VAD speech detected but bargeIn already in flight")
                    return
                }
                AppLogger.audio.debug("[BARGE-IN] VAD speech detected during \(self.appState.rawValue, privacy: .public) — triggering bargeIn")
                self.handsFreeBargeInInFlight = true
                Task { @MainActor in
                    defer { self.handsFreeBargeInInFlight = false }
                    await self.bargeIn(reason: "local_speech_start")
                }
                return
            }

            AppLogger.audio.debug("[BARGE-IN] VAD speech detected but appState=\(self.appState.rawValue, privacy: .public) — NOT triggering bargeIn")
            if self.appState == .idle || self.appState == .transcribing {
                self.setState(.listening)
            }
        }

        voiceActivityDetector.onSpeechEnded = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.recordingMode == .pushToTalk else { return }
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
        if recordingMode == .pushToTalk {
            voiceActivityDetector.stopMonitoring()
        }

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
            // Capture the current response ID as rejected BEFORE stopping audio.
            // Late-arriving chunks with this ID will be dropped by handleAssistantAudioChunk.
            AppLogger.audio.debug("[BARGE-IN] bargeIn vadAuto: rejecting liveResponseId=\(self.currentPlayingLiveResponseId ?? "nil", privacy: .public) reason=\(reason, privacy: .public)")
            rejectedLiveResponseId = currentPlayingLiveResponseId
            currentPlayingLiveResponseId = nil
            await stopRemoteAssistantAudio()
            AppLogger.audio.debug("[BARGE-IN] bargeIn vadAuto: stopRemoteAssistantAudio completed")
        }

        let interruptedEvent = Event.audioOutputInterrupted(reason, sessionId: sessionId)
        eventBus.emit(interruptedEvent)
        Task {
            await sendConductorEvent(interruptedEvent, false)
        }

        if recordingMode == .vadAuto {
            setState(.listening)
            // vadAuto: mic is already streaming to Nova Sonic, no refresh needed.
            // Nova Sonic handles barge-in natively on the same stream.
        } else {
            await refreshLiveConversationState()
        }
    }

    private func setState(_ state: AppState) {
        appStateStore.current = state
        appState = state
    }

    func handleAssistantAudioChunk(_ chunk: Event.AssistantAudioChunk) async {
        guard recordingMode == .vadAuto else { return }

        // Gate: drop chunks from a rejected (interrupted) response
        if let rejected = rejectedLiveResponseId {
            if chunk.liveResponseId == rejected {
                AppLogger.audio.debug("[BARGE-IN] Dropped audio chunk with rejected liveResponseId=\(rejected, privacy: .public)")
                return
            }
            // New response arrived — clear the gate
            AppLogger.audio.debug("[BARGE-IN] Clearing gate: new liveResponseId=\(chunk.liveResponseId ?? "nil", privacy: .public) rejected=\(rejected, privacy: .public)")
            rejectedLiveResponseId = nil
        }

        currentPlayingLiveResponseId = chunk.liveResponseId

        guard !isTTSMuted() else { return }
        guard let data = Data(base64Encoded: chunk.audio), !data.isEmpty else { return }
        do {
            try await remoteVoiceCapture.appendAssistantAudio(
                data,
                sampleRate: Double(chunk.sampleRateHertz)
            )
        } catch {
            await handleError(error.localizedDescription)
        }
    }

    func handleAssistantAudioEnd() async {
        guard recordingMode == .vadAuto else { return }
        currentPlayingLiveResponseId = nil
        await remoteVoiceCapture.finishAssistantAudio()
    }

    func handleAssistantAudioInterrupted() async {
        guard recordingMode == .vadAuto else { return }
        AppLogger.audio.debug("[BARGE-IN] handleAssistantAudioInterrupted — stopping remote assistant audio")
        await stopRemoteAssistantAudio()
    }

    private func refreshRemoteVoiceConversationState() async {
        if remoteCaptureTransitionInFlight {
            pendingRemoteCaptureReconcile = true
            return
        }

        remoteCaptureTransitionInFlight = true
        defer {
            remoteCaptureTransitionInFlight = false
        }

        while true {
            pendingRemoteCaptureReconcile = false

            if shouldStreamRemoteVoiceCapture {
                await startRemoteVoiceCapture()
            } else {
                await stopRemoteVoiceCapture()
                if !canRunLiveConversation && appState != .speaking && appState != .thinking {
                    setState(.idle)
                }
            }

            guard pendingRemoteCaptureReconcile else { break }
        }
    }

    private func startRemoteVoiceCapture() async {
        guard shouldStreamRemoteVoiceCapture else { return }
        guard !remoteVoiceCapture.isStreaming else { return }
        do {
            partialTranscript = ""
            setState(.listening)
            voiceActivityDetector.startMonitoring()
            let pendingStart = PendingRemoteStreamStart()
            try await remoteVoiceCapture.start(
                onChunk: { [weak self] base64Chunk in
                    guard let self else { return }
                    Task { @MainActor in
                        if pendingStart.hasAnnouncedStart {
                            await self.sendRemoteAudioChunk(base64Chunk)
                        } else {
                            pendingStart.bufferedChunks.append(base64Chunk)
                        }
                    }
                },
                onInputLevel: { [weak self] level in
                    self?.voiceActivityDetector.processAudioLevel(level)
                }
            )
            let startEvent = Event.userAudioStreamStart(sessionId: sessionId)
            eventBus.emit(startEvent)
            await sendConductorEvent(startEvent, true)
            pendingStart.hasAnnouncedStart = true
            for bufferedChunk in pendingStart.bufferedChunks {
                await sendRemoteAudioChunk(bufferedChunk)
            }
            pendingStart.bufferedChunks.removeAll(keepingCapacity: false)
        } catch {
            voiceActivityDetector.stopMonitoring()
            AppLogger.audio.error("startRemoteVoiceCapture failed: \(error.localizedDescription, privacy: .public)")
            await handleError(error.localizedDescription)
        }
    }

    private func sendRemoteAudioChunk(_ base64Chunk: String) async {
        let chunkEvent = Event.userAudioStreamChunk(audio: base64Chunk, sessionId: sessionId)
        eventBus.emit(chunkEvent)
        await sendConductorEvent(chunkEvent, false)
    }

    private func stopRemoteVoiceCapture() async {
        guard remoteVoiceCapture.isStreaming else { return }
        voiceActivityDetector.stopMonitoring()
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
        await remoteVoiceCapture.stopAssistantAudio()
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
    var isAssistantAudioPlaying: Bool { get }
    func start(
        onChunk: @escaping (String) -> Void,
        onInputLevel: @escaping (Float) -> Void
    ) async throws
    func stop() async
    func appendAssistantAudio(_ data: Data, sampleRate: Double) async throws
    func finishAssistantAudio() async
    func stopAssistantAudio() async
}

@MainActor
final class BufferedPCMPlaybackQueue {
    struct DrainResult {
        let chunks: [Data]
        let shouldStartPlayback: Bool
    }

    private let startupThresholdBytes: Int
    private let scheduledChunkBytes: Int

    private var pendingAudio = Data()
    private var scheduledBufferCount = 0
    private var playbackStarted = false
    private var finishedReceivingAudio = false

    init(
        startupThresholdBytes: Int = 16_384,
        scheduledChunkBytes: Int = 8_192
    ) {
        self.startupThresholdBytes = startupThresholdBytes
        self.scheduledChunkBytes = scheduledChunkBytes
    }

    func enqueue(_ data: Data, bytesPerFrame: Int) -> DrainResult {
        guard !data.isEmpty else { return DrainResult(chunks: [], shouldStartPlayback: false) }
        finishedReceivingAudio = false
        pendingAudio.append(data)
        return drain(force: false, bytesPerFrame: bytesPerFrame)
    }

    func finish(bytesPerFrame: Int) -> DrainResult {
        finishedReceivingAudio = true
        return drain(force: true, bytesPerFrame: bytesPerFrame)
    }

    func didPlayBuffer(bytesPerFrame: Int) -> DrainResult {
        scheduledBufferCount = max(0, scheduledBufferCount - 1)
        let result = drain(force: finishedReceivingAudio, bytesPerFrame: bytesPerFrame)
        if finishedReceivingAudio, scheduledBufferCount == 0, pendingAudio.isEmpty {
            playbackStarted = false
            finishedReceivingAudio = false
        }
        return result
    }

    func reset() {
        pendingAudio.removeAll(keepingCapacity: false)
        scheduledBufferCount = 0
        playbackStarted = false
        finishedReceivingAudio = false
    }

    var hasBufferedAudio: Bool {
        !pendingAudio.isEmpty || scheduledBufferCount > 0
    }

    private func drain(force: Bool, bytesPerFrame: Int) -> DrainResult {
        guard bytesPerFrame > 0 else {
            return DrainResult(chunks: [], shouldStartPlayback: false)
        }

        var chunks: [Data] = []
        while pendingAudio.count >= scheduledChunkBytes || (force && pendingAudio.count >= bytesPerFrame) {
            let targetBytes = min(pendingAudio.count, scheduledChunkBytes)
            let bufferBytes = targetBytes - (targetBytes % bytesPerFrame)
            guard bufferBytes >= bytesPerFrame else { break }

            chunks.append(Data(pendingAudio.prefix(bufferBytes)))
            pendingAudio.removeFirst(bufferBytes)
            scheduledBufferCount += 1
        }

        let bufferedBytes = pendingAudio.count + scheduledBufferCount * scheduledChunkBytes
        let shouldStartPlayback = !playbackStarted
            && scheduledBufferCount > 0
            && (bufferedBytes >= startupThresholdBytes || finishedReceivingAudio)
        if shouldStartPlayback {
            playbackStarted = true
        }

        return DrainResult(chunks: chunks, shouldStartPlayback: shouldStartPlayback)
    }
}

@MainActor
private final class RemoteAudioCapture: RemoteVoiceCapturing {
    private static let targetSampleRate: Double = 16_000
    private static let preferredHardwareSampleRate: Double = 48_000

    private final class CaptureRunState {
        struct Snapshot {
            let callbackCount: Int
            let totalFrames: Int64
            let firstCallbackAfterMilliseconds: Double?
        }

        private let lock = NSLock()
        private var token = 0
        private var startUptime = ProcessInfo.processInfo.systemUptime
        private var firstCallbackUptime: TimeInterval?
        private var callbackCount = 0
        private var totalFrames: Int64 = 0

        func begin(token: Int) {
            lock.lock()
            self.token = token
            startUptime = ProcessInfo.processInfo.systemUptime
            firstCallbackUptime = nil
            callbackCount = 0
            totalFrames = 0
            lock.unlock()
        }

        func recordCallback(token: Int, frameCount: Int) -> (isFirst: Bool, snapshot: Snapshot)? {
            lock.lock()
            defer { lock.unlock() }
            guard self.token == token else { return nil }

            callbackCount += 1
            totalFrames += Int64(frameCount)

            let now = ProcessInfo.processInfo.systemUptime
            let isFirst = firstCallbackUptime == nil
            if isFirst {
                firstCallbackUptime = now
            }

            return (isFirst, Snapshot(
                callbackCount: callbackCount,
                totalFrames: totalFrames,
                firstCallbackAfterMilliseconds: firstCallbackUptime.map { ($0 - startUptime) * 1_000 }
            ))
        }

        func snapshot(token: Int) -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard self.token == token else { return nil }

            return Snapshot(
                callbackCount: callbackCount,
                totalFrames: totalFrames,
                firstCallbackAfterMilliseconds: firstCallbackUptime.map { ($0 - startUptime) * 1_000 }
            )
        }
    }

    private let emissionChunkBytes = 3_200
    private let captureLogLimit = 5
    private let assistantPlaybackQueue = BufferedPCMPlaybackQueue()

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureSinkNode: AVAudioSinkNode?
    private var playbackFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var onChunk: ((String) -> Void)?
    private var onInputLevel: ((Float) -> Void)?
    private var pendingPCM = Data()
    private(set) var isStreaming = false
    private var captureDiagnosticsRemaining = 5
    private var captureWatchdogTask: Task<Void, Never>?
    private var captureStartToken = 0
    private let captureRunState = CaptureRunState()

    func start(
        onChunk: @escaping (String) -> Void,
        onInputLevel: @escaping (Float) -> Void
    ) async throws {
        guard !isStreaming else { return }
        self.onChunk = onChunk
        self.onInputLevel = onInputLevel

        let session = AVAudioSession.sharedInstance()
        do {
            try configureAudioSession(session)
        } catch {
            logAudioError("Hands-free audio session configuration failed", error: error)
            logSessionState(session, stage: "config-failed")
            throw error
        }
        logSessionState(session, stage: "configured")
        logRuntimeEnvironment()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        let inputNode = engine.inputNode
        let outputNode = engine.outputNode

        enableVoiceProcessing(on: inputNode, label: "input")

        let captureFormat = inputNode.outputFormat(forBus: 0)
        let sinkNode = makeCaptureSinkNode(format: captureFormat, startToken: captureStartToken + 1)
        engine.attach(sinkNode)
        engine.connect(inputNode, to: sinkNode, format: captureFormat)

        // Build assistant playback around the voice-processing I/O rate.
        // On device the mixer's pre-start format can still report 44.1kHz even when
        // voice-processing input is already fixed at 48kHz, and using that stale rate
        // causes the duplex graph to fail silently with engine.isRunning == false.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let playbackSampleRate = resolvedPlaybackSampleRate(
            captureFormat: captureFormat,
            mixerFormat: mixerFormat,
            session: session
        )
        let playbackFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: 1,
            interleaved: false
        )!
        self.playbackFormat = playbackFmt
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFmt)
        // Explicitly set the mixer→output format to the voice-processing rate.
        // Without this, the mixer→output path defaults to 44.1kHz stereo while
        // voice-processing input runs at 48kHz mono — the rate mismatch causes
        // the duplex graph to silently stop delivering mic frames.
        engine.connect(engine.mainMixerNode, to: outputNode, format: playbackFmt)
        captureDiagnosticsRemaining = captureLogLimit
        captureStartToken += 1
        captureRunState.begin(token: captureStartToken)

        logEngineGraph(
            engine,
            inputNode: inputNode,
            outputNode: outputNode,
            playerNode: playerNode,
            sinkNode: sinkNode,
            stage: "pre-start"
        )
        // Override to speaker BEFORE starting the engine so the route is
        // settled when the graph spins up. Doing it after start can cause
        // a transient route change that makes engine.isRunning flicker.
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            AppLogger.audio.warning("Hands-free route override failed: \(error.localizedDescription, privacy: .public)")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logAudioError("Hands-free audio engine start threw", error: error)
            logSessionState(session, stage: "engine-start-threw")
            logEngineGraph(
                engine,
                inputNode: inputNode,
                outputNode: outputNode,
                playerNode: playerNode,
                sinkNode: sinkNode,
                stage: "engine-start-threw"
            )
            throw error
        }

        // The engine can take a moment to stabilize after start, especially
        // on device with voice processing enabled. Retry briefly before
        // declaring failure.
        if !engine.isRunning {
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if engine.isRunning { break }
            }
        }
        if !engine.isRunning {
            logSessionState(session, stage: "start-failed")
            logEngineGraph(
                engine,
                inputNode: inputNode,
                outputNode: outputNode,
                playerNode: playerNode,
                sinkNode: sinkNode,
                stage: "start-failed"
            )
            throw NSError(
                domain: "RemoteAudioCapture",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Hands-free audio engine did not enter a running state"]
            )
        }
        self.engine = engine
        self.playerNode = playerNode
        self.captureSinkNode = sinkNode
        self.captureFormat = captureFormat
        self.isStreaming = true
        logSessionState(session, stage: "started")
        logEngineGraph(
            engine,
            inputNode: inputNode,
            outputNode: outputNode,
            playerNode: playerNode,
            sinkNode: sinkNode,
            stage: "post-start"
        )
        scheduleCaptureWatchdog(startToken: captureStartToken)
    }

    func stop() async {
        guard isStreaming else { return }
        captureWatchdogTask?.cancel()
        captureWatchdogTask = nil
        await stopAssistantAudio()
        engine?.stop()
        engine = nil
        playerNode = nil
        captureSinkNode = nil
        captureFormat = nil
        playbackFormat = nil
        onInputLevel = nil
        assistantPlaybackQueue.reset()
        flushRemaining()
        pendingPCM.removeAll(keepingCapacity: false)
        isStreaming = false
        onChunk = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func appendAssistantAudio(_ data: Data, sampleRate: Double) async throws {
        guard !data.isEmpty else { return }
        guard let engine, let playerNode, let playbackFormat else {
            throw NSError(
                domain: "RemoteAudioCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Hands-free audio engine is not active"]
            )
        }

        // Parse Int16 samples from incoming data
        let int16Count = data.count / 2
        guard int16Count > 0 else { return }
        var floatSamples = [Float](repeating: 0, count: int16Count)
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<int16Count {
                floatSamples[i] = Float(source[i]) / Float(Int16.max)
            }
        }

        // Resample from source rate to playback format rate (e.g. 24kHz → 48kHz)
        let resampled = Self.resample(samples: floatSamples, from: sampleRate, to: playbackFormat.sampleRate)
        guard !resampled.isEmpty else { return }

        let bytesPerFrame = Self.bytesPerFrame(for: playbackFormat)
        guard bytesPerFrame > 0 else {
            throw NSError(
                domain: "RemoteAudioCapture",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid assistant playback format"]
            )
        }

        let playbackData = Self.encodeFloat32(samples: resampled)
        let drainResult = assistantPlaybackQueue.enqueue(playbackData, bytesPerFrame: bytesPerFrame)
        try scheduleAssistantPlayback(drainResult, engine: engine, playerNode: playerNode, format: playbackFormat)
    }

    func finishAssistantAudio() async {
        guard let engine, let playerNode, let playbackFormat else { return }
        let bytesPerFrame = Self.bytesPerFrame(for: playbackFormat)
        guard bytesPerFrame > 0 else { return }

        let drainResult = assistantPlaybackQueue.finish(bytesPerFrame: bytesPerFrame)
        do {
            try scheduleAssistantPlayback(drainResult, engine: engine, playerNode: playerNode, format: playbackFormat)
        } catch {
            AppLogger.audio.error("Hands-free assistant playback finish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isAssistantAudioPlaying: Bool {
        playerNode?.isPlaying ?? false
    }

    func stopAssistantAudio() async {
        playerNode?.stop()
        playerNode?.reset()
        assistantPlaybackQueue.reset()
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

    private func configureAudioSession(_ session: AVAudioSession) throws {
        try configureSessionCategory(session)
        applySessionPreference("preferredSampleRate") {
            try session.setPreferredSampleRate(Self.preferredHardwareSampleRate)
        }
        applySessionPreference("preferredIOBufferDuration") {
            try session.setPreferredIOBufferDuration(0.02)
        }
        applySessionPreference("preferredInputNumberOfChannels") {
            try session.setPreferredInputNumberOfChannels(1)
        }
        try session.setActive(true)
    }

    private func configureSessionCategory(_ session: AVAudioSession) throws {
        let optionAttempts: [AVAudioSession.CategoryOptions] = [
            [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers],
            [.defaultToSpeaker, .allowBluetoothHFP],
            [.defaultToSpeaker]
        ]

        var lastError: Error?
        for options in optionAttempts {
            do {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
                AppLogger.audio.debug(
                    "Hands-free session category configured with options=\(self.describeCategoryOptions(options), privacy: .public)"
                )
                return
            } catch {
                lastError = error
                logAudioError(
                    "Hands-free session setCategory failed for options=\(describeCategoryOptions(options))",
                    error: error,
                    level: .warning
                )
            }
        }

        throw lastError ?? NSError(
            domain: "RemoteAudioCapture",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Unable to configure AVAudioSession category"]
        )
    }

    private func applySessionPreference(
        _ label: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
        } catch {
            let nsError = error as NSError
            AppLogger.audio.warning(
                """
                Hands-free session preference \(label, privacy: .public) failed: \
                domain=\(nsError.domain, privacy: .public) code=\(nsError.code) \
                message=\(nsError.localizedDescription, privacy: .public)
                """
            )
        }
    }

    private func describeCategoryOptions(_ options: AVAudioSession.CategoryOptions) -> String {
        var labels: [String] = []
        if options.contains(.defaultToSpeaker) {
            labels.append("defaultToSpeaker")
        }
        if options.contains(.allowBluetoothHFP) {
            labels.append("allowBluetoothHFP")
        }
        if options.contains(.duckOthers) {
            labels.append("duckOthers")
        }
        return labels.isEmpty ? "none" : labels.joined(separator: ",")
    }

    private enum AudioErrorLogLevel {
        case warning
        case error
    }

    private func logAudioError(
        _ message: String,
        error: Error,
        level: AudioErrorLogLevel = .error
    ) {
        let nsError = error as NSError
        switch level {
        case .warning:
            AppLogger.audio.warning(
                "\(message, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(nsError.localizedDescription, privacy: .public)"
            )
        case .error:
            AppLogger.audio.error(
                "\(message, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(nsError.localizedDescription, privacy: .public)"
            )
        }
    }

    private func resolvedPlaybackSampleRate(
        captureFormat: AVAudioFormat,
        mixerFormat: AVAudioFormat,
        session: AVAudioSession
    ) -> Double {
        let captureRate = captureFormat.sampleRate
        let sessionRate = session.sampleRate
        let mixerRate = mixerFormat.sampleRate

        if abs(mixerRate - captureRate) > 1 {
            AppLogger.audio.warning(
                """
                Hands-free playback rate mismatch before start: capture=\(captureRate, privacy: .public) \
                mixer=\(mixerRate, privacy: .public) session=\(sessionRate, privacy: .public). \
                Using capture/session hardware rate for assistant playback.
                """
            )
        }

        if sessionRate > 0, abs(sessionRate - captureRate) <= 1 {
            return sessionRate
        }

        return captureRate
    }

    private func enableVoiceProcessing(on node: AVAudioIONode, label: String) {
        do {
            try node.setVoiceProcessingEnabled(true)
            AppLogger.audio.debug("Voice processing enabled on \(label, privacy: .public)")
        } catch {
            AppLogger.audio.warning(
                "Voice processing unavailable on \(label, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func logRuntimeEnvironment() {
        #if targetEnvironment(simulator)
        AppLogger.audio.warning("Hands-free capture running in iOS Simulator; microphone routing and voice processing can differ from device behavior")
        #else
        AppLogger.audio.debug("Hands-free capture running on physical device")
        #endif
    }

    private func logSessionState(_ session: AVAudioSession, stage: String) {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let availableInputs = session.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" } ?? []
        AppLogger.audio.debug(
            """
            Hands-free session[\(stage, privacy: .public)] category=\(session.category.rawValue, privacy: .public) \
            mode=\(session.mode.rawValue, privacy: .public) sampleRate=\(session.sampleRate, privacy: .public) \
            ioBuffer=\(session.ioBufferDuration, privacy: .public) preferredSampleRate=\(session.preferredSampleRate, privacy: .public) \
            preferredIOBuffer=\(session.preferredIOBufferDuration, privacy: .public) inputAvailable=\(session.isInputAvailable) \
            otherAudioPlaying=\(session.isOtherAudioPlaying) routeIn=\(inputs.joined(separator: ","), privacy: .public) \
            routeOut=\(outputs.joined(separator: ","), privacy: .public) availableInputs=\(availableInputs.joined(separator: ","), privacy: .public)
            """
        )
    }

    private func logEngineGraph(
        _ engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        outputNode: AVAudioOutputNode,
        playerNode: AVAudioPlayerNode?,
        sinkNode: AVAudioSinkNode?,
        stage: String
    ) {
        let playerConnections = playerNode.map { describeConnections(from: $0, in: engine, playerNode: playerNode, sinkNode: sinkNode) } ?? "none"
        let inputConnections = describeConnections(from: inputNode, in: engine, playerNode: playerNode, sinkNode: sinkNode)
        let mixerConnections = describeConnections(from: engine.mainMixerNode, in: engine, playerNode: playerNode, sinkNode: sinkNode)

        AppLogger.audio.debug(
            """
            Hands-free graph[\(stage, privacy: .public)] running=\(engine.isRunning) attachedNodes=\(engine.attachedNodes.count) \
            input.voiceProcessing=\(inputNode.isVoiceProcessingEnabled) output.voiceProcessing=\(outputNode.isVoiceProcessingEnabled) \
            input.input=\(self.describe(format: inputNode.inputFormat(forBus: 0)), privacy: .public) \
            input.output=\(self.describe(format: inputNode.outputFormat(forBus: 0)), privacy: .public) \
            output.input=\(self.describe(format: outputNode.inputFormat(forBus: 0)), privacy: .public) \
            mixer.output=\(self.describe(format: engine.mainMixerNode.outputFormat(forBus: 0)), privacy: .public) \
            player.output=\(playerNode.map { self.describe(format: $0.outputFormat(forBus: 0)) } ?? "none", privacy: .public) \
            sink.input=\(sinkNode.map { self.describe(format: $0.inputFormat(forBus: 0)) } ?? "none", privacy: .public) \
            input.connections=\(inputConnections, privacy: .public) player.connections=\(playerConnections, privacy: .public) \
            mixer.connections=\(mixerConnections, privacy: .public)
            """
        )
    }

    private func logCaptureIssue(_ message: String) {
        guard captureDiagnosticsRemaining > 0 else { return }
        captureDiagnosticsRemaining -= 1
        AppLogger.audio.warning("\(message, privacy: .public)")
    }

    private func scheduleCaptureWatchdog(startToken: Int) {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.runCaptureWatchdog(startToken: startToken)
        }
    }

    private func runCaptureWatchdog(startToken: Int) {
        guard isStreaming, captureStartToken == startToken else { return }
        guard let snapshot = captureRunState.snapshot(token: startToken) else { return }
        let firstCallbackMS = snapshot.firstCallbackAfterMilliseconds.map { String(format: "%.1f", $0) } ?? "none"
        AppLogger.audio.debug(
            "Hands-free capture watchdog callbacks=\(snapshot.callbackCount) frames=\(snapshot.totalFrames) firstCallbackMs=\(firstCallbackMS, privacy: .public) engineRunning=\(self.engine?.isRunning ?? false)"
        )
        let session = AVAudioSession.sharedInstance()
        logSessionState(session, stage: "watchdog")
        if let engine, let playerNode, let captureSinkNode {
            logEngineGraph(
                engine,
                inputNode: engine.inputNode,
                outputNode: engine.outputNode,
                playerNode: playerNode,
                sinkNode: captureSinkNode,
                stage: "watchdog"
            )
        }
        if snapshot.callbackCount == 0 {
            AppLogger.audio.error("Hands-free capture produced zero callbacks in the first second; the duplex graph is alive enough to start but not delivering mic frames")
        }
    }

    private func handleCapturedChunk(_ chunk: Data) {
        pendingPCM.append(chunk)
        flushIfNeeded()
    }

    private func handleCaptureStarted(snapshot: CaptureRunState.Snapshot, format: AVAudioFormat) {
        let latencyMs = snapshot.firstCallbackAfterMilliseconds.map { String(format: "%.1f", $0) } ?? "unknown"
        AppLogger.audio.debug(
            "Hands-free capture received first callback after \(latencyMs, privacy: .public) ms format=\(self.describe(format: format), privacy: .public)"
        )
    }

    private func makeCaptureSinkNode(format: AVAudioFormat, startToken: Int) -> AVAudioSinkNode {
        AVAudioSinkNode { [weak self] _, frameCount, audioBufferList in
            guard let self else { return noErr }
            guard let samples = Self.extractSamples(from: audioBufferList, frameCount: Int(frameCount), format: format) else {
                Task { @MainActor [weak self] in
                    self?.logCaptureIssue(
                        "Unsupported sink buffer format fmt=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved) ch=\(format.channelCount)"
                    )
                }
                return noErr
            }

            let resampled = Self.resample(samples: samples, from: format.sampleRate, to: Self.targetSampleRate)
            guard !resampled.isEmpty else { return noErr }

            let chunk = Self.encodePCM16(samples: resampled)
            let inputLevel = Self.computeAudioLevelDB(from: samples)
            guard let callback = self.captureRunState.recordCallback(token: startToken, frameCount: Int(frameCount)) else {
                return noErr
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if callback.isFirst {
                    self.handleCaptureStarted(snapshot: callback.snapshot, format: format)
                }
                self.onInputLevel?(inputLevel)
                self.handleCapturedChunk(chunk)
            }
            return noErr
        }
    }

    private func scheduleAssistantPlayback(
        _ drainResult: BufferedPCMPlaybackQueue.DrainResult,
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode,
        format: AVAudioFormat
    ) throws {
        if !engine.isRunning {
            try engine.start()
        }

        for chunk in drainResult.chunks {
            try scheduleAssistantChunk(
                chunk,
                playerNode: playerNode,
                format: format
            )
        }

        if drainResult.shouldStartPlayback && !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func scheduleAssistantChunk(
        _ chunk: Data,
        playerNode: AVAudioPlayerNode,
        format: AVAudioFormat
    ) throws {
        let bytesPerFrame = Self.bytesPerFrame(for: format)
        let frameCount = UInt32(chunk.count / bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "RemoteAudioCapture",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to schedule assistant playback buffer"]
            )
        }

        buffer.frameLength = frameCount
        chunk.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(channelData, baseAddress, chunk.count)
        }

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAssistantBufferPlaybackFinished()
            }
        }
    }

    private func handleAssistantBufferPlaybackFinished() async {
        guard let engine, let playerNode, let playbackFormat else { return }
        let bytesPerFrame = Self.bytesPerFrame(for: playbackFormat)
        guard bytesPerFrame > 0 else { return }

        let drainResult = assistantPlaybackQueue.didPlayBuffer(bytesPerFrame: bytesPerFrame)
        do {
            try scheduleAssistantPlayback(drainResult, engine: engine, playerNode: playerNode, format: playbackFormat)
        } catch {
            AppLogger.audio.error("Hands-free assistant playback drain failed: \(error.localizedDescription, privacy: .public)")
            await stopAssistantAudio()
        }
    }

    private func describeConnections(
        from node: AVAudioNode,
        in engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode?,
        sinkNode: AVAudioSinkNode?
    ) -> String {
        let points = engine.outputConnectionPoints(for: node, outputBus: 0)
        guard !points.isEmpty else { return "none" }
        return points.map { point in
            let label = point.node.map { self.nodeLabel($0, in: engine, playerNode: playerNode, sinkNode: sinkNode) } ?? "nil"
            return "\(label)@bus\(point.bus)"
        }.joined(separator: ",")
    }

    private func nodeLabel(
        _ node: AVAudioNode,
        in engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode?,
        sinkNode: AVAudioSinkNode?
    ) -> String {
        if node === engine.inputNode { return "input" }
        if node === engine.outputNode { return "output" }
        if node === engine.mainMixerNode { return "mainMixer" }
        if let playerNode, node === playerNode { return "player" }
        if let sinkNode, node === sinkNode { return "sink" }
        return String(describing: type(of: node))
    }

    private func describe(format: AVAudioFormat) -> String {
        "\(format.commonFormat.rawValue)@\(Int(format.sampleRate))Hz ch\(format.channelCount) interleaved=\(format.isInterleaved)"
    }

    private nonisolated static func extractSamples(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int,
        format: AVAudioFormat
    ) -> [Float]? {
        guard frameCount > 0 else { return [] }
        let firstBuffer = audioBufferList.pointee.mBuffers
        let channelCount = max(1, Int(format.channelCount))

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let baseAddress = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            if format.isInterleaved {
                let source = UnsafeBufferPointer<Float>(start: baseAddress, count: frameCount * channelCount)
                return stride(from: 0, to: source.count, by: channelCount).map { source[$0] }
            }
            return Array(UnsafeBufferPointer<Float>(start: baseAddress, count: frameCount))

        case .pcmFormatInt16:
            guard let baseAddress = firstBuffer.mData?.assumingMemoryBound(to: Int16.self) else { return nil }
            if format.isInterleaved {
                let source = UnsafeBufferPointer<Int16>(start: baseAddress, count: frameCount * channelCount)
                return stride(from: 0, to: source.count, by: channelCount).map {
                    Float(source[$0]) / Float(Int16.max)
                }
            }
            return UnsafeBufferPointer<Int16>(start: baseAddress, count: frameCount).map {
                Float($0) / Float(Int16.max)
            }

        case .pcmFormatInt32:
            guard let baseAddress = firstBuffer.mData?.assumingMemoryBound(to: Int32.self) else { return nil }
            if format.isInterleaved {
                let source = UnsafeBufferPointer<Int32>(start: baseAddress, count: frameCount * channelCount)
                return stride(from: 0, to: source.count, by: channelCount).map {
                    Float($0) / Float(Int32.max)
                }
            }
            return UnsafeBufferPointer<Int32>(start: baseAddress, count: frameCount).map {
                Float($0) / Float(Int32.max)
            }

        default:
            return nil
        }
    }

    private nonisolated static func encodePCM16(samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1.0, min(1.0, sample))
                baseAddress[index] = Int16(clamped * Float(Int16.max))
            }
        }
        return data
    }

    private nonisolated static func encodeFloat32(samples: [Float]) -> Data {
        var data = Data(count: samples.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            baseAddress.update(from: samples, count: samples.count)
        }
        return data
    }

    private nonisolated static func bytesPerFrame(for format: AVAudioFormat) -> Int {
        Int(format.streamDescription.pointee.mBytesPerFrame)
    }

    private nonisolated static func computeAudioLevelDB(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160.0 }
        let sumSquares = samples.reduce(0.0) { partial, sample in
            partial + (sample * sample)
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        guard rms > 0 else { return -160.0 }
        return max(-160.0, 20.0 * log10(rms))
    }

    private nonisolated static func resample(samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate > 0, sourceRate != targetRate else { return samples }
        let ratio = sourceRate / targetRate
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
