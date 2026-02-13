import Foundation

/// Tool: convo.appendMessage
/// Appends a message to the conversation transcript.
struct ConvoAppendMessageTool: Tool {
    static let name = "convo.appendMessage"

    struct Arguments: Codable, Sendable {
        let role: String   // "user", "assistant", or "system"
        let text: String
        let isPartial: Bool?
    }

    struct Result: Codable, Sendable {
        let messageId: String
    }

    private let store: ConversationStore

    init(store: ConversationStore) {
        self.store = store
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        guard let role = ConversationMessage.Role(rawValue: arguments.role) else {
            throw ToolError.executionFailed(Self.name, NSError(
                domain: "ConvoAppendMessage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid role: \(arguments.role)"]
            ))
        }

        let message = ConversationMessage(
            role: role,
            text: arguments.text,
            isPartial: arguments.isPartial ?? false
        )

        store.append(message)
        return Result(messageId: message.id.uuidString)
    }
}

/// Shared mutable store for conversation messages, owned by the ViewModel.
@MainActor
final class ConversationStore: Sendable {
    private(set) var messages: [ConversationMessage] = []

    func append(_ message: ConversationMessage) {
        // If the last message is a partial from the same role, replace it
        if let last = messages.last,
           last.isPartial,
           last.role == message.role {
            messages[messages.count - 1] = message
        } else {
            messages.append(message)
        }
    }

    func clear() {
        messages.removeAll()
    }
}
