import Combine
import Foundation

/// Parses gmail.* tool results into EmailCard models for inline display.
@MainActor
final class ConversationEmailManager: ObservableObject {
    @Published private(set) var emailCards: [EmailCard] = []

    private let eventBus: EventBus
    private var pendingToolCalls: [String: Event.ToolCall] = [:]

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func handleEventStream(_ event: Event) {
        switch event.kind {
        case .toolCall(let toolCall):
            if toolCall.name.hasPrefix("gmail.") {
                pendingToolCalls[toolCall.callId] = toolCall
            }
        case .toolResult(let toolResult):
            guard let toolCall = pendingToolCalls.removeValue(forKey: toolResult.callId) else { return }
            handleGmailResult(toolResult, for: toolCall)
        default:
            break
        }
    }

    func toggleExpanded(cardId: UUID) {
        guard let index = emailCards.firstIndex(where: { $0.id == cardId }) else { return }
        emailCards[index].isExpanded.toggle()
    }

    private func handleGmailResult(_ result: Event.ToolResult, for toolCall: Event.ToolCall) {
        guard result.error == nil, let json = result.result else { return }
        guard let data = json.data(using: .utf8) else { return }

        switch toolCall.name {
        case "gmail.inbox", "gmail.search":
            parseMessageList(data)
        case "gmail.read":
            parseSingleMessage(data)
        default:
            break
        }
    }

    private func parseMessageList(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(GmailListPayload.self, from: data) else { return }
        for msg in payload.messages {
            guard !emailCards.contains(where: { $0.messageId == msg.messageId }) else { continue }
            emailCards.append(EmailCard(
                messageId: msg.messageId,
                from: msg.from,
                to: msg.to,
                subject: msg.subject,
                date: msg.date,
                snippet: msg.snippet,
                serverCardId: msg.cardId
            ))
        }
    }

    private func parseSingleMessage(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(GmailFullMessage.self, from: data) else { return }
        if let index = emailCards.firstIndex(where: { $0.messageId == msg.messageId }) {
            emailCards[index].body = msg.body
            emailCards[index].isExpanded = true
            if let cardId = msg.cardId { emailCards[index].serverCardId = cardId }
        } else {
            emailCards.append(EmailCard(
                messageId: msg.messageId,
                from: msg.from,
                to: msg.to,
                subject: msg.subject,
                date: msg.date,
                snippet: msg.snippet,
                body: msg.body,
                isExpanded: true,
                serverCardId: msg.cardId
            ))
        }
    }
}

// MARK: - Decodable helpers

private struct GmailListPayload: Decodable {
    let messages: [GmailMessageSummary]
}

private struct GmailMessageSummary: Decodable {
    let messageId: String
    let from: String
    let to: [String]
    let subject: String
    let date: String
    let snippet: String
    let cardId: String?
}

private struct GmailFullMessage: Decodable {
    let messageId: String
    let from: String
    let to: [String]
    let subject: String
    let date: String
    let snippet: String
    let body: String
    let cardId: String?
}
