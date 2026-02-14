import Foundation
import SwiftUI
import Combine

/// Central ViewModel owning all state. The single point of coordination.
/// UI emits intents -> ViewModel translates to tool calls -> ToolRouter executes.
///
/// Phase 2: When Config.useCloudConductor is true, uses WebSocketConductorClient
/// instead of LocalConductorStub. Inbound events from the server are dispatched
/// through the same ToolRouter, preserving the same event/tool protocol.
@MainActor
final class ConversationViewModel: ObservableObject {
    // MARK: - Published State

    @Published var messages: [ConversationMessage] = []
    @Published var appState: AppState = .idle
    @Published var partialTranscript: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    @AppStorage("recordingMode") var recordingMode: RecordingMode = .tapToToggle

    // MARK: - Event Bus (observable timeline)

    let eventBus = EventBus()

    // MARK: - Internal Components

    let conversationStore = ConversationStore()
    let appStateStore = AppStateStore()

    private var toolRegistry: ToolRegistry!
    private var toolRouter: ToolRouter!

    // Phase 1: batch-mode conductor (LocalConductorStub)
    private var conductor: Conductor = LocalConductorStub()

    // Phase 2: streaming conductor (WebSocketConductorClient)
    private var conductorClient: ConductorClient?
    private var useCloudConductor: Bool = false
    private var sessionId: String = UUID().uuidString
    private var inboundEventTask: Task<Void, Never>?

    // Services (var to allow injection in test init)
    private var transcriber: SpeechTranscriber
    private var tts: TextToSpeech

    private var cancellables = Set<AnyCancellable>()

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

        // Decide conductor mode
        if Config.useCloudConductor && Config.isBackendConfigured {
            useCloudConductor = true
            let client = WebSocketConductorClient()
            self.conductorClient = client
            startCloudSession(client: client)
        } else {
            useCloudConductor = false
            startSession()
        }
    }

    /// Initializer for testing with injectable dependencies (Phase 1 mode).
    init(conductor: Conductor, transcriber: SpeechTranscriber, tts: TextToSpeech) {
        self.conductor = conductor
        self.transcriber = transcriber
        self.tts = tts
        self.useCloudConductor = false

        setupToolSystem(transcriber: transcriber, tts: tts)
        observeStores()
    }

    /// Initializer for testing with a ConductorClient (Phase 2 mode).
    init(conductorClient: ConductorClient, transcriber: SpeechTranscriber, tts: TextToSpeech) {
        self.conductorClient = conductorClient
        self.transcriber = transcriber
        self.tts = tts
        self.useCloudConductor = true

        setupToolSystem(transcriber: transcriber, tts: tts)
        observeStores()
    }

    deinit {
        inboundEventTask?.cancel()
    }

    private func setupToolSystem(transcriber: SpeechTranscriber? = nil, tts: TextToSpeech? = nil) {
        let registry = ToolRegistry()
        let sttImpl = transcriber ?? self.transcriber
        let ttsImpl = tts ?? self.tts

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
    }

    // MARK: - Session (Phase 1)

    private func startSession() {
        Task {
            let events = await conductor.handleSessionStart()
            await toolRouter.processEvents(events)
        }
    }

    // MARK: - Session (Phase 2: Cloud Conductor)

    private func startCloudSession(client: ConductorClient) {
        Task {
            do {
                try await client.connect(sessionId: sessionId)

                // Send session.start event
                let sessionEvent = Event.sessionStart(sessionId: sessionId)
                eventBus.emit(sessionEvent)
                try await client.send(event: sessionEvent)

                // Start listening for inbound events from the server
                startInboundEventLoop(client: client)
            } catch {
                eventBus.emit(Event.error(code: "ws_connect_failed", message: error.localizedDescription))
                // Fall back to local conductor
                useCloudConductor = false
                startSession()
            }
        }
    }

    private func startInboundEventLoop(client: ConductorClient) {
        inboundEventTask = Task { [weak self] in
            for await event in client.inboundEvents {
                guard let self, !Task.isCancelled else { break }
                await self.handleInboundEvent(event)
            }
        }
    }

    /// Handle an event received from the cloud conductor.
    /// Internal (not private) so tests can call it directly.
    func handleInboundEvent(_ event: Event) async {
        switch event.kind {
        case .toolCall(let tc):
            // Server requests tool execution — dispatch via ToolRouter
            eventBus.emit(event)
            let resultEvent = await toolRouter.dispatch(tc)

            // Send tool.result back to server
            if let client = conductorClient {
                try? await client.send(event: resultEvent)
            }

        case .assistantSpeechPartial:
            // Stream speech partial to UI (display only, no tool call)
            eventBus.emit(event)

        case .assistantSpeechFinal:
            // Finalize speech text in UI
            eventBus.emit(event)

        case .error(let errInfo):
            // Surface server errors
            eventBus.emit(event)
            errorMessage = errInfo.message
            showError = true

        default:
            // Emit all other events to the timeline
            eventBus.emit(event)
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
        let transcriptEvent = Event.transcriptFinal(finalTranscript)
        eventBus.emit(transcriptEvent)

        // Route to the appropriate conductor
        if useCloudConductor, let client = conductorClient, client.isConnected {
            // Phase 2: send transcript.final to cloud conductor
            do {
                try await client.send(event: transcriptEvent)
            } catch {
                eventBus.emit(Event.error(code: "ws_send_failed", message: error.localizedDescription))
                // Fall back to local conductor
                let conductorEvents = await conductor.handleTranscript(finalTranscript)
                await toolRouter.processEvents(conductorEvents)
            }
        } else {
            // Phase 1: local conductor
            let conductorEvents = await conductor.handleTranscript(finalTranscript)
            await toolRouter.processEvents(conductorEvents)
        }

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

        // 2. Optionally notify server about barge-in
        if useCloudConductor, let client = conductorClient, client.isConnected {
            let interruptEvent = Event.error(code: "audio.output.interrupted", message: "User barged in")
            try? await client.send(event: interruptEvent)
        }

        // 3. Start listening
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
}
