import Combine
import Foundation

/// Owns Cursor agent progress state, polling, and completion notifications for one conversation session.
/// `ConversationViewModel` mirrors the published cards for the UI, while `EventCoordinator` forwards agent events here.
@MainActor
final class ConversationAgentManager: ObservableObject {
    @Published private(set) var cards: [AgentProgressCard] = []

    private let eventBus: EventBus
    private let toolRouter: ToolRouter
    private let sessionId: String
    private let conversationMessages: @MainActor @Sendable () -> [ConversationMessage]
    private let sendConductorEvent: @MainActor @Sendable (Event) async -> Void
    private let shouldUseWebhookUpdates: @MainActor @Sendable () -> Bool
    private let isUsingServerClient: @MainActor @Sendable () -> Bool

    private var pendingToolCalls: [String: Event.ToolCall] = [:]
    private var agentStatusPollingTask: Task<Void, Never>?
    private var notifiedTerminalAgentIDs: Set<String> = []
    private var hasReceivedWebhookDrivenAgentStatus = false
    private var webhookDrivenAgentIDs: Set<String> = []

    init(
        eventBus: EventBus,
        toolRouter: ToolRouter,
        sessionId: String,
        conversationMessages: @escaping @MainActor @Sendable () -> [ConversationMessage],
        sendConductorEvent: @escaping @MainActor @Sendable (Event) async -> Void,
        shouldUseWebhookUpdates: @escaping @MainActor @Sendable () -> Bool,
        isUsingServerClient: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.eventBus = eventBus
        self.toolRouter = toolRouter
        self.sessionId = sessionId
        self.conversationMessages = conversationMessages
        self.sendConductorEvent = sendConductorEvent
        self.shouldUseWebhookUpdates = shouldUseWebhookUpdates
        self.isUsingServerClient = isUsingServerClient
    }

    deinit {
        agentStatusPollingTask?.cancel()
    }

