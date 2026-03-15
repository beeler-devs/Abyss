import Combine
import Foundation
import SwiftUI

/// High-level conversation orchestrator.
/// It keeps the published UI surface stable while wiring together the audio pipeline, event coordinator, and agent manager.
@MainActor
final class ConversationViewModel: ObservableObject {
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
    @Published var isPTTHeld: Bool = false
    @Published private(set) var useServerConductor: Bool = false
    @Published private(set) var repositorySelectionManager = RepositorySelectionManager()
    @AppStorage("agentStatusWebhookUpdatesEnabled") private var agentStatusWebhookUpdatesEnabled: Bool = true
    @AppStorage("recordingMode") private var recordingModeRaw: String = RecordingMode.vadAuto.rawValue
    @AppStorage("voiceMode") private var voiceModeRaw: String = VoiceMode.local.rawValue

    let eventBus = EventBus()
    let conversationStore = ConversationStore()
    let appStateStore = AppStateStore()

    private var toolRegistry: ToolRegistry!
    private var toolRouter: ToolRouter!

    private var transcriber: SpeechTranscriber
    private var tts: TextToSpeech
    private let transcriptFormatter: FastTranscriptFormatter

    private let localConductor: Conductor
    private let sessionId: String
    private var activeConductorClient: ConductorClient?
    private var inboundEventsTask: Task<Void, Never>?
    private var isUsingServerClient = false

    private var audioPipeline: ConversationAudioPipeline!
    private var eventCoordinator: ConversationEventCoordinator!
    private var agentManager: ConversationAgentManager!

    private var cancellables = Set<AnyCancellable>()

    private static let useServerConductorKey = "useServerConductor"

    private var recordingMode: RecordingMode {
        RecordingMode(rawValue: recordingModeRaw) ?? .vadAuto
    }

    private var voiceMode: VoiceMode {
        VoiceMode(rawValue: voiceModeRaw) ?? .local
    }

