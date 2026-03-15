import Combine
import Foundation

struct PairedBridgeDevice: Codable, Identifiable, Equatable {
    let deviceId: String
    let deviceName: String
    let status: String
    let lastSeen: String?

    var id: String { deviceId }
}

/// Routes inbound conductor events and bridge-related updates to the audio pipeline, agent manager, and UI-facing stores.
/// `ConversationViewModel` mirrors its published bridge/assistant state while keeping conductor wiring at the top level.
@MainActor
final class ConversationEventCoordinator: ObservableObject {
    @Published private(set) var pairedBridgeDevices: [PairedBridgeDevice] = []
    @Published private(set) var bridgePairingMessage: String?
    @Published private(set) var assistantPartialSpeech: String = ""

    private let eventBus: EventBus
    private let toolRouter: ToolRouter
    private let audioPipeline: ConversationAudioPipeline
    private let agentManager: ConversationAgentManager
    private let sessionId: String
    private let sendConductorEvent: @MainActor @Sendable (Event, Bool) async -> Void

    private static let pairedBridgeDevicesKey = "pairedBridgeDevices"

    init(
        eventBus: EventBus,
        toolRouter: ToolRouter,
        audioPipeline: ConversationAudioPipeline,
        agentManager: ConversationAgentManager,
        sessionId: String,
        sendConductorEvent: @escaping @MainActor @Sendable (Event, Bool) async -> Void
    ) {
        self.eventBus = eventBus
        self.toolRouter = toolRouter
        self.audioPipeline = audioPipeline
        self.agentManager = agentManager
        self.sessionId = sessionId
        self.sendConductorEvent = sendConductorEvent

        loadPairedBridgeDevices()
        refreshBridgeStatusesOnStartup()
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
            await sendConductorEvent(event, true)
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
            guard assistantPartialSpeech != partial.text else { return }
            assistantPartialSpeech = partial.text
            eventBus.emit(event)

        case .assistantSpeechFinal:
            assistantPartialSpeech = ""
            eventBus.emit(event)

        case .assistantAudioChunk(let chunk):
            eventBus.emit(event)
            await audioPipeline.handleAssistantAudioChunk(chunk)

        case .assistantAudioEnd:
            eventBus.emit(event)
            await audioPipeline.handleAssistantAudioEnd()

        case .assistantAudioInterrupted:
            eventBus.emit(event)
            await audioPipeline.handleAssistantAudioInterrupted()

        case .toolCall(let toolCall):
            eventBus.emit(event)
            if toolCall.name.hasPrefix("bridge.") {
                return
            }

            let toolResultEvent = await toolRouter.dispatch(toolCall)
            await sendConductorEvent(toolResultEvent, true)

            if toolCall.name == ConvoSetStateTool.name,
               let requested = decode(ConvoSetStateTool.Arguments.self, from: toolCall.arguments),
               let requestedState = AppState(rawValue: requested.state) {
                await audioPipeline.applyRemoteState(requestedState)
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

        case .bridgeExecOutput, .bridgeExecFinished:
            eventBus.emit(event)

        case .assistantUIPatch, .agentStatus, .agentConversation, .sessionStart, .toolResult, .error,
                .userAudioTranscriptPartial, .userAudioTranscriptFinal, .userAudioStreamStart,
                .userAudioStreamChunk, .userAudioStreamEnd, .audioOutputInterrupted,
                .agentCompleted, .bridgePairRequest:
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
                lastSeen: device.lastSeen
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

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
