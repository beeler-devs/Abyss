import Foundation
import SwiftUI
import Combine

struct PairedBridgeDevice: Codable, Identifiable, Equatable {
    let deviceId: String
    let deviceName: String
    let status: String
    let lastSeen: String?

    var id: String { deviceId }
}

/// Central ViewModel owning all state. The single point of coordination.
/// UI emits intents -> ViewModel translates to tool calls -> ToolRouter executes.
@MainActor
final class ConversationViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messages: [ConversationMessage] = []
    @Published var appState: AppState = .idle
    @Published var partialTranscript: String = ""
    @Published var assistantPartialSpeech: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var agentProgressCards: [AgentProgressCard] = []
    @Published var pairedBridgeDevices: [PairedBridgeDevice] = []
    @Published var bridgePairingMessage: String?
    @Published var isMuted: Bool = false
    @Published private(set) var useServerConductor: Bool = false
    @Published private(set) var repositorySelectionManager = RepositorySelectionManager()
    @AppStorage("agentStatusWebhookUpdatesEnabled") private var agentStatusWebhookUpdatesEnabled: Bool = true
    @AppStorage("recordingMode") private var recordingModeRaw: String = RecordingMode.vadAuto.rawValue

    private var recordingMode: RecordingMode {
        RecordingMode(rawValue: recordingModeRaw) ?? .vadAuto
    }

    // MARK: - Event Bus (observable timeline)

    let eventBus = EventBus()

    // MARK: - Internal Components

    let conversationStore = ConversationStore()
    let appStateStore = AppStateStore()

    private var toolRegistry: ToolRegistry!
    private var toolRouter: ToolRouter!

    // Services (var to allow injection in test init)
    private var transcriber: SpeechTranscriber
    private var tts: TextToSpeech
    private let transcriptFormatter: FastTranscriptFormatter

    private let localConductor: Conductor
    private let sessionId: String
    private var activeConductorClient: ConductorClient?
    private var inboundEventsTask: Task<Void, Never>?
    private var isUsingServerClient = false

    private var cancellables = Set<AnyCancellable>()
    private var pendingToolCalls: [String: Event.ToolCall] = [:]
    private var agentStatusPollingTask: Task<Void, Never>?
    private var isStoppingRecording = false
    private var isStartingRecording = false
    private var isChatActive = false
    private var notifiedTerminalAgentIDs: Set<String> = []
    private var hasReceivedWebhookDrivenAgentStatus = false
    private var webhookDrivenAgentIDs: Set<String> = []
    private let voiceActivityDetector = VoiceActivityDetector(
        config: VoiceActivityDetector.Config(
            silenceThreshold: -37.0,
            speechThreshold: -35.0,
            silenceDuration: 0.9,
            minSpeechDuration: 0.25
        )
    )

    private static let useServerConductorKey = "useServerConductor"
    private static let pairedBridgeDevicesKey = "pairedBridgeDevices"

    // MARK: - Init

    init(sessionId: String = UUID().uuidString) {
        let defaults = UserDefaults.standard

        // When a backend URL is present in Secrets.plist the server conductor is always
        // preferred, regardless of any stale UserDefaults value (e.g. from a previous
        // failed-send fallback). UserDefaults is only consulted when no URL is configured.
        let resolvedUseServer: Bool
        if Config.isBackendWSConfigured {
            resolvedUseServer = true
        } else {
            resolvedUseServer = defaults.bool(forKey: Self.useServerConductorKey)
        }
        defaults.set(resolvedUseServer, forKey: Self.useServerConductorKey)
        self.useServerConductor = resolvedUseServer
        self.localConductor = LocalConductorStub()
        self.sessionId = sessionId

        let elevenLabs = ElevenLabsTTS(
            voiceId: Config.elevenLabsVoiceId,
            modelId: Config.elevenLabsModelId
        )
        self.tts = elevenLabs
        self.transcriber = WhisperKitSpeechTranscriber()
        self.transcriptFormatter = FastTranscriptFormatter()

        setupToolSystem()
        loadPairedBridgeDevices()
        refreshBridgeStatusesOnStartup()
        observeStores()
        configureVoicePipeline()
        preloadTranscriber()
        startSession()
    }

    /// Initializer for testing with injectable dependencies and local-conductor semantics.
    init(
        conductor: Conductor,
        transcriber: SpeechTranscriber,
        tts: TextToSpeech,
        transcriptFormatter: FastTranscriptFormatter = FastTranscriptFormatter()
    ) {
        self.useServerConductor = false
        self.localConductor = conductor
        self.sessionId = UUID().uuidString
        self.transcriber = transcriber
        self.tts = tts
        self.transcriptFormatter = transcriptFormatter

        setupToolSystem(transcriber: transcriber, tts: tts)
        loadPairedBridgeDevices()
        refreshBridgeStatusesOnStartup()
        observeStores()
        configureVoicePipeline()
    }

    /// Initializer for testing with an explicit conductor client.
    init(
        conductorClient: ConductorClient,
        transcriber: SpeechTranscriber,
        tts: TextToSpeech,
        transcriptFormatter: FastTranscriptFormatter = FastTranscriptFormatter(),
        sessionId: String = UUID().uuidString,
        autoStartSession: Bool = true
    ) {
        self.useServerConductor = false
        self.localConductor = LocalConductorStub()
        self.sessionId = sessionId
        self.activeConductorClient = conductorClient
        self.transcriber = transcriber
        self.tts = tts
        self.transcriptFormatter = transcriptFormatter

        setupToolSystem(transcriber: transcriber, tts: tts)
        loadPairedBridgeDevices()
        refreshBridgeStatusesOnStartup()
        observeStores()
        configureVoicePipeline()

        if autoStartSession {
            startSession(using: conductorClient)
        }
    }

    deinit {
        inboundEventsTask?.cancel()
        voiceActivityDetector.stopMonitoring()
        if let whisperTranscriber = transcriber as? WhisperKitSpeechTranscriber {
            whisperTranscriber.onAudioLevel = nil
        }
    }

    private func preloadTranscriber() {
        let transcriber = self.transcriber
        Task {
            await transcriber.preload()
        }
    }

    private func configureVoicePipeline() {
        voiceActivityDetector.onSpeechStarted = { [weak self] in
            guard let self else { return }
            guard self.canRunLiveConversation else { return }

            if self.appState == .idle || self.appState == .transcribing {
                self.appStateStore.current = .listening
                self.appState = .listening
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

    private func setupToolSystem(transcriber: SpeechTranscriber? = nil, tts: TextToSpeech? = nil) {
        let registry = ToolRegistry()
        let sttImpl = transcriber ?? self.transcriber
        let ttsImpl = tts ?? self.tts
        let cursorClient = CursorCloudAgentsClient()

        // Register audio tools
        registry.register(STTStartTool(transcriber: sttImpl, onPartial: { [weak self] partial in
            self?.handlePartialTranscript(partial)
        }))
        registry.register(STTStopTool(transcriber: sttImpl))
        registry.register(TTSSpeakTool(tts: ttsImpl))
        registry.register(TTSStopTool(tts: ttsImpl))

        // Register conversation tools
        registry.register(ConvoAppendMessageTool(store: conversationStore))
        registry.register(ConvoSetStateTool(stateStore: appStateStore))

        // Register Cursor Cloud Agent tools
        registry.register(AgentSpawnTool(client: cursorClient))
        registry.register(AgentStatusTool(client: cursorClient))
        registry.register(AgentCancelTool(client: cursorClient))
        registry.register(AgentFollowUpTool(client: cursorClient))
        registry.register(AgentListTool(client: cursorClient))
        registry.register(RepositoriesListTool(client: cursorClient))
        registry.register(RepositoriesSelectTool(client: cursorClient, selectionManager: repositorySelectionManager))

        self.toolRegistry = registry
        self.toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
    }

    private func observeStores() {
        // Sync conversation messages back to the published property whenever events are emitted.
        // NOTE: appState is NOT synced here — all state transitions set both appStateStore.current
        // and appState directly (in tandem) throughout the VM. Syncing appState from the store
        // via this sink causes a race: the sink fires on every eventBus emission (including
        // tool.result events during barge-in), potentially overwriting an optimistic .listening
        // state that was set synchronously before the async barge-in task ran.
        eventBus.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.messages = self.conversationStore.messages
            }
            .store(in: &cancellables)

        // Observe individual tool call/result events to maintain agent progress cards.
        eventBus.stream
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleEventStream(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Session

    private func startSession(using client: ConductorClient? = nil) {
        Task {
            if let client {
                await attachConductorClient(client)
            } else {
                await configureConductorClient(forceReconnect: true)
            }
        }
    }

    func setUseServerConductor(_ enabled: Bool) {
        let resolved = enabled && Config.isBackendWSConfigured
        guard useServerConductor != resolved else { return }

        useServerConductor = resolved
        UserDefaults.standard.set(resolved, forKey: Self.useServerConductorKey)

        Task {
            await configureConductorClient(forceReconnect: true)
        }
    }

    func requestBridgePairing(pairingCode: String, deviceName: String?) {
        let normalizedCode = pairingCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !normalizedCode.isEmpty else {
            bridgePairingMessage = "Enter a pairing code from AbyssBridge on Mac."
            return
        }

        bridgePairingMessage = "Sending pairing request…"
        let event = Event.bridgePairRequest(
            code: normalizedCode,
            deviceName: deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionId: sessionId
        )
        eventBus.emit(event)

        Task {
            await sendEventToConductor(event)
        }
    }

    private func configureConductorClient(forceReconnect: Bool) async {
        let shouldUseServer = useServerConductor && Config.isBackendWSConfigured
        if !forceReconnect, shouldUseServer == isUsingServerClient, activeConductorClient != nil {
            return
        }

        await disconnectConductorClient()

        if shouldUseServer, let backendURL = Config.backendWSURL {
            let wsClient = WebSocketConductorClient(backendURL: backendURL)
            do {
                isUsingServerClient = true
                try await connectConductorClient(wsClient)
                return
            } catch {
                eventBus.emit(Event.error(
                    code: "conductor_connect_failed",
                    message: "Could not connect to server conductor. Falling back to local conductor.",
                    sessionId: sessionId
                ))
                isUsingServerClient = false
            }
        }

        let localClient = LocalConductorClient(conductor: localConductor)
        do {
            try await connectConductorClient(localClient)
            activeConductorClient = localClient
        } catch {
            eventBus.emit(Event.error(
                code: "local_conductor_failed",
                message: "Failed to start local conductor: \(error.localizedDescription)",
                sessionId: sessionId
            ))
        }
    }

    private func attachConductorClient(_ client: ConductorClient) async {
        await disconnectConductorClient()
        do {
            try await connectConductorClient(client)
            activeConductorClient = client
        } catch {
            eventBus.emit(Event.error(
                code: "conductor_connect_failed",
                message: "Failed to attach conductor client: \(error.localizedDescription)",
                sessionId: sessionId
            ))
        }
    }

    private func connectConductorClient(_ client: ConductorClient) async throws {
        activeConductorClient = client
        let githubToken = GitHubAuthManager.loadToken()
        try await client.connect(sessionId: sessionId, githubToken: githubToken)

        inboundEventsTask?.cancel()
        inboundEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.inboundEvents {
                await self.handleInboundEvent(event)
            }
        }
    }

    private func disconnectConductorClient() async {
        inboundEventsTask?.cancel()
        inboundEventsTask = nil

        if let client = activeConductorClient {
            await client.disconnect()
        }
        activeConductorClient = nil
    }

    // MARK: - User Intents (UI calls these)

    func setChatActive(_ isActive: Bool) {
        guard isChatActive != isActive else { return }
        isChatActive = isActive
        Task { await refreshLiveConversationState() }
    }

    func toggleMute() {
        setMuted(!isMuted)
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
        Task {
            await bargeIn(reason: "button_interrupt")
        }
    }

    /// PTT: user pressed the mic button. Start recording immediately (bypasses VAD).
    /// If the assistant is currently speaking, barge in first (stops TTS), then start PTT.
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

    /// PTT: user released the mic button. Stop and process.
    /// Also handles fast tap: if startListeningPTT() is still in progress (isStartingRecording),
    /// we still schedule the stop so the mic doesn't stay open forever.
    func micReleased() {
        guard recordingMode == .pushToTalk else { return }
        guard !isStoppingRecording else { return }
        // Allow stop even if isListening is not yet true — startListeningPTT() is async and
        // may still be running. Since Tasks are serialised on MainActor, stopListeningAndProcess()
        // will execute after startListeningPTT() completes and its guard will pass.
        guard transcriber.isListening || isStartingRecording else { return }
        Task { await stopListeningAndProcess() }
    }

    /// User submitted text from the input bar.
    func sendTypedMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            let transcriptEvent = Event.transcriptFinal(trimmed, sessionId: sessionId)
            eventBus.emit(transcriptEvent)
            await sendEventToConductor(transcriptEvent)
        }
    }

    func refreshAgentStatus(cardID: UUID) {
        guard let card = agentProgressCards.first(where: { $0.id == cardID }),
              let agentID = card.agentId else { return }

        Task {
            await requestAgentStatus(agentID: agentID)
        }
    }

    func dismissAgentCard(cardID: UUID) {
        agentProgressCards.removeAll { $0.id == cardID }
    }

    func cancelAgent(cardID: UUID) {
        guard let card = agentProgressCards.first(where: { $0.id == cardID }),
              let agentID = card.agentId else { return }

        Task {
            let cancelEvent = Event.toolCall(
                name: AgentCancelTool.name,
                arguments: encode(AgentCancelTool.Arguments(id: agentID)),
                sessionId: sessionId
            )
            eventBus.emit(cancelEvent)
            if case .toolCall(let tc) = cancelEvent.kind {
                _ = await toolRouter.dispatch(tc)
            }
        }
    }

    // MARK: - Repository Selection

    func selectRepository(_ repository: RepositorySelectionCard.Repository) {
        repositorySelectionManager.completeSelection(repository: repository)
    }

    func cancelRepositorySelection() {
        repositorySelectionManager.cancelSelection()
    }

    // MARK: - Tool-Call–Based Actions

    private var canRunLiveConversation: Bool {
        isChatActive && !isMuted
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
            appStateStore.current = .idle
            appState = .idle
        }
    }

    private func handleMuteActivated() async {
        voiceActivityDetector.stopMonitoring()

        if transcriber.isListening && !isStoppingRecording {
            await stopListeningAndProcess()
            return
        }

        if appState == .listening || appState == .transcribing || appState == .idle {
            appStateStore.current = .idle
            appState = .idle
        }
    }

    /// Start listening via tool calls. PTT mode manages its own mic lifecycle via micPressed/micReleased.
    private func startListening() async {
        guard recordingMode == .vadAuto else { return }
        guard canRunLiveConversation else { return }
        guard !isStoppingRecording else { return }
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        partialTranscript = ""
        assistantPartialSpeech = ""
        appStateStore.current = .listening
        appState = .listening

        // Always assert the listening state, even if the transcriber is already running.
        // Without this, a stale convo.setState(idle) arriving from the conductor after a
        // barge-in can wipe out the .listening state we set optimistically, because
        // startListening() would have returned early before re-asserting it.
        let setStateEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "listening")),
            sessionId: sessionId
        )
        eventBus.emit(setStateEvent)
        if case .toolCall(let tc) = setStateEvent.kind {
            await toolRouter.dispatch(tc)
        }

        if transcriber.isListening {
            if recordingMode == .vadAuto && !voiceActivityDetector.isMonitoring {
                voiceActivityDetector.startMonitoring()
            }
            return
        }

        // Start STT
        let sttEvent = Event.toolCall(
            name: "stt.start",
            arguments: encode(STTStartTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttEvent)
        if case .toolCall(let tc) = sttEvent.kind {
            let result = await toolRouter.dispatch(tc)
            // Check for errors
            if case .toolResult(let tr) = result.kind, tr.isError {
                await handleToolError(tr.error ?? "STT start failed")
                return
            }
        }

        if recordingMode == .vadAuto && !voiceActivityDetector.isMonitoring {
            voiceActivityDetector.startMonitoring()
        }
    }

    /// Start listening for PTT mode — bypasses mute/canRunLiveConversation, never starts VAD.
    private func startListeningPTT() async {
        guard !isStoppingRecording else { return }
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        partialTranscript = ""
        assistantPartialSpeech = ""
        appStateStore.current = .listening
        appState = .listening

        let setStateEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "listening")),
            sessionId: sessionId
        )
        eventBus.emit(setStateEvent)
        if case .toolCall(let tc) = setStateEvent.kind {
            await toolRouter.dispatch(tc)
        }

        guard !transcriber.isListening else { return }

        let sttEvent = Event.toolCall(
            name: "stt.start",
            arguments: encode(STTStartTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttEvent)
        if case .toolCall(let tc) = sttEvent.kind {
            let result = await toolRouter.dispatch(tc)
            if case .toolResult(let tr) = result.kind, tr.isError {
                await handleToolError(tr.error ?? "STT start failed")
            }
        }
        // VAD is intentionally NOT started in PTT mode
    }

    private func stopListeningSilently() async {
        guard transcriber.isListening else { return }

        isStoppingRecording = true
        defer { isStoppingRecording = false }

        let sttStopEvent = Event.toolCall(
            name: "stt.stop",
            arguments: encode(STTStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttStopEvent)
        if case .toolCall(let tc) = sttStopEvent.kind {
            _ = await toolRouter.dispatch(tc)
        }
        partialTranscript = ""
    }

    /// Stop listening and send transcript to conductor.
    private func stopListeningAndProcess() async {
        guard transcriber.isListening else { return }
        print("⏹️ [STEP 2] stopListeningAndProcess() ENTER — appState=\(appState.rawValue)")
        isStoppingRecording = true
        defer {
            print("⏹️ [STEP 2-EXIT] stopListeningAndProcess() EXIT — resetting isStoppingRecording")
            isStoppingRecording = false
        }
        voiceActivityDetector.stopMonitoring()
        appStateStore.current = .transcribing
        appState = .transcribing

        // Set state to transcribing
        let setTranscribingEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "transcribing")),
            sessionId: sessionId
        )
        eventBus.emit(setTranscribingEvent)
        if case .toolCall(let tc) = setTranscribingEvent.kind {
            await toolRouter.dispatch(tc)
        }
        print("⏹️ [STEP 3] setState(transcribing) dispatched — appState now=\(appState.rawValue)")

        // Stop STT and get final transcript
        let sttStopEvent = Event.toolCall(
            name: "stt.stop",
            arguments: encode(STTStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(sttStopEvent)

        print("⏹️ [STEP 4] stt.stop dispatched — WAITING for WhisperKit final transcription...")
        var finalTranscript = partialTranscript
        if case .toolCall(let tc) = sttStopEvent.kind {
            let result = await toolRouter.dispatch(tc)
            if case .toolResult(let tr) = result.kind {
                if tr.isError {
                    print("⏹️ [STEP 4-ERR] stt.stop returned an error: \(tr.error ?? "unknown")")
                } else if let json = tr.result,
                          let decoded = try? JSONDecoder().decode(STTStopTool.Result.self, from: Data(json.utf8)) {
                    finalTranscript = decoded.finalTranscript
                } else {
                    print("⏹️ [STEP 4-WARN] stt.stop result could not be decoded — json=\(tr.result ?? "nil")")
                }
            } else {
                print("⏹️ [STEP 4-WARN] stt.stop returned unexpected event kind")
            }
        }
        print("⏹️ [STEP 5] stt.stop returned — finalTranscript='\(finalTranscript)'")

        // Treat placeholder returns from the transcriber (e.g. "[No audio captured]") as empty
        // so they don't get forwarded to the conductor as real utterances.
        if isPlaceholderTranscript(finalTranscript) {
            print("⏹️ [STEP 5-PLACEHOLDER] final transcript is a placeholder — treating as empty")
            finalTranscript = ""
        }

        // Use partial if final is empty, but skip placeholder text
        if finalTranscript.isEmpty {
            let trimmed = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isPlaceholderTranscript(trimmed) && !trimmed.isEmpty {
                finalTranscript = trimmed
                print("⏹️ [STEP 5a] empty final — fell back to partial: '\(finalTranscript)'")
            } else {
                print("⏹️ [STEP 5b] both final and partial are empty/placeholder — resetting to idle without sending")
            }
        }

        let normalizedTranscript = transcriptFormatter.normalizeForAgent(finalTranscript)

        // Don't send an empty transcript to the conductor — it will reject it and the
        // conversation never advances. Instead, quietly reset back to idle.
        guard !normalizedTranscript.isEmpty else {
            print("⏹️ [STEP 6-SKIP] normalized transcript is empty — skipping send, resetting to idle")
            let resetEvent = Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "idle")),
                sessionId: sessionId
            )
            eventBus.emit(resetEvent)
            if case .toolCall(let tc) = resetEvent.kind {
                await toolRouter.dispatch(tc)
            }
            appStateStore.current = .idle
            appState = .idle
            partialTranscript = ""
            await refreshLiveConversationState()
            return
        }

        print("⏹️ [STEP 6] sending to conductor — normalizedTranscript='\(normalizedTranscript)'")

        // Emit normalized transcript and send to conductor.
        let transcriptEvent = Event.transcriptFinal(normalizedTranscript, sessionId: sessionId)
        eventBus.emit(transcriptEvent)
        await sendEventToConductor(transcriptEvent)
        print("⏹️ [STEP 7] sendEventToConductor returned — conversation turn complete")

        partialTranscript = ""
    }

    /// Barge-in: stop TTS then start listening.
    private func bargeIn(reason: String = "barge_in") async {
        voiceActivityDetector.stopMonitoring()

        // 1. Stop TTS via tool call
        let ttsStopEvent = Event.toolCall(
            name: "tts.stop",
            arguments: encode(TTSStopTool.Arguments()),
            sessionId: sessionId
        )
        eventBus.emit(ttsStopEvent)
        if case .toolCall(let tc) = ttsStopEvent.kind {
            await toolRouter.dispatch(tc)
        }

        // 2. Notify server best-effort (non-blocking)
        let interruptedEvent = Event.audioOutputInterrupted(reason, sessionId: sessionId)
        eventBus.emit(interruptedEvent)
        Task {
            await sendEventToConductor(interruptedEvent, surfaceErrors: false)
        }

        // 3. Start listening immediately
        await refreshLiveConversationState()
    }

    /// Handle partial transcript from STT.
    private func handlePartialTranscript(_ text: String) {
        if isPlaceholderTranscript(text) {
            return
        }
        partialTranscript = text
        eventBus.emit(Event.transcriptPartial(text, sessionId: sessionId))

        // Update state to transcribing if we're getting partials
        if appState == .listening {
            appStateStore.current = .transcribing
            appState = .transcribing
        }
    }

    private func sendEventToConductor(_ event: Event, surfaceErrors: Bool = true) async {
        let clientType = activeConductorClient.map { "\(type(of: $0))" } ?? "nil"
        print("📡 [SEND-1] sendEventToConductor — client=\(clientType), eventKind=\(event.kind.displayName)")
        guard let client = activeConductorClient else {
            print("📡 [SEND-ERR] activeConductorClient is nil — bailing")
            if surfaceErrors {
                eventBus.emit(Event.error(
                    code: "conductor_missing",
                    message: "Conductor client is not available.",
                    sessionId: sessionId
                ))
            }
            return
        }

        print("📡 [SEND-2] calling client.send()...")
        do {
            try await client.send(event: event)
            print("📡 [SEND-3] client.send() returned OK")
        } catch {
            print("📡 [SEND-ERR] client.send() threw: \(error.localizedDescription)")

            // When the server conductor fails (e.g. server unreachable or WebSocket timeout),
            // automatically fall back to the local conductor so the conversation can continue
            // instead of hanging indefinitely.
            if isUsingServerClient {
                print("📡 [SEND-FALLBACK] server conductor failed — switching to local conductor and retrying")
                isUsingServerClient = false
                useServerConductor = false
                // Do NOT persist false to UserDefaults here — next launch should re-evaluate
                // from Secrets.plist (so adding a working URL will auto-reconnect).

                let localClient = LocalConductorClient(conductor: localConductor)
                do {
                    try await connectConductorClient(localClient)
                    try await localClient.send(event: event)
                    print("📡 [SEND-FALLBACK] local conductor send OK")
                } catch {
                    print("📡 [SEND-FALLBACK-ERR] local conductor send also failed: \(error.localizedDescription)")
                    if surfaceErrors {
                        eventBus.emit(Event.error(
                            code: "conductor_send_failed",
                            message: "Conductor unavailable: \(error.localizedDescription)",
                            sessionId: sessionId
                        ))
                    }
                }
            } else if surfaceErrors {
                eventBus.emit(Event.error(
                    code: "conductor_send_failed",
                    message: "Failed to send event to conductor: \(error.localizedDescription)",
                    sessionId: sessionId
                ))
            }
        }
    }

    private func handleInboundEvent(_ event: Event) async {
        print("📥 [INBOUND] handleInboundEvent — \(event.kind.displayName)")
        switch event.kind {
        case .assistantSpeechPartial(let partial):
            guard assistantPartialSpeech != partial.text else { return }
            assistantPartialSpeech = partial.text
            eventBus.emit(event)

        case .assistantSpeechFinal:
            assistantPartialSpeech = ""
            eventBus.emit(event)

        case .toolCall(let toolCall):
            eventBus.emit(event)
            if toolCall.name.hasPrefix("bridge.") {
                return
            }
            print("📥 [INBOUND] dispatching tool '\(toolCall.name)'...")
            let toolResultEvent = await toolRouter.dispatch(toolCall)
            print("📥 [INBOUND] tool '\(toolCall.name)' done — sending result back")
            await sendEventToConductor(toolResultEvent)
            print("📥 [INBOUND] tool '\(toolCall.name)' result sent")

            if toolCall.name == ConvoSetStateTool.name {
                let requestedState = appStateStore.current
                let effectiveState: AppState
                if isMuted && (requestedState == .listening || requestedState == .transcribing) {
                    effectiveState = .idle
                } else {
                    effectiveState = requestedState
                }

                // PTT: don't let any inbound server state overwrite the active recording visual
                // while the user is holding. Two issues with the old condition:
                //   1. transcriber.isListening is false during the stt.start startup window
                //      (isStartingRecording is the right signal for that gap).
                //   2. Only blocking .idle/.speaking missed .thinking, which the server sends
                //      immediately after an interrupt — causing the button to go dark on barge-in.
                // Whitelist: allow .listening/.transcribing through; block everything else.
                let preservePTTRecording = recordingMode == .pushToTalk
                    && (transcriber.isListening || isStartingRecording)
                    && (appState == .listening || appState == .transcribing)
                    && effectiveState != .listening
                    && effectiveState != .transcribing

                if !preservePTTRecording {
                    appStateStore.current = effectiveState
                    appState = effectiveState

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
            }

        case .bridgePairPending(let pending):
            bridgePairingMessage = "Pairing code \(pending.pairingCode) accepted."
            eventBus.emit(event)
        case .bridgePaired(let paired):
            bridgePairingMessage = "Paired with \(paired.deviceName)."
            upsertPairedBridgeDevice(
                deviceId: paired.deviceId,
                deviceName: paired.deviceName,
                status: paired.status,
                lastSeen: nil
            )
            eventBus.emit(event)
        case .bridgeStatus(let status):
            if let index = pairedBridgeDevices.firstIndex(where: { $0.deviceId == status.deviceId }) {
                let existing = pairedBridgeDevices[index]
                pairedBridgeDevices[index] = PairedBridgeDevice(
                    deviceId: existing.deviceId,
                    deviceName: existing.deviceName,
                    status: status.status,
                    lastSeen: status.lastSeen
                )
                persistPairedBridgeDevices()
            } else {
                upsertPairedBridgeDevice(
                    deviceId: status.deviceId,
                    deviceName: status.deviceId,
                    status: status.status,
                    lastSeen: status.lastSeen
                )
            }
            eventBus.emit(event)
        case .assistantUIPatch, .agentStatus, .agentConversation, .sessionStart, .toolResult, .error,
                .userAudioTranscriptPartial, .userAudioTranscriptFinal, .audioOutputInterrupted,
                .agentCompleted, .bridgePairRequest:
            eventBus.emit(event)
        }
        print("📥 [INBOUND] handleInboundEvent DONE — \(event.kind.displayName)")
    }

    /// Surface an error to the UI.
    private func handleToolError(_ message: String) async {
        voiceActivityDetector.stopMonitoring()
        appStateStore.current = .error
        appState = .error

        let setErrorEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "error")),
            sessionId: sessionId
        )
        eventBus.emit(setErrorEvent)
        if case .toolCall(let tc) = setErrorEvent.kind {
            await toolRouter.dispatch(tc)
        }

        eventBus.emit(Event.error(code: "tool_error", message: message, sessionId: sessionId))
        errorMessage = message
        showError = true
    }

    // MARK: - Agent Progress Cards

    private func handleEventStream(_ event: Event) {
        switch event.kind {
        case .toolCall(let toolCall):
            pendingToolCalls[toolCall.callId] = toolCall
            if toolCall.name == AgentSpawnTool.name {
                registerPendingAgentCard(from: toolCall)
            }
        case .toolResult(let toolResult):
            guard let toolCall = pendingToolCalls.removeValue(forKey: toolResult.callId) else {
                return
            }
            handleToolResult(toolResult, for: toolCall)
        case .agentStatus(let status):
            handleAgentStatusEvent(status)
        case .agentConversation(let conversation):
            handleAgentConversationEvent(conversation)
        default:
            break
        }
    }

    private func registerPendingAgentCard(from toolCall: Event.ToolCall) {
        guard let args = decode(AgentSpawnTool.Arguments.self, from: toolCall.arguments) else { return }
        guard !agentProgressCards.contains(where: { $0.spawnCallId == toolCall.callId }) else { return }

        let card = AgentProgressCard.pending(
            spawnCallId: toolCall.callId,
            prompt: args.prompt,
            repository: args.repository,
            autoCreatePR: args.autoCreatePr ?? false
        )

        agentProgressCards.insert(card, at: 0)
    }

    private func handleToolResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        switch toolCall.name {
        case AgentSpawnTool.name:
            handleAgentSpawnResult(toolResult, for: toolCall)
        case AgentStatusTool.name:
            handleAgentStatusResult(toolResult, for: toolCall)
        case AgentCancelTool.name:
            handleAgentCancelResult(toolResult, for: toolCall)
        default:
            break
        }
    }

    private func handleAgentSpawnResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        if let error = toolResult.error {
            updateCard(spawnCallId: toolCall.callId) { card in
                card.applySpawnError(error)
            }
            sortCardsByLastUpdate()
            return
        }

        guard let result = decode(AgentSpawnTool.Result.self, from: toolResult.result) else { return }

        if updateCard(spawnCallId: toolCall.callId, mutate: { card in
            card.applySpawnResult(result)
        }) == false {
            var fallbackCard = AgentProgressCard.pending(
                spawnCallId: toolCall.callId,
                prompt: "Cursor agent task",
                repository: nil,
                autoCreatePR: false
            )
            fallbackCard.applySpawnResult(result)
            agentProgressCards.insert(fallbackCard, at: 0)
        }

        sortCardsByLastUpdate()
        if result.status.uppercased() != "FINISHED" {
            ensureAgentStatusPolling()
        }
        if let card = agentProgressCards.first(where: { $0.agentId == result.id }) {
            notifyAgentCompletionIfNeeded(card: card)
        }
    }

    private func handleAgentStatusResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        guard let args = decode(AgentStatusTool.Arguments.self, from: toolCall.arguments) else { return }

        if let error = toolResult.error {
            updateCard(agentID: args.id) { card in
                card.noteStatusRefreshError(error)
            }
            sortCardsByLastUpdate()
            return
        }

        guard let result = decode(AgentStatusTool.Result.self, from: toolResult.result) else { return }

        if updateCard(agentID: result.id, mutate: { card in
            card.applyStatusResult(result)
        }) == false {
            var fallbackCard = AgentProgressCard.pending(
                spawnCallId: toolCall.callId,
                prompt: result.name ?? "Cursor agent task",
                repository: nil,
                autoCreatePR: false
            )
            fallbackCard.applyStatusResult(result)
            agentProgressCards.insert(fallbackCard, at: 0)
        }

        sortCardsByLastUpdate()
        if !agentProgressCards.filter({ !$0.isTerminal && $0.agentId != nil }).isEmpty {
            ensureAgentStatusPolling()
        }
        if let card = agentProgressCards.first(where: { $0.agentId == result.id }) {
            notifyAgentCompletionIfNeeded(card: card)
        }
    }

    private func handleAgentCancelResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        if toolResult.error != nil { return }
        guard let result = decode(AgentCancelTool.Result.self, from: toolResult.result) else { return }

        updateCard(agentID: result.id) { card in
            card.applyCancelled(agentID: result.id)
        }
        sortCardsByLastUpdate()
    }

    private func notifyAgentCompletionIfNeeded(card: AgentProgressCard) {
        let status = card.normalizedStatus
        guard status == "FINISHED" || status == "FAILED" else { return }
        guard let agentId = card.agentId else { return }
        guard !notifiedTerminalAgentIDs.contains(agentId) else { return }
        notifiedTerminalAgentIDs.insert(agentId)
        if isUsingServerClient && webhookDrivenAgentIDs.contains(agentId) {
            return
        }
        let event = Event.agentCompleted(
            agentId: agentId,
            status: status,
            summary: card.summary.isEmpty ? "No summary available." : card.summary,
            name: card.title.isEmpty ? nil : card.title,
            prompt: card.prompt.isEmpty ? nil : card.prompt,
            sessionId: sessionId
        )
        Task { await sendEventToConductor(event) }
    }

    @discardableResult
    private func updateCard(spawnCallId: String, mutate: (inout AgentProgressCard) -> Void) -> Bool {
        guard let index = agentProgressCards.firstIndex(where: { $0.spawnCallId == spawnCallId }) else {
            return false
        }
        mutate(&agentProgressCards[index])
        return true
    }

    @discardableResult
    private func updateCard(agentID: String, mutate: (inout AgentProgressCard) -> Void) -> Bool {
        guard let index = agentProgressCards.firstIndex(where: { $0.agentId == agentID }) else {
            return false
        }
        mutate(&agentProgressCards[index])
        return true
    }

    private func sortCardsByLastUpdate() {
        agentProgressCards.sort { $0.updatedAt > $1.updatedAt }
    }

    private func ensureAgentStatusPolling() {
        guard shouldAutoPollAgentStatus() else { return }
        guard agentStatusPollingTask == nil else { return }

        agentStatusPollingTask = Task { [weak self] in
            await self?.pollAgentStatuses()
        }
    }

    private func pollAgentStatuses() async {
        defer { agentStatusPollingTask = nil }

        while !Task.isCancelled {
            let activeAgentIDs: [String] = agentProgressCards.compactMap { card in
                guard let agentID = card.agentId, !card.isTerminal else { return nil }
                return agentID
            }

            guard !activeAgentIDs.isEmpty else {
                break
            }

            for agentID in activeAgentIDs {
                if Task.isCancelled { return }
                await requestAgentStatus(agentID: agentID)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }

    private func requestAgentStatus(agentID: String) async {
        let statusEvent = Event.toolCall(
            name: AgentStatusTool.name,
            arguments: encode(AgentStatusTool.Arguments(id: agentID)),
            sessionId: sessionId
        )
        eventBus.emit(statusEvent)
        if case .toolCall(let tc) = statusEvent.kind {
            _ = await toolRouter.dispatch(tc)
        }
    }

    private func handleAgentStatusEvent(_ status: Event.AgentStatus) {
        guard let agentID = status.agentId, !agentID.isEmpty else { return }

        if status.webhookDriven == true && agentStatusWebhookUpdatesEnabled {
            hasReceivedWebhookDrivenAgentStatus = true
            webhookDrivenAgentIDs.insert(agentID)
            agentStatusPollingTask?.cancel()
            agentStatusPollingTask = nil
        }

        if updateCard(agentID: agentID, mutate: { card in
            card.applyAgentStatusEvent(status)
        }) == false {
            var fallbackCard = AgentProgressCard.pending(
                spawnCallId: "server-\(agentID)",
                prompt: status.summary ?? status.detail ?? "Cursor agent task",
                repository: nil,
                autoCreatePR: false
            )
            fallbackCard.applyAgentStatusEvent(status)
            agentProgressCards.insert(fallbackCard, at: 0)
        }

        sortCardsByLastUpdate()
        if shouldAutoPollAgentStatus(),
           !agentProgressCards.filter({ !$0.isTerminal && $0.agentId != nil }).isEmpty {
            ensureAgentStatusPolling()
        }

        if let card = agentProgressCards.first(where: { $0.agentId == agentID }) {
            notifyAgentCompletionIfNeeded(card: card)
        }
    }

    private func handleAgentConversationEvent(_ conversation: Event.AgentConversation) {
        guard !conversation.agentId.isEmpty else { return }
        if updateCard(agentID: conversation.agentId, mutate: { card in
            card.appendConversationMessages(conversation.messages)
        }) {
            sortCardsByLastUpdate()
        }
    }

    func toggleConversationExpanded(cardID: UUID) {
        guard let index = agentProgressCards.firstIndex(where: { $0.id == cardID }) else { return }
        agentProgressCards[index].isConversationExpanded.toggle()
    }

    private func shouldAutoPollAgentStatus() -> Bool {
        if agentStatusWebhookUpdatesEnabled && hasReceivedWebhookDrivenAgentStatus {
            return false
        }
        return true
    }

    private func loadPairedBridgeDevices() {
        guard let data = UserDefaults.standard.data(forKey: Self.pairedBridgeDevicesKey) else {
            pairedBridgeDevices = []
            return
        }

        if let decoded = try? JSONDecoder().decode([PairedBridgeDevice].self, from: data) {
            pairedBridgeDevices = decoded
        } else {
            pairedBridgeDevices = []
        }
    }

    /// Always invalidate cached "online" statuses at app startup.
    /// Fresh server bridge.status events will restore accurate status.
    private func refreshBridgeStatusesOnStartup() {
        guard !pairedBridgeDevices.isEmpty else {
            return
        }

        let refreshed = pairedBridgeDevices.map { device in
            PairedBridgeDevice(
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                status: "offline",
                lastSeen: device.lastSeen
            )
        }

        guard refreshed != pairedBridgeDevices else {
            return
        }

        pairedBridgeDevices = refreshed
        persistPairedBridgeDevices()
    }

    private func persistPairedBridgeDevices() {
        guard let data = try? JSONEncoder().encode(pairedBridgeDevices) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.pairedBridgeDevicesKey)
    }

    private func upsertPairedBridgeDevice(
        deviceId: String,
        deviceName: String,
        status: String,
        lastSeen: String?
    ) {
        let updated = PairedBridgeDevice(
            deviceId: deviceId,
            deviceName: deviceName,
            status: status,
            lastSeen: lastSeen
        )

        if let index = pairedBridgeDevices.firstIndex(where: { $0.deviceId == deviceId }) {
            pairedBridgeDevices[index] = updated
        } else {
            pairedBridgeDevices.insert(updated, at: 0)
        }
        persistPairedBridgeDevices()
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
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

/// Extremely lightweight transcript cleanup for better downstream agent parsing.
struct FastTranscriptFormatter: Sendable {
    func normalizeForAgent(_ transcript: String) -> String {
        var text = normalizeWhitespace(in: transcript)
        guard !text.isEmpty else { return "" }

        text = removeLeadingFillers(from: text)
        text = normalizeSpokenGithubURL(text)
        text = normalizePronounI(in: text)
        text = capitalizeFirstCharacter(in: text)

        if !hasTerminalPunctuation(text) {
            text.append(".")
        }

        return text
    }

    private func normalizeWhitespace(in text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeLeadingFillers(from text: String) -> String {
        let pattern = #"^(?:(?:um+|uh+|ah+|er+|like|you know|i mean)\s+)+"#
        return replacingRegex(pattern, with: "", in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeSpokenGithubURL(_ text: String) -> String {
        replacingRegex(#"github\s+dot\s+com"#, with: "github.com", in: text, caseInsensitive: true)
    }

    private func normalizePronounI(in text: String) -> String {
        replacingRegex(#"\bi\b"#, with: "I", in: text)
    }

    private func capitalizeFirstCharacter(in text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return [".", "!", "?"].contains(String(last))
    }

    private func replacingRegex(
        _ pattern: String,
        with replacement: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
