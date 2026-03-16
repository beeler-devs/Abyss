import Combine
import Foundation

struct PairedBridgeDevice: Codable, Identifiable, Equatable {
    let deviceId: String
    let deviceName: String
    let status: String
    let lastSeen: String?
    let workspaceRoot: String?
    let workspaceOverride: String?
    let pairingCode: String?

    var id: String { deviceId }
}

/// Routes inbound conductor events and bridge-related updates to the audio pipeline, agent manager, and UI-facing stores.
/// `ConversationViewModel` mirrors its published bridge/assistant state while keeping conductor wiring at the top level.
@MainActor
final class ConversationEventCoordinator: ObservableObject {
    @Published private(set) var pairedBridgeDevices: [PairedBridgeDevice] = []
    @Published private(set) var bridgePairingMessage: String?
    @Published private(set) var assistantPartialSpeech: String = ""
    var onTitleGenerated: ((String) -> Void)?

    private let conversationStore: ConversationStore
    private let eventBus: EventBus
    private let toolRouter: ToolRouter
    private let audioPipeline: ConversationAudioPipeline
    private let agentManager: ConversationAgentManager
    private let emailDraftManager: EmailDraftManager
    private let sessionId: String
    private let sendConductorEvent: @MainActor @Sendable (Event, Bool) async -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var pendingPairingCode: String?
    private var activeLiveResponseId: String?
    private var assistantPartialSpeechResponseId: String?
    private var invalidatedLiveResponseIds: Set<String> = []
    private var pendingInterruptCandidate: PendingInterruptCandidate?

    private static let pairedBridgeDevicesKey = "pairedBridgeDevices"
    private static let pendingInterruptTimeoutNanoseconds: UInt64 = 900_000_000

    private struct PendingInterruptCandidate {
        let liveResponseId: String
        let assistantTextSnapshot: String
        let timeoutTask: Task<Void, Never>
    }

    init(
        conversationStore: ConversationStore,
        eventBus: EventBus,
        toolRouter: ToolRouter,
        audioPipeline: ConversationAudioPipeline,
        agentManager: ConversationAgentManager,
        emailDraftManager: EmailDraftManager,
        sessionId: String,
        sendConductorEvent: @escaping @MainActor @Sendable (Event, Bool) async -> Void
    ) {
        self.conversationStore = conversationStore
        self.eventBus = eventBus
        self.toolRouter = toolRouter
        self.audioPipeline = audioPipeline
        self.agentManager = agentManager
        self.emailDraftManager = emailDraftManager
        self.sessionId = sessionId
        self.sendConductorEvent = sendConductorEvent

        loadPairedBridgeDevices()
        refreshBridgeStatusesOnStartup()
        observeLocalEvents()
    }

    deinit {
        pendingInterruptCandidate?.timeoutTask.cancel()
    }

    func requestBridgePairing(pairingCode: String, deviceName: String?) {
        let normalizedCode = pairingCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !normalizedCode.isEmpty else {
            bridgePairingMessage = "Enter a pairing code from AbyssBridge on Mac."
            return
        }

        self.pendingPairingCode = normalizedCode
        AppLogger.conductor.info("Bridge pairing: sending request with code \(normalizedCode, privacy: .public)")
        bridgePairingMessage = "Sending pairing request…"
        let event = Event.bridgePairRequest(
            code: normalizedCode,
            deviceName: deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionId: sessionId
        )
        eventBus.emit(event)

        Task {
            await sendConductorEvent(event, true)
        }
    }

    func reRegisterPairedBridgeCodes() {
        for device in pairedBridgeDevices {
            guard let code = device.pairingCode, !code.isEmpty else { continue }
            AppLogger.conductor.info("Bridge auto-reconnect: re-registering code for \(device.deviceName, privacy: .public)")
            let event = Event.bridgePairRequest(
                code: code,
                deviceName: device.deviceName,
                sessionId: sessionId
            )
            Task { await sendConductorEvent(event, true) }
        }
    }

    func handleEventStream(_ event: Event) {
        agentManager.handleEventStream(event)
    }

