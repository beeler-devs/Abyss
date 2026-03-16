import Foundation

/// Tool: convo.appendMessage
/// Appends a message to the conversation transcript.
struct ConvoAppendMessageTool: Tool {
    static let name = "convo.appendMessage"

    struct Arguments: Codable, Sendable {
        let role: String   // "user", "assistant", or "system"
        let text: String
        let isPartial: Bool?
        let liveResponseId: String?

        init(role: String, text: String, isPartial: Bool? = nil, liveResponseId: String? = nil) {
            self.role = role
            self.text = text
            self.isPartial = isPartial
            self.liveResponseId = liveResponseId
        }
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
            isPartial: arguments.isPartial ?? false,
            liveResponseId: arguments.liveResponseId
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
        if let liveResponseId = message.liveResponseId {
            if let index = messages.lastIndex(where: { $0.role == message.role && $0.liveResponseId == liveResponseId }) {
                messages[index] = message
                return
            }

            messages.append(message)
            return
        }

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

    func hasPartialMessage(role: ConversationMessage.Role, liveResponseId: String? = nil) -> Bool {
        messages.contains {
            $0.role == role
                && $0.isPartial
                && (liveResponseId == nil || $0.liveResponseId == liveResponseId)
        }
    }

    func upsertStreamingMessage(role: ConversationMessage.Role, text: String, liveResponseId: String? = nil) {
        guard let normalized = normalizedText(text) else { return }

        if let idx = messages.lastIndex(where: {
            $0.role == role
                && $0.isPartial
                && (liveResponseId == nil || $0.liveResponseId == liveResponseId)
        }) {
            var updated = messages[idx]
            updated.text = mergeStreamingText(existing: updated.text, incoming: normalized)
            messages[idx] = updated
            return
        }

        messages.append(ConversationMessage(
            role: role,
            text: normalized,
            isPartial: true,
            liveResponseId: liveResponseId
        ))
    }

    func finalizeLastPartialMessage(
        role: ConversationMessage.Role,
        finalText: String? = nil,
        liveResponseId: String? = nil
    ) {
        guard let idx = messages.lastIndex(where: {
            $0.role == role
                && $0.isPartial
                && (liveResponseId == nil || $0.liveResponseId == liveResponseId)
        }) else {
            return
        }

        var updated = messages[idx]
        if let normalizedFinalText = normalizedText(finalText) {
            updated.text = normalizedFinalText
        }
        updated.isPartial = false
        messages[idx] = updated
    }

    func removePartialMessage(role: ConversationMessage.Role, liveResponseId: String? = nil) {
        guard let index = messages.lastIndex(where: {
            $0.role == role
                && $0.isPartial
                && (liveResponseId == nil || $0.liveResponseId == liveResponseId)
        }) else {
            return
        }
        messages.remove(at: index)
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
