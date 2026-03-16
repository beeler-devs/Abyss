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
        // Fast path: last message is a partial from the same role — replace it
        if let last = messages.last,
           last.isPartial,
           last.role == message.role {
            messages[messages.count - 1] = message
            return
        }

        // Defensive: finalization arrived after a user message was interleaved —
        // search backwards for an orphaned partial of the same role and replace it.
        if !message.isPartial,
           let idx = messages.lastIndex(where: { $0.isPartial && $0.role == message.role }) {
            messages[idx] = message
            return
        }

        messages.append(message)
    }

    func hasPartialMessage(role: ConversationMessage.Role) -> Bool {
        messages.contains { $0.role == role && $0.isPartial }
    }

    func upsertStreamingMessage(role: ConversationMessage.Role, text: String) {
        guard let normalized = normalizedText(text) else { return }

        if let idx = messages.lastIndex(where: { $0.role == role && $0.isPartial }) {
            var updated = messages[idx]
            updated.text = mergeStreamingText(existing: updated.text, incoming: normalized)
            messages[idx] = updated
            return
        }

        messages.append(ConversationMessage(role: role, text: normalized, isPartial: true))
    }

    func finalizeLastPartialMessage(role: ConversationMessage.Role, finalText: String? = nil) {
        guard let idx = messages.lastIndex(where: { $0.role == role && $0.isPartial }) else {
            return
        }

        var updated = messages[idx]
        if let normalizedFinalText = normalizedText(finalText) {
            updated.text = normalizedFinalText
        }
        updated.isPartial = false
        messages[idx] = updated
    }

    func clear() {
        messages.removeAll()
    }

    private func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func mergeStreamingText(existing: String, incoming: String) -> String {
        let current = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !current.isEmpty else { return next }
        guard !next.isEmpty else { return current }
        guard current != next else { return current }

        if next.hasPrefix(current) {
            return next
        }

        if current.hasPrefix(next) {
            return current
        }

        let overlap = overlapLength(betweenSuffixOf: current, andPrefixOf: next)
        if overlap > 0 {
            return current + next.dropFirst(overlap)
        }

        if current.hasSuffix(" ") || next.hasPrefix(" ") {
            return current + next
        }

        return current + " " + next
    }

    private func overlapLength(betweenSuffixOf existing: String, andPrefixOf incoming: String) -> Int {
        let maxOverlap = min(existing.count, incoming.count)
        guard maxOverlap > 0 else { return 0 }

        for count in stride(from: maxOverlap, through: 1, by: -1) {
            if existing.suffix(count) == incoming.prefix(count) {
                return count
            }
        }

        return 0
    }
}