    func handleInboundEvent(_ event: Event) async {
        if case .assistantAudioChunk = event.kind {} else {
            AppLogger.conductor.debug("Inbound event: \(event.kind.displayName, privacy: .public)")
        }

        switch event.kind {
        case .assistantSpeechPartial(let partial):
            guard audioPipeline.isHandsFreeLiveConversationMode else {
                assistantPartialSpeech = partial.text
                eventBus.emit(event)
                return
            }
            guard let liveResponseId = partial.liveResponseId,
                  !shouldIgnoreLiveResponse(liveResponseId) else {
                return
            }
            activateLiveResponse(liveResponseId)
            updateAssistantOverlay(with: partial.text, liveResponseId: liveResponseId)
            eventBus.emit(event)

        case .assistantSpeechFinal(let final):
            guard audioPipeline.isHandsFreeLiveConversationMode else {
                assistantPartialSpeech = ""
                eventBus.emit(event)
                return
            }
            guard let liveResponseId = final.liveResponseId,
                  !shouldIgnoreLiveResponse(liveResponseId) else {
                return
            }
            activateLiveResponse(liveResponseId)
            updateAssistantOverlay(with: final.text, liveResponseId: liveResponseId)
            eventBus.emit(event)

        case .assistantAudioChunk(let chunk):
            if audioPipeline.isHandsFreeLiveConversationMode {
                guard let liveResponseId = chunk.liveResponseId,
                      !shouldIgnoreLiveResponse(liveResponseId) else {
                    return
                }
                activateLiveResponse(liveResponseId)
            }
            eventBus.emit(event)
            await audioPipeline.handleAssistantAudioChunk(chunk)

        case .assistantAudioEnd(let audioEnd):
            if audioPipeline.isHandsFreeLiveConversationMode,
               let liveResponseId = audioEnd.liveResponseId,
               shouldIgnoreLiveResponse(liveResponseId) {
                return
            }
            eventBus.emit(event)
            await audioPipeline.handleAssistantAudioEnd()

        case .assistantAudioInterrupted(let interrupted):
            if audioPipeline.isHandsFreeLiveConversationMode,
               let liveResponseId = interrupted.liveResponseId,
               shouldIgnoreLiveResponse(liveResponseId) {
                return
            }
            eventBus.emit(event)
            await audioPipeline.handleAssistantAudioInterrupted()
            if audioPipeline.isHandsFreeLiveConversationMode {
                registerPendingInterruptCandidate(for: interrupted)
            }

        case .toolCall(let toolCall):
            if toolCall.name.hasPrefix("bridge.") {
                eventBus.emit(event)
                return
            }

            // Confirmation tools (gmail.send.confirm, calendar.create.confirm, etc.)
            // are dispatched locally on iOS — they show draft cards and await user input.
            let isConfirmTool = toolCall.name.hasSuffix(".confirm")

            // Server-side tools (canvas/gmail/calendar) are executed on the server.
            // The server sends tool.call + tool.result events so card managers can
            // render inline cards. Do NOT dispatch these locally — there are no iOS
            // tools registered for them, and dispatching would emit an error result
            // that poisons the card manager's pending-call tracking.
            if !isConfirmTool &&
               (toolCall.name.hasPrefix("canvas.") ||
                toolCall.name.hasPrefix("gmail.") ||
                toolCall.name.hasPrefix("calendar.")) {
                AppLogger.tooling.debug("Skipping local dispatch for server-side tool: \(toolCall.name, privacy: .public)")
                eventBus.emit(event)
                return
            }

            if isConfirmTool {
                AppLogger.tooling.info("Dispatching confirm tool locally: \(toolCall.name, privacy: .public) callId=\(toolCall.callId, privacy: .public)")
            }

            if audioPipeline.isHandsFreeLiveConversationMode,
               toolCall.name == ConvoAppendMessageTool.name,
               let arguments = decode(ConvoAppendMessageTool.Arguments.self, from: toolCall.arguments),
               arguments.role == ConversationMessage.Role.assistant.rawValue,
               let liveResponseId = arguments.liveResponseId {
                if shouldIgnoreLiveResponse(liveResponseId) {
                    let result = makeNoOpAppendMessageResult(callId: toolCall.callId)
                    await sendConductorEvent(result, true)
                    return
                }
                activateLiveResponse(liveResponseId)
            }

            eventBus.emit(event)
            let toolResultEvent = await toolRouter.dispatch(toolCall)
            await sendConductorEvent(toolResultEvent, true)

            if audioPipeline.isHandsFreeLiveConversationMode,
               toolCall.name == ConvoAppendMessageTool.name,
               let arguments = decode(ConvoAppendMessageTool.Arguments.self, from: toolCall.arguments),
               arguments.role == ConversationMessage.Role.assistant.rawValue,
               let liveResponseId = arguments.liveResponseId {
                clearAssistantOverlay(for: liveResponseId)
                if arguments.isPartial == false {
                    completeLiveResponse(liveResponseId)
                }
            }

            if toolCall.name == ConvoSetStateTool.name,
               let requested = decode(ConvoSetStateTool.Arguments.self, from: toolCall.arguments),
               let requestedState = AppState(rawValue: requested.state) {
                await audioPipeline.applyRemoteState(requestedState)
            }

        case .bridgePairPending(let pending):
            AppLogger.conductor.info("Bridge pairing: code \(pending.pairingCode, privacy: .public) accepted by server, waiting for bridge to register…")
            bridgePairingMessage = "Pairing code \(pending.pairingCode) accepted — waiting for bridge…"
            eventBus.emit(event)

        case .bridgePaired(let paired):
            AppLogger.conductor.info("Bridge pairing: paired with \(paired.deviceName, privacy: .public) (deviceId=\(paired.deviceId, privacy: .public), status=\(paired.status, privacy: .public))")
            bridgePairingMessage = "Paired with \(paired.deviceName)."
            let existingOverride = pairedBridgeDevices
                .first(where: { $0.deviceId == paired.deviceId })?.workspaceOverride
            upsertPairedBridgeDevice(
                deviceId: paired.deviceId,
                deviceName: paired.deviceName,
                status: paired.status,
                lastSeen: nil,
                workspaceRoot: paired.workspaceRoot,
                workspaceOverride: existingOverride,
                pairingCode: pendingPairingCode
            )
            pendingPairingCode = nil
            if let override = existingOverride, !override.isEmpty {
                sendWorkspaceSet(deviceId: paired.deviceId, path: override)
            }
            eventBus.emit(event)

        case .bridgeStatus(let status):
            AppLogger.conductor.info("Bridge status: deviceId=\(status.deviceId, privacy: .public) status=\(status.status, privacy: .public)")
            let existing = pairedBridgeDevices.first(where: { $0.deviceId == status.deviceId })
            upsertPairedBridgeDevice(
                deviceId: status.deviceId,
                deviceName: existing?.deviceName ?? status.deviceId,
                status: status.status,
                lastSeen: status.lastSeen
                // workspaceRoot/workspaceOverride default nil → helper preserves existing values
            )
            if existing?.status != "online",
               status.status == "online",
               let override = existing?.workspaceOverride, !override.isEmpty {
                sendWorkspaceSet(deviceId: status.deviceId, path: override)
            }
            eventBus.emit(event)

        case .bridgeExecOutput, .bridgeExecFinished, .bridgeWorkspaceSet:
            eventBus.emit(event)

        case .gmailSendResult(let result):
            if result.success {
                emailDraftManager.markSent(callId: result.callId)
            } else {
                emailDraftManager.markFailed(callId: result.callId, error: result.error ?? "Send failed")
            }
            eventBus.emit(event)

        case .error(let error):
            AppLogger.conductor.error("Inbound error: code=\(error.code, privacy: .public) message=\(error.message, privacy: .public)")
            if error.code.hasPrefix("bridge") || error.code.contains("pairing") {
                bridgePairingMessage = "Error: \(error.message)"
            }
            eventBus.emit(event)
            if audioPipeline.isHandsFreeLiveConversationMode,
               error.code == "voice_provider_failed" {
                clearPendingInterruptCandidate()
                invalidateActiveLiveResponse(activeLiveResponseId)
                await audioPipeline.applyRemoteState(.listening)
            }

        case .userAudioTranscriptFinal(let transcript):
            if audioPipeline.isHandsFreeLiveConversationMode,
               handlePendingInterruptTranscript(transcript) {
                return
            }
            eventBus.emit(event)

        case .sessionTitle(let titlePayload):
            onTitleGenerated?(titlePayload.title)
            eventBus.emit(event)

        case .assistantUIPatch, .agentStatus, .agentConversation, .sessionStart, .toolResult,
                .userAudioTranscriptPartial, .userAudioStreamStart,
                .userAudioStreamChunk, .userAudioStreamEnd, .audioOutputInterrupted,
                .agentCompleted, .bridgePairRequest, .preferencesSync, .gmailSendExecute:
            eventBus.emit(event)
        }
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

    private func refreshBridgeStatusesOnStartup() {
        guard !pairedBridgeDevices.isEmpty else { return }

        let refreshed = pairedBridgeDevices.map { device in
            PairedBridgeDevice(
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                status: "offline",
                lastSeen: device.lastSeen,
                workspaceRoot: device.workspaceRoot,
                workspaceOverride: device.workspaceOverride,
                pairingCode: device.pairingCode
            )
        }

        guard refreshed != pairedBridgeDevices else { return }
        pairedBridgeDevices = refreshed
        persistPairedBridgeDevices()
    }

    private func persistPairedBridgeDevices() {
        guard let data = try? JSONEncoder().encode(pairedBridgeDevices) else { return }
        UserDefaults.standard.set(data, forKey: Self.pairedBridgeDevicesKey)
    }

    func setWorkspaceOverride(deviceId: String, path: String?) {
        guard let existing = pairedBridgeDevices.first(where: { $0.deviceId == deviceId }) else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newOverride = (trimmed?.isEmpty == false) ? trimmed : nil
        let updated = PairedBridgeDevice(
            deviceId: existing.deviceId,
            deviceName: existing.deviceName,
            status: existing.status,
            lastSeen: existing.lastSeen,
            workspaceRoot: existing.workspaceRoot,
            workspaceOverride: newOverride,
            pairingCode: existing.pairingCode
        )
        if let index = pairedBridgeDevices.firstIndex(where: { $0.deviceId == deviceId }) {
            pairedBridgeDevices[index] = updated
        }
        persistPairedBridgeDevices()
        if let override = newOverride, existing.status == "online" {
            sendWorkspaceSet(deviceId: deviceId, path: override)
        }
    }

    private func sendWorkspaceSet(deviceId: String, path: String) {
        let event = Event.bridgeWorkspaceSet(deviceId: deviceId, workspacePath: path, sessionId: sessionId)
        Task { await sendConductorEvent(event, true) }
    }

    private func upsertPairedBridgeDevice(
        deviceId: String,
        deviceName: String,
        status: String,
        lastSeen: String?,
        workspaceRoot: String? = nil,
        workspaceOverride: String? = nil,
        pairingCode: String? = nil
    ) {
        let existing = pairedBridgeDevices.first(where: { $0.deviceId == deviceId })
        let updated = PairedBridgeDevice(
            deviceId: deviceId,
            deviceName: deviceName,
            status: status,
            lastSeen: lastSeen ?? existing?.lastSeen,
            workspaceRoot: workspaceRoot ?? existing?.workspaceRoot,
            workspaceOverride: workspaceOverride ?? existing?.workspaceOverride,
            pairingCode: pairingCode ?? existing?.pairingCode
        )

        if let index = pairedBridgeDevices.firstIndex(where: { $0.deviceId == deviceId }) {
            pairedBridgeDevices[index] = updated
        } else {
            pairedBridgeDevices.insert(updated, at: 0)
        }

        persistPairedBridgeDevices()
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func observeLocalEvents() {
        eventBus.stream
            .sink { [weak self] event in
                self?.handleLocalEvent(event)
            }
            .store(in: &cancellables)
    }

    private func handleLocalEvent(_ event: Event) {
        guard audioPipeline.isHandsFreeLiveConversationMode else { return }
        guard case .audioOutputInterrupted = event.kind else { return }
        handleLocalAudioOutputInterrupted()
    }

    private func handleLocalAudioOutputInterrupted() {
        guard let liveResponseId = activeLiveResponseId ?? assistantPartialSpeechResponseId else {
            return
        }

        registerPendingInterruptCandidate(for: liveResponseId)
        invalidatedLiveResponseIds.insert(liveResponseId)
        clearAssistantOverlay(for: liveResponseId)
        if activeLiveResponseId == liveResponseId {
            activeLiveResponseId = nil
        }
    }

    private func shouldIgnoreLiveResponse(_ liveResponseId: String) -> Bool {
        invalidatedLiveResponseIds.contains(liveResponseId)
    }

    private func activateLiveResponse(_ liveResponseId: String) {
        invalidatedLiveResponseIds.remove(liveResponseId)
        if pendingInterruptCandidate?.liveResponseId != liveResponseId {
            clearPendingInterruptCandidate()
        }
        guard activeLiveResponseId != liveResponseId else { return }
        if let activeLiveResponseId {
            invalidateActiveLiveResponse(activeLiveResponseId)
        }
        activeLiveResponseId = liveResponseId
    }

    private func completeLiveResponse(_ liveResponseId: String) {
        clearAssistantOverlay(for: liveResponseId)
        if pendingInterruptCandidate?.liveResponseId == liveResponseId {
            clearPendingInterruptCandidate()
        }
        if activeLiveResponseId == liveResponseId {
            activeLiveResponseId = nil
        }
        invalidatedLiveResponseIds.insert(liveResponseId)
    }

    private func invalidateActiveLiveResponse(_ liveResponseId: String?) {
        if pendingInterruptCandidate?.liveResponseId == liveResponseId {
            clearPendingInterruptCandidate()
        }
        guard let liveResponseId else {
            assistantPartialSpeech = ""
            assistantPartialSpeechResponseId = nil
            activeLiveResponseId = nil
            return
        }
        invalidatedLiveResponseIds.insert(liveResponseId)
        conversationStore.removePartialMessage(role: .assistant, liveResponseId: liveResponseId)
        clearAssistantOverlay(for: liveResponseId)
        if activeLiveResponseId == liveResponseId {
            activeLiveResponseId = nil
        }
    }

    private func updateAssistantOverlay(with incoming: String, liveResponseId: String) {
        guard !conversationStore.hasPartialMessage(role: .assistant, liveResponseId: liveResponseId) else {
            clearAssistantOverlay(for: liveResponseId)
            return
        }

        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }

        if assistantPartialSpeechResponseId != liveResponseId {
            assistantPartialSpeechResponseId = liveResponseId
            assistantPartialSpeech = next
            return
        }

        assistantPartialSpeech = mergeAssistantPartialText(current: assistantPartialSpeech, incoming: next)
    }

    private func clearAssistantOverlay(for liveResponseId: String?) {
        guard liveResponseId == nil || assistantPartialSpeechResponseId == liveResponseId else {
            return
        }
        assistantPartialSpeech = ""
        assistantPartialSpeechResponseId = nil
    }

    private func mergeAssistantPartialText(current: String, incoming: String) -> String {
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return normalizedCurrent }
        guard !normalizedCurrent.isEmpty else { return next }
        guard normalizedCurrent != next else { return normalizedCurrent }

        if next.hasPrefix(normalizedCurrent) {
            return next
        }

        if normalizedCurrent.hasPrefix(next) {
            return normalizedCurrent
        }

        let maxOverlap = min(normalizedCurrent.count, next.count)
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                if normalizedCurrent.suffix(overlap) == next.prefix(overlap) {
                    return normalizedCurrent + next.dropFirst(overlap)
                }
            }
        }

        return normalizedCurrent + " " + next
    }

    private func makeNoOpAppendMessageResult(callId: String) -> Event {
        let result = ConvoAppendMessageTool.Result(messageId: UUID().uuidString)
        let payload = (try? JSONEncoder().encode(result))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"messageId":""}"#
        return Event.toolResult(callId: callId, result: payload, sessionId: sessionId)
    }

    private func registerPendingInterruptCandidate(for interrupted: Event.AssistantAudioInterrupted) {
        guard let liveResponseId = interrupted.liveResponseId ?? activeLiveResponseId else {
            return
        }
        registerPendingInterruptCandidate(for: liveResponseId)
    }

    private func registerPendingInterruptCandidate(for liveResponseId: String) {
        clearPendingInterruptCandidate()

        let assistantTextSnapshot = assistantTextSnapshot(for: liveResponseId)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingInterruptTimeoutNanoseconds)
            await MainActor.run {
                self?.handlePendingInterruptTimeout(for: liveResponseId)
            }
        }

        pendingInterruptCandidate = PendingInterruptCandidate(
            liveResponseId: liveResponseId,
            assistantTextSnapshot: assistantTextSnapshot,
            timeoutTask: timeoutTask
        )
    }

    private func handlePendingInterruptTranscript(_ transcript: Event.TranscriptFinal) -> Bool {
        guard let candidate = pendingInterruptCandidate else {
            return false
        }

        clearPendingInterruptCandidate()

        if isLikelyEchoTranscript(
            transcript.text,
            assistantSnapshot: candidate.assistantTextSnapshot
        ) {
            Task { await audioPipeline.applyRemoteState(.listening) }
            return true
        }

        invalidateActiveLiveResponse(candidate.liveResponseId)
        return false
    }

    private func handlePendingInterruptTimeout(for liveResponseId: String) {
        guard pendingInterruptCandidate?.liveResponseId == liveResponseId else {
            return
        }
        clearPendingInterruptCandidate()
    }

    private func clearPendingInterruptCandidate() {
        pendingInterruptCandidate?.timeoutTask.cancel()
        pendingInterruptCandidate = nil
    }

    private func assistantTextSnapshot(for liveResponseId: String) -> String {
        if let partial = conversationStore.messages.last(where: {
            $0.role == .assistant && $0.liveResponseId == liveResponseId && $0.isPartial
        }) {
            return partial.text
        }

        if assistantPartialSpeechResponseId == liveResponseId {
            return assistantPartialSpeech
        }

        return assistantPartialSpeech
    }

    private func isLikelyEchoTranscript(_ transcript: String, assistantSnapshot: String) -> Bool {
        let normalizedTranscript = normalizeInterruptText(transcript)
        let normalizedAssistant = normalizeInterruptText(assistantSnapshot)
        guard !normalizedTranscript.isEmpty, !normalizedAssistant.isEmpty else {
            return false
        }

        if normalizedAssistant == normalizedTranscript {
            return true
        }

        let suffixWindowSize = max(normalizedTranscript.count * 2, normalizedTranscript.count + 16)
        let assistantSuffix = String(normalizedAssistant.suffix(suffixWindowSize))
        if assistantSuffix.contains(normalizedTranscript) {
            return true
        }

        let transcriptTokens = normalizedTranscript.split(separator: " ").map(String.init)
        guard !transcriptTokens.isEmpty else {
            return false
        }

        let assistantTokenSet = Set(normalizedAssistant.split(separator: " ").map(String.init))
        let overlapCount = transcriptTokens.filter { assistantTokenSet.contains($0) }.count
        let overlapRatio = Double(overlapCount) / Double(transcriptTokens.count)
        let novelTokenCount = Set(
            transcriptTokens.filter { !assistantTokenSet.contains($0) && $0.count >= 3 }
        ).count

        return overlapRatio >= 0.8 && novelTokenCount <= 1
    }

    private func normalizeInterruptText(_ text: String) -> String {
        let loweredScalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return String(loweredScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
