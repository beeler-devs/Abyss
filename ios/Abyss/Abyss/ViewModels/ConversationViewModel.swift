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
    @Published var emailCards: [EmailCard] = []
    @Published var pairedBridgeDevices: [PairedBridgeDevice] = []
    @Published var bridgePairingMessage: String?
    @Published var isMuted: Bool = false
    @Published var isPTTHeld: Bool = false
    @Published var isTTSSpeaking: Bool = false
    @Published private(set) var useServerConductor: Bool = false
    @Published private(set) var repositorySelectionManager = RepositorySelectionManager()
    private weak var gmailAuthManager: GmailAuthManager?
    @AppStorage("agentStatusWebhookUpdatesEnabled") private var agentStatusWebhookUpdatesEnabled: Bool = true
    @AppStorage("recordingMode") private var recordingModeRaw: String = RecordingMode.vadAuto.rawValue

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
    private var conductorConnectionTask: Task<ConductorClient, Error>?
    private var conductorConnectionAttempt = 0
    private var isUsingServerClient = false

    private var audioPipeline: ConversationAudioPipeline!
    private var eventCoordinator: ConversationEventCoordinator!
    private var agentManager: ConversationAgentManager!
    private var emailManager: ConversationEmailManager!

    private var cancellables = Set<AnyCancellable>()

    private static let useServerConductorKey = "useServerConductor"

    private var recordingMode: RecordingMode {
        RecordingMode(rawValue: recordingModeRaw) ?? .vadAuto
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
        conductorConnectionTask?.cancel()
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
        syncRecordingMode()
        audioPipeline.micPressed()
    }

    func micReleased() {
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

    func toggleAgentCardExpanded(cardID: UUID) {
        agentManager.toggleCardExpanded(cardID: cardID)
    }

    func selectRepository(_ repository: RepositorySelectionCard.Repository) {
        repositorySelectionManager.completeSelection(repository: repository)
    }

    func cancelRepositorySelection() {
        repositorySelectionManager.cancelSelection()
    }

    func setGmailAuthManager(_ manager: GmailAuthManager) {
        guard gmailAuthManager == nil else { return }
        gmailAuthManager = manager
        toolRegistry.register(GmailAuthenticateTool(
            authManager: manager,
            onAuthenticated: { [weak self] in
                guard let self else { return }
                await self.configureConductorClient(forceReconnect: true)
            }
        ))
    }

    func toggleEmailCardExpanded(cardID: UUID) {
        emailManager.toggleExpanded(cardId: cardID)
    }

    func requestBridgePairing(pairingCode: String, deviceName: String?) {
        eventCoordinator.requestBridgePairing(pairingCode: pairingCode, deviceName: deviceName)
    }

    func setWorkspaceOverride(deviceId: String, path: String?) {
        eventCoordinator.setWorkspaceOverride(deviceId: deviceId, path: path)
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
            conversationMessages: { [weak self] in
                self?.conversationStore.messages ?? []
            },
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

        emailManager = ConversationEmailManager(eventBus: eventBus)

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
                self?.emailManager.handleEventStream(event)
            }
            .store(in: &cancellables)

        audioPipeline.$appState
            .receive(on: RunLoop.main)
            .assign(to: &$appState)

        tts.isSpeakingPublisher
            .receive(on: RunLoop.main)
            .assign(to: &$isTTSSpeaking)

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

        emailManager.$emailCards
            .receive(on: RunLoop.main)
            .assign(to: &$emailCards)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncRecordingMode()
            }
            .store(in: &cancellables)
    }

    private func syncRecordingMode() {
        audioPipeline.updateRecordingMode(recordingMode)
    }

    private func startSession(using client: ConductorClient? = nil) {
        Task {
            if let client {
                await attachConductorClient(client)
            } else {
                _ = await configureConductorClient(forceReconnect: true)
            }
        }
    }

    @discardableResult
    private func configureConductorClient(forceReconnect: Bool) async -> ConductorClient? {
        let shouldUseServer = useServerConductor && Config.isBackendWSConfigured
        if !forceReconnect,
           shouldUseServer == isUsingServerClient,
           let client = activeConductorClient {
            return client
        }

        if let existingTask = conductorConnectionTask {
            if forceReconnect {
                existingTask.cancel()
                conductorConnectionTask = nil
            } else {
                do {
                    return try await existingTask.value
                } catch {
                    conductorConnectionTask = nil
                }
            }
        }

        conductorConnectionAttempt += 1
        let attempt = conductorConnectionAttempt
        let task = Task<ConductorClient, Error> { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.establishConductorClient(shouldUseServer: shouldUseServer)
        }
        conductorConnectionTask = task

        do {
            let client = try await task.value
            if conductorConnectionAttempt == attempt {
                conductorConnectionTask = nil
            }
            return client
        } catch {
            if conductorConnectionAttempt == attempt {
                conductorConnectionTask = nil
            }
            return nil
        }
    }

    private func establishConductorClient(shouldUseServer: Bool) async throws -> ConductorClient {
        await disconnectActiveConductorClient()

        if shouldUseServer, let backendURL = Config.backendWSURL {
            let wsClient = WebSocketConductorClient(backendURL: backendURL)
            do {
                try await connectConductorClient(wsClient)
                isUsingServerClient = true
                return wsClient
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
            isUsingServerClient = false
            return localClient
        } catch {
            eventBus.emit(Event.error(
                code: "local_conductor_failed",
                message: "Failed to start local conductor: \(error.localizedDescription)",
                sessionId: sessionId
            ))
            throw error
        }
    }

    private func attachConductorClient(_ client: ConductorClient) async {
        conductorConnectionTask?.cancel()
        conductorConnectionTask = nil
        await disconnectActiveConductorClient()
        do {
            try await connectConductorClient(client)
        } catch {
            eventBus.emit(Event.error(
                code: "conductor_connect_failed",
                message: "Failed to attach conductor client: \(error.localizedDescription)",
                sessionId: sessionId
            ))
        }
    }

    private func connectConductorClient(_ client: ConductorClient) async throws {
        let githubToken = GitHubAuthManager.loadToken()
        let gmailAccessToken = GmailAuthManager.loadAccessToken()
        let gmailRefreshToken = GmailAuthManager.loadRefreshToken()
        let gmailTokenExpiresAt = GmailAuthManager.loadExpiresAt()
        try await client.connect(
            sessionId: sessionId,
            githubToken: githubToken,
            gmailAccessToken: gmailAccessToken,
            gmailRefreshToken: gmailRefreshToken,
            gmailTokenExpiresAt: gmailTokenExpiresAt
        )

        inboundEventsTask?.cancel()
        inboundEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.inboundEvents {
                await self.handleInboundEvent(event)
            }
        }
        activeConductorClient = client
    }

    private func disconnectActiveConductorClient() async {
        inboundEventsTask?.cancel()
        inboundEventsTask = nil

        if let client = activeConductorClient {
            await client.disconnect()
        }
        activeConductorClient = nil
    }

    private func sendEventToConductor(_ event: Event, surfaceErrors: Bool = true) async {
        let clientType = activeConductorClient.map { "\(type(of: $0))" } ?? "pending"
        if case .userAudioStreamChunk = event.kind {} else {
            AppLogger.conductor.debug("Sending \(event.kind.displayName, privacy: .public) via \(clientType, privacy: .public)")
        }

        let client: ConductorClient?
        if let activeConductorClient {
            client = activeConductorClient
        } else {
            client = await configureConductorClient(forceReconnect: false)
        }
        guard let client else {
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
                if await retryServerSend(event: event, because: error.localizedDescription) {
                    return
                }

                if isLiveAudioStreamEvent(event) {
                    await audioPipeline.applyRemoteState(.error)
                    if surfaceErrors {
                        eventBus.emit(Event.error(
                            code: "conductor_send_failed",
                            message: "Live conversation lost its server connection: \(error.localizedDescription)",
                            sessionId: sessionId
                        ))
                    }
                    return
                }

                AppLogger.conductor.notice("Falling back to local conductor after server send failure")
                isUsingServerClient = false

                let localClient = LocalConductorClient(conductor: localConductor)
                do {
                    await disconnectActiveConductorClient()
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

    private func retryServerSend(event: Event, because reason: String) async -> Bool {
        guard useServerConductor,
              Config.isBackendWSConfigured,
              Config.backendWSURL != nil else {
            return false
        }

        AppLogger.conductor.notice("Retrying server conductor after failure: \(reason, privacy: .public)")
        conductorConnectionTask?.cancel()
        conductorConnectionTask = nil

        do {
            guard let client = await configureConductorClient(forceReconnect: true) else {
                throw WebSocketConductorClient.Error.notConnected
            }
            try await client.send(event: event)
            return true
        } catch {
            AppLogger.conductor.error("Server retry failed: \(error.localizedDescription, privacy: .public)")
            isUsingServerClient = false
            return false
        }
    }

    private func isLiveAudioStreamEvent(_ event: Event) -> Bool {
        switch event.kind {
        case .userAudioStreamStart, .userAudioStreamChunk, .userAudioStreamEnd:
            return true
        default:
            return false
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
