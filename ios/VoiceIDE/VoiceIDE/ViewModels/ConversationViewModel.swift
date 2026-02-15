import Foundation
import SwiftUI
import Combine

/// Central ViewModel owning all state. The single point of coordination.
/// UI emits intents -> ViewModel translates to tool calls -> ToolRouter executes.
@MainActor
final class ConversationViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messages: [ConversationMessage] = []
    @Published var appState: AppState = .idle
    @Published var partialTranscript: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var agentProgressCards: [AgentProgressCard] = []

    @AppStorage("recordingMode") var recordingMode: RecordingMode = .tapToToggle

    // MARK: - Event Bus (observable timeline)

    let eventBus = EventBus()

    // MARK: - Internal Components

    let conversationStore = ConversationStore()
    let appStateStore = AppStateStore()

    private var toolRegistry: ToolRegistry!
    private var toolRouter: ToolRouter!
    private var conductor: Conductor = LocalConductorStub()

    // Services (var to allow injection in test init)
    private var transcriber: SpeechTranscriber
    private var tts: TextToSpeech

    private var cancellables = Set<AnyCancellable>()
    private var pendingToolCalls: [String: Event.ToolCall] = [:]
    private var agentStatusPollingTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let elevenLabs = ElevenLabsTTS(
            voiceId: Config.elevenLabsVoiceId,
            modelId: Config.elevenLabsModelId
        )
        self.tts = elevenLabs
        self.transcriber = WhisperKitSpeechTranscriber()

        setupToolSystem()
        observeStores()
        preloadTranscriber()
        startSession()
    }

    /// Initializer for testing with injectable dependencies.
    init(conductor: Conductor, transcriber: SpeechTranscriber, tts: TextToSpeech) {
        self.conductor = conductor
        self.transcriber = transcriber
        self.tts = tts

        setupToolSystem(transcriber: transcriber, tts: tts)
        observeStores()
    }

    private func preloadTranscriber() {
        let transcriber = self.transcriber
        Task {
            await transcriber.preload()
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

        self.toolRegistry = registry
        self.toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
    }

    private func observeStores() {
        // Sync stores back to published properties whenever events are emitted
        eventBus.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.messages = self.conversationStore.messages
                self.appState = self.appStateStore.current
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

    private func startSession() {
        Task {
            let events = await conductor.handleSessionStart()
            await toolRouter.processEvents(events)
        }
    }

    // MARK: - User Intents (UI calls these)

    /// User tapped the mic button (tap-to-toggle mode).
    func micTapped() {
        Task {
            switch appState {
            case .idle, .error:
                await startListening()
            case .listening, .transcribing:
                await stopListeningAndProcess()
            case .speaking:
                // Barge-in: stop TTS, then start listening
                await bargeIn()
            case .thinking:
                break // Can't interrupt thinking
            }
        }
    }

    /// User pressed down (press-and-hold mode).
    func micPressed() {
        Task {
            if appState == .speaking {
                await bargeIn()
            } else {
                await startListening()
            }
        }
    }

    /// User released (press-and-hold mode).
    func micReleased() {
        Task {
            if appState == .listening || appState == .transcribing {
                await stopListeningAndProcess()
            }
        }
    }

    /// User submitted text from the input bar.
    func sendTypedMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            eventBus.emit(Event.transcriptFinal(trimmed))
            let conductorEvents = await conductor.handleTranscript(trimmed)
            await toolRouter.processEvents(conductorEvents)
        }
    }

    func refreshAgentStatus(cardID: UUID) {
        guard let card = agentProgressCards.first(where: { $0.id == cardID }),
              let agentID = card.agentId else { return }

        Task {
            await requestAgentStatus(agentID: agentID)
        }
    }

    func cancelAgent(cardID: UUID) {
        guard let card = agentProgressCards.first(where: { $0.id == cardID }),
              let agentID = card.agentId else { return }

        Task {
            let cancelEvent = Event.toolCall(
                name: AgentCancelTool.name,
                arguments: encode(AgentCancelTool.Arguments(id: agentID))
            )
            eventBus.emit(cancelEvent)
            if case .toolCall(let tc) = cancelEvent.kind {
                _ = await toolRouter.dispatch(tc)
            }
        }
    }

    // MARK: - Tool-Call–Based Actions

    /// Start listening via tool calls.
    private func startListening() async {
        partialTranscript = ""

        // Set state to listening
        let setStateEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "listening"))
        )
        eventBus.emit(setStateEvent)
        if case .toolCall(let tc) = setStateEvent.kind {
            await toolRouter.dispatch(tc)
        }

        // Start STT
        let sttEvent = Event.toolCall(
            name: "stt.start",
            arguments: encode(STTStartTool.Arguments(mode: recordingMode.rawValue))
        )
        eventBus.emit(sttEvent)
        if case .toolCall(let tc) = sttEvent.kind {
            let result = await toolRouter.dispatch(tc)
            // Check for errors
            if case .toolResult(let tr) = result.kind, tr.isError {
                await handleToolError(tr.error ?? "STT start failed")
            }
        }
    }

    /// Stop listening and send transcript to conductor.
    private func stopListeningAndProcess() async {
        // Set state to transcribing
        let setTranscribingEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "transcribing"))
        )
        eventBus.emit(setTranscribingEvent)
        if case .toolCall(let tc) = setTranscribingEvent.kind {
            await toolRouter.dispatch(tc)
        }

        // Stop STT and get final transcript
        let sttStopEvent = Event.toolCall(
            name: "stt.stop",
            arguments: encode(STTStopTool.Arguments())
        )
        eventBus.emit(sttStopEvent)

        var finalTranscript = partialTranscript
        if case .toolCall(let tc) = sttStopEvent.kind {
            let result = await toolRouter.dispatch(tc)
            if case .toolResult(let tr) = result.kind, let json = tr.result {
                if let decoded = try? JSONDecoder().decode(STTStopTool.Result.self, from: Data(json.utf8)) {
                    finalTranscript = decoded.finalTranscript
                }
            }
        }

        // Use partial if final is empty, but skip placeholder text
        if finalTranscript.isEmpty {
            let trimmed = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Don't use the "Listening…" placeholder as actual speech
            if trimmed != "Listening…" && !trimmed.isEmpty {
                finalTranscript = trimmed
            }
        }

        // Emit final transcript event
        eventBus.emit(Event.transcriptFinal(finalTranscript))

        // Send to conductor
        let conductorEvents = await conductor.handleTranscript(finalTranscript)
        await toolRouter.processEvents(conductorEvents)

        partialTranscript = ""
    }

    /// Barge-in: stop TTS then start listening.
    private func bargeIn() async {
        // 1. Stop TTS via tool call
        let ttsStopEvent = Event.toolCall(
            name: "tts.stop",
            arguments: encode(TTSStopTool.Arguments())
        )
        eventBus.emit(ttsStopEvent)
        if case .toolCall(let tc) = ttsStopEvent.kind {
            await toolRouter.dispatch(tc)
        }

        // 2. Start listening
        await startListening()
    }

    /// Handle partial transcript from STT.
    private func handlePartialTranscript(_ text: String) {
        partialTranscript = text
        eventBus.emit(Event.transcriptPartial(text))

        // Update state to transcribing if we're getting partials
        if appState == .listening {
            appStateStore.current = .transcribing
            appState = .transcribing
        }
    }

    /// Surface an error to the UI.
    private func handleToolError(_ message: String) async {
        let setErrorEvent = Event.toolCall(
            name: "convo.setState",
            arguments: encode(ConvoSetStateTool.Arguments(state: "error"))
        )
        eventBus.emit(setErrorEvent)
        if case .toolCall(let tc) = setErrorEvent.kind {
            await toolRouter.dispatch(tc)
        }

        eventBus.emit(Event.error(code: "tool_error", message: message))
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
    }

    private func handleAgentCancelResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        if toolResult.error != nil { return }
        guard let result = decode(AgentCancelTool.Result.self, from: toolResult.result) else { return }

        updateCard(agentID: result.id) { card in
            card.applyCancelled(agentID: result.id)
        }
        sortCardsByLastUpdate()
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
            arguments: encode(AgentStatusTool.Arguments(id: agentID))
        )
        eventBus.emit(statusEvent)
        if case .toolCall(let tc) = statusEvent.kind {
            _ = await toolRouter.dispatch(tc)
        }
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
}
