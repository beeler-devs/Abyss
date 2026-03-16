import Combine
import Foundation

/// Parses bridge exec tool calls and streaming output into BridgeExecCard models.
@MainActor
final class ConversationBridgeExecManager: ObservableObject {
    @Published private(set) var cards: [BridgeExecCard] = []

    private var pendingByCallId: [String: UUID] = [:]
    private var cardByCommandId: [String: UUID] = [:]
    private var lastAssistantMessageID: UUID?

    private static let bridgeExecToolNames: Set<String> = [
        "bridge.exec.run",
        "bridge.exec.start",
        "bridge.claude.run",
    ]

    func updateLastAssistantMessageID(_ id: UUID) {
        lastAssistantMessageID = id
    }

    func handleEventStream(_ event: Event) {
        switch event.kind {
        case .toolCall(let toolCall):
            guard Self.bridgeExecToolNames.contains(toolCall.name) else { return }
            let command = parseCommand(from: toolCall)
            var card = BridgeExecCard(
                callId: toolCall.callId,
                anchorMessageID: nil,
                command: command,
                status: .running
            )
            card.isExpanded = true
            cards.append(card)
            pendingByCallId[toolCall.callId] = card.id

        case .toolResult(let toolResult):
            guard let cardId = pendingByCallId[toolResult.callId] else { return }
            guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }

            if let resultJSON = toolResult.result,
               let commandId = parseCommandId(from: resultJSON) {
                cards[index].commandId = commandId
                cardByCommandId[commandId] = cardId
            }

            if toolResult.isError {
                cards[index].status = .failed
                cards[index].finishedAt = Date()
            }

        case .bridgeExecOutput(let output):
            let index: Int?
            if let cardId = cardByCommandId[output.commandId] {
                index = cards.firstIndex(where: { $0.id == cardId })
            } else {
                // Fallback: match the single running card with no commandId yet
                index = cards.firstIndex(where: { $0.status == .running && $0.commandId == nil })
                if let idx = index {
                    cards[idx].commandId = output.commandId
                    cardByCommandId[output.commandId] = cards[idx].id
                }
            }
            guard let idx = index else { return }
            cards[idx].appendOutput(output.chunk)

        case .bridgeExecFinished(let finished):
            let cardId: UUID?
            if let id = cardByCommandId[finished.commandId] {
                cardId = id
            } else {
                // Fallback: match running card without commandId
                cardId = cards.first(where: { $0.status == .running && $0.commandId == nil })?.id
            }
            guard let id = cardId,
                  let index = cards.firstIndex(where: { $0.id == id }) else { return }
            cards[index].commandId = finished.commandId
            cards[index].exitCode = finished.exitCode
            cards[index].status = finished.exitCode == 0 ? .finished : .failed
            cards[index].finishedAt = Date()
            cardByCommandId[finished.commandId] = id

        default:
            break
        }
    }

    func anchorUnanchoredCards(to messageID: UUID) {
        for index in cards.indices where cards[index].anchorMessageID == nil {
            cards[index].anchorMessageID = messageID
        }
    }

    func toggleExpanded(cardID: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].isExpanded.toggle()
    }

    // MARK: - Parsing

    private func parseCommand(from toolCall: Event.ToolCall) -> String {
        guard let data = toolCall.arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return toolCall.name
        }
        // bridge.exec.run / bridge.exec.start use "command"
        if let command = json["command"] as? String {
            return command
        }
        // bridge.claude.run uses "prompt"
        if let prompt = json["prompt"] as? String {
            return prompt
        }
        return toolCall.name
    }

    private func parseCommandId(from resultJSON: String) -> String? {
        guard let data = resultJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["commandId"] as? String
    }
}