    init(sessionId: String = UUID().uuidString) {
        let defaults = UserDefaults.standard
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
        self.transcriber = WhisperKitSpeechTranscriber()
        self.tts = ElevenLabsTTS(
            voiceId: Config.elevenLabsVoiceId,
            modelId: Config.elevenLabsModelId
        )
        self.transcriptFormatter = FastTranscriptFormatter()

        setupToolSystem()
        setupConversationComponents()
        observeStores()
        audioPipeline.preloadTranscriber()
        startSession()
    }

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
        setupConversationComponents()
        observeStores()
    }

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
        setupConversationComponents()
        observeStores()

        if autoStartSession {
            startSession(using: conductorClient)
        }
    }

    deinit {
        inboundEventsTask?.cancel()
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

    func setChatActive(_ isActive: Bool) {
        syncRecordingMode()
        audioPipeline.setChatActive(isActive)
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        syncRecordingMode()
        audioPipeline.setMuted(muted)
    }

    func interruptAssistantSpeech() {
        syncRecordingMode()
        audioPipeline.interruptAssistantSpeech()
    }

    func micPressed() {
        isPTTHeld = true
        syncRecordingMode()
        audioPipeline.micPressed()
    }

    func micReleased() {
        isPTTHeld = false
        syncRecordingMode()
        audioPipeline.micReleased()
    }

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
        agentManager.refreshAgentStatus(cardID: cardID)
    }

    func dismissAgentCard(cardID: UUID) {
        agentManager.dismissCard(cardID: cardID)
    }

    func cancelAgent(cardID: UUID) {
        agentManager.cancelAgent(cardID: cardID)
    }

    func toggleConversationExpanded(cardID: UUID) {
        agentManager.toggleConversationExpanded(cardID: cardID)
    }

    func selectRepository(_ repository: RepositorySelectionCard.Repository) {
        repositorySelectionManager.completeSelection(repository: repository)
    }

    func cancelRepositorySelection() {
        repositorySelectionManager.cancelSelection()
    }

    func requestBridgePairing(pairingCode: String, deviceName: String?) {
        eventCoordinator.requestBridgePairing(pairingCode: pairingCode, deviceName: deviceName)
    }

    private func setupToolSystem(transcriber: SpeechTranscriber? = nil, tts: TextToSpeech? = nil) {
        let registry = ToolRegistry()
        let sttImpl = transcriber ?? self.transcriber
        let ttsImpl = tts ?? self.tts
        let cursorClient = CursorCloudAgentsClient()

        registry.register(STTStartTool(transcriber: sttImpl, onPartial: { [weak self] partial in
            self?.audioPipeline?.handlePartialTranscript(partial)
        }))
        registry.register(STTStopTool(transcriber: sttImpl))
        registry.register(TTSSpeakTool(tts: ttsImpl))
        registry.register(TTSStopTool(tts: ttsImpl))
        registry.register(ConvoAppendMessageTool(store: conversationStore))
        registry.register(ConvoSetStateTool(stateStore: appStateStore))
        registry.register(AgentSpawnTool(client: cursorClient))
        registry.register(AgentStatusTool(client: cursorClient))
        registry.register(AgentCancelTool(client: cursorClient))
        registry.register(AgentFollowUpTool(client: cursorClient))
        registry.register(AgentListTool(client: cursorClient))
        registry.register(RepositoriesListTool(client: cursorClient))
        registry.register(RepositoriesSelectTool(client: cursorClient, selectionManager: repositorySelectionManager))

        toolRegistry = registry
        toolRouter = ToolRouter(registry: registry, eventBus: eventBus)
    }

    private func setupConversationComponents() {
        audioPipeline = ConversationAudioPipeline(
            transcriber: transcriber,
            tts: tts,
            transcriptFormatter: transcriptFormatter,
            eventBus: eventBus,
            toolRouter: toolRouter,
            appStateStore: appStateStore,
            sessionId: sessionId,
            sendConductorEvent: { [weak self] event, surfaceErrors in
                await self?.sendEventToConductor(event, surfaceErrors: surfaceErrors)
            },
            handleError: { [weak self] message in
                await self?.handleToolError(message)
            }
        )

        agentManager = ConversationAgentManager(
            eventBus: eventBus,
            toolRouter: toolRouter,
            sessionId: sessionId,
            sendConductorEvent: { [weak self] event in
                await self?.sendEventToConductor(event)
            },
            shouldUseWebhookUpdates: { [weak self] in
                self?.agentStatusWebhookUpdatesEnabled ?? true
            },
            isUsingServerClient: { [weak self] in
                self?.isUsingServerClient ?? false
            }
        )

        eventCoordinator = ConversationEventCoordinator(
            eventBus: eventBus,
            toolRouter: toolRouter,
            audioPipeline: audioPipeline,
            agentManager: agentManager,
            sessionId: sessionId,
            sendConductorEvent: { [weak self] event, surfaceErrors in
                await self?.sendEventToConductor(event, surfaceErrors: surfaceErrors)
            }
        )

        syncRecordingMode()
    }

    private func observeStores() {
        eventBus.$events
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.messages = self.conversationStore.messages
            }
            .store(in: &cancellables)

        eventBus.stream
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.eventCoordinator.handleEventStream(event)
            }
            .store(in: &cancellables)

        audioPipeline.$appState
            .receive(on: RunLoop.main)
            .assign(to: &$appState)

        audioPipeline.$partialTranscript
            .receive(on: RunLoop.main)
            .assign(to: &$partialTranscript)

        eventCoordinator.$assistantPartialSpeech
            .receive(on: RunLoop.main)
            .assign(to: &$assistantPartialSpeech)

        eventCoordinator.$pairedBridgeDevices
            .receive(on: RunLoop.main)
            .assign(to: &$pairedBridgeDevices)

        eventCoordinator.$bridgePairingMessage
            .receive(on: RunLoop.main)
            .assign(to: &$bridgePairingMessage)

        agentManager.$cards
            .receive(on: RunLoop.main)
            .assign(to: &$agentProgressCards)
    }

    private func syncRecordingMode() {
        audioPipeline.updateVoiceMode(voiceMode)
        audioPipeline.updateRecordingMode(recordingMode)
    }

    private func startSession(using client: ConductorClient? = nil) {
        Task {
            if let client {
                await attachConductorClient(client)
            } else {
                await configureConductorClient(forceReconnect: true)
            }
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

    private func sendEventToConductor(_ event: Event, surfaceErrors: Bool = true) async {
        let clientType = activeConductorClient.map { "\(type(of: $0))" } ?? "nil"
        AppLogger.conductor.debug("Sending \(event.kind.displayName, privacy: .public) via \(clientType, privacy: .public)")

        guard let client = activeConductorClient else {
            if surfaceErrors {
                eventBus.emit(Event.error(
                    code: "conductor_missing",
                    message: "Conductor client is not available.",
                    sessionId: sessionId
                ))
            }
            return
        }

        do {
            try await client.send(event: event)
        } catch {
            AppLogger.conductor.error("Send failed: \(error.localizedDescription, privacy: .public)")

            if isUsingServerClient {
                AppLogger.conductor.notice("Falling back to local conductor after server send failure")
                isUsingServerClient = false
                useServerConductor = false

                let localClient = LocalConductorClient(conductor: localConductor)
                do {
                    try await connectConductorClient(localClient)
                    try await localClient.send(event: event)
                } catch {
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
        await eventCoordinator.handleInboundEvent(event)
    }

    private func handleToolError(_ message: String) async {
        appStateStore.current = .error
        appState = .error

        let setErrorEvent = Event.toolCall(
            name: ConvoSetStateTool.name,
            arguments: encode(ConvoSetStateTool.Arguments(state: AppState.error.rawValue)),
            sessionId: sessionId
        )
        eventBus.emit(setErrorEvent)
        if case .toolCall(let toolCall) = setErrorEvent.kind {
            await toolRouter.dispatch(toolCall)
        }

        eventBus.emit(Event.error(code: "tool_error", message: message, sessionId: sessionId))
        errorMessage = message
        showError = true
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
