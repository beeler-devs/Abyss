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