    func handleEventStream(_ event: Event) {
        switch event.kind {
        case .toolCall(let toolCall):
            pendingToolCalls[toolCall.callId] = toolCall
            if toolCall.name == AgentSpawnTool.name {
                registerPendingCard(from: toolCall)
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

    func refreshAgentStatus(cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }),
              let agentID = card.agentId else { return }
        Task { await requestAgentStatus(agentID: agentID) }
    }

    func dismissCard(cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }) else { return }
        cards.removeAll { $0.id == cardID }
    }

    func cancelAgent(cardID: UUID) {
        guard let card = cards.first(where: { $0.id == cardID }),
              let agentID = card.agentId else { return }

        Task {
            let cancelEvent = Event.toolCall(
                name: AgentCancelTool.name,
                arguments: encode(AgentCancelTool.Arguments(id: agentID)),
                sessionId: sessionId
            )
            eventBus.emit(cancelEvent)
            if case .toolCall(let toolCall) = cancelEvent.kind {
                _ = await toolRouter.dispatch(toolCall)
            }
        }
    }

    func toggleConversationExpanded(cardID: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].isConversationExpanded.toggle()
    }

    func toggleCardExpanded(cardID: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].isExpanded.toggle()
    }

    private func registerPendingCard(from toolCall: Event.ToolCall) {
        guard let args = decode(AgentSpawnTool.Arguments.self, from: toolCall.arguments) else { return }
        guard !cards.contains(where: { $0.spawnCallId == toolCall.callId }) else { return }

        cards.append(
            AgentProgressCard.pending(
                spawnCallId: toolCall.callId,
                prompt: args.prompt,
                repository: args.repository,
                autoCreatePR: args.autoCreatePr ?? false
            )
        )
    }

    private func handleToolResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        switch toolCall.name {
        case AgentSpawnTool.name:
            handleAgentSpawnResult(toolResult, for: toolCall)
        case AgentStatusTool.name:
            handleAgentStatusResult(toolResult, for: toolCall)
        case AgentCancelTool.name:
            handleAgentCancelResult(toolResult)
        default:
            break
        }
    }

    private func handleAgentSpawnResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        if let error = toolResult.error {
            updateCard(spawnCallId: toolCall.callId) {
                $0 = $0.applyingSpawnError(error)
            }
            return
        }

        guard let result = decode(AgentSpawnTool.Result.self, from: toolResult.result) else { return }

        if !updateCard(spawnCallId: toolCall.callId, mutate: { card in
            card = card.applyingSpawnResult(result)
        }) {
            let fallback = AgentProgressCard.pending(
                spawnCallId: toolCall.callId,
                prompt: "Cursor agent task",
                repository: nil,
                autoCreatePR: false
            ).applyingSpawnResult(result)
            cards.append(fallback)
        }

        if result.status.uppercased() != "FINISHED" {
            ensureAgentStatusPolling()
        }
        if let card = cards.first(where: { $0.agentId == result.id }) {
            notifyAgentCompletionIfNeeded(card: card)
        }
    }

    private func handleAgentStatusResult(_ toolResult: Event.ToolResult, for toolCall: Event.ToolCall) {
        guard let args = decode(AgentStatusTool.Arguments.self, from: toolCall.arguments) else { return }

        if let error = toolResult.error {
            updateCard(agentID: args.id) {
                $0 = $0.notingStatusRefreshError(error)
            }
            return
        }

        guard let result = decode(AgentStatusTool.Result.self, from: toolResult.result) else { return }

        if !updateCard(agentID: result.id, mutate: { card in
            card = card.applyingStatusResult(result)
        }) {
            let fallback = AgentProgressCard.pending(
                spawnCallId: toolCall.callId,
                prompt: result.name ?? "Cursor agent task",
                repository: nil,
                autoCreatePR: false
            ).applyingStatusResult(result)
            cards.append(fallback)
        }

        if !cards.filter({ !$0.isTerminal && $0.agentId != nil }).isEmpty {
            ensureAgentStatusPolling()
        }
        if let card = cards.first(where: { $0.agentId == result.id }) {
            notifyAgentCompletionIfNeeded(card: card)
        }
    }

    private func handleAgentCancelResult(_ toolResult: Event.ToolResult) {
        guard toolResult.error == nil,
              let result = decode(AgentCancelTool.Result.self, from: toolResult.result) else { return }

        updateCard(agentID: result.id) {
            $0 = $0.applyingCancelled(agentID: result.id)
        }
    }

    private func handleAgentStatusEvent(_ status: Event.AgentStatus) {
        guard let agentID = status.agentId, !agentID.isEmpty else { return }

        if status.webhookDriven == true && shouldUseWebhookUpdates() {
            hasReceivedWebhookDrivenAgentStatus = true
            webhookDrivenAgentIDs.insert(agentID)
            agentStatusPollingTask?.cancel()
            agentStatusPollingTask = nil
        }

        if !updateCard(agentID: agentID, mutate: { card in
            card = card.applyingAgentStatusEvent(status)
        }) {
            let fallback = AgentProgressCard.pending(
                spawnCallId: "server-\(agentID)",
                prompt: status.summary ?? status.detail ?? "Cursor agent task",
                repository: nil,
                autoCreatePR: false
            ).applyingAgentStatusEvent(status)
            cards.append(fallback)
        }

        if shouldAutoPollAgentStatus(),
           !cards.filter({ !$0.isTerminal && $0.agentId != nil }).isEmpty {
            ensureAgentStatusPolling()
        }

        if let card = cards.first(where: { $0.agentId == agentID }) {
            notifyAgentCompletionIfNeeded(card: card)
        }
    }

    private func handleAgentConversationEvent(_ conversation: Event.AgentConversation) {
        guard !conversation.agentId.isEmpty else { return }
        _ = updateCard(agentID: conversation.agentId, mutate: { card in
            card = card.appendingConversationMessages(conversation.messages)
        })
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
            let activeAgentIDs = cards.compactMap { card -> String? in
                guard let agentID = card.agentId, !card.isTerminal else { return nil }
                return agentID
            }

            guard !activeAgentIDs.isEmpty else { break }

            for agentID in activeAgentIDs {
                guard !Task.isCancelled else { return }
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
        if case .toolCall(let toolCall) = statusEvent.kind {
            _ = await toolRouter.dispatch(toolCall)
        }
    }

    private func notifyAgentCompletionIfNeeded(card: AgentProgressCard) {
        let status = card.normalizedStatus
        guard status == "FINISHED" || status == "FAILED" else { return }
        guard let agentId = card.agentId else { return }
        guard !notifiedTerminalAgentIDs.contains(agentId) else { return }
        notifiedTerminalAgentIDs.insert(agentId)
        if isUsingServerClient() && webhookDrivenAgentIDs.contains(agentId) {
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
        Task { await sendConductorEvent(event) }
    }

    @discardableResult
    private func updateCard(
        spawnCallId: String,
        mutate: (inout AgentProgressCard) -> Void
    ) -> Bool {
        guard let index = cards.firstIndex(where: { $0.spawnCallId == spawnCallId }) else {
            return false
        }
        mutate(&cards[index])
        return true
    }

    @discardableResult
    private func updateCard(
        agentID: String,
        mutate: (inout AgentProgressCard) -> Void
    ) -> Bool {
        guard let index = cards.firstIndex(where: { $0.agentId == agentID }) else {
            return false
        }
        mutate(&cards[index])
        return true
    }


    private func shouldAutoPollAgentStatus() -> Bool {
        if shouldUseWebhookUpdates() && hasReceivedWebhookDrivenAgentStatus {
            return false
        }
        return true
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

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

private extension AgentProgressCard {
    func applyingSpawnResult(_ result: AgentSpawnTool.Result) -> AgentProgressCard {
        var copy = self
        copy.agentId = result.id
        copy.status = result.status
        if let name = result.name, !name.isEmpty {
            copy.title = name
        }
        copy.branchName = result.branchName
        copy.agentURL = result.url
        copy.prURL = result.prUrl
        copy.createdAt = result.createdAt
        if let cardId = result.cardId {
            copy.serverCardId = cardId
        }
        copy.summary = copy.summaryTextForStatus(currentSummary: copy.summary)
        copy.errorMessage = nil
        copy.updatedAt = Date()
        return copy
    }

    func applyingStatusResult(_ result: AgentStatusTool.Result) -> AgentProgressCard {
        var copy = self
        copy.agentId = result.id
        copy.status = result.status

        if let name = result.name, !name.isEmpty {
            copy.title = name
        }

        if let summary = result.summary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.summary = summary
        } else {
            copy.summary = copy.summaryTextForStatus(currentSummary: copy.summary)
        }

        copy.branchName = result.branchName ?? copy.branchName
        copy.agentURL = result.url ?? copy.agentURL
        copy.prURL = result.prUrl ?? copy.prURL
        copy.createdAt = result.createdAt ?? copy.createdAt

        if copy.normalizedStatus == "FINISHED" {
            copy.errorMessage = nil
        }

        copy.updatedAt = Date()
        return copy
    }

    func applyingCancelled(agentID: String) -> AgentProgressCard {
        var copy = self
        copy.agentId = agentID
        copy.status = "STOPPED"
        copy.summary = "Agent stopped by user."
        copy.errorMessage = nil
        copy.updatedAt = Date()
        return copy
    }

    func applyingAgentStatusEvent(_ event: Event.AgentStatus) -> AgentProgressCard {
        var copy = self
        if let incomingAgentID = event.agentId, !incomingAgentID.isEmpty {
            copy.agentId = incomingAgentID
        }

        copy.status = event.status
        copy.summary = event.summary ?? event.detail ?? copy.summaryTextForStatus(currentSummary: copy.summary)

        if let runURL = event.runUrl, !runURL.isEmpty {
            copy.agentURL = runURL
        }
        if let prURL = event.prUrl, !prURL.isEmpty {
            copy.prURL = prURL
        }
        if let branchName = event.branchName, !branchName.isEmpty {
            copy.branchName = branchName
        }

        copy.updatedAt = Date()
        return copy
    }

    func applyingSpawnError(_ message: String) -> AgentProgressCard {
        var copy = self
        copy.status = "FAILED"
        copy.summary = "Could not start Cursor Cloud Agent."
        copy.errorMessage = message
        copy.updatedAt = Date()
        return copy
    }

    func notingStatusRefreshError(_ message: String) -> AgentProgressCard {
        var copy = self
        copy.summary = "Status refresh failed: \(message)"
        copy.updatedAt = Date()
        return copy
    }

    func appendingConversationMessages(_ newMessages: [Event.AgentConversationMessage]) -> AgentProgressCard {
        var copy = self
        let existingIds = Set(copy.conversationMessages.map(\.id))
        let deduped = newMessages.filter { !existingIds.contains($0.id) }
        copy.conversationMessages.append(contentsOf: deduped)
        copy.updatedAt = Date()
        return copy
    }
}
