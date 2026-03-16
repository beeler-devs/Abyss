import Foundation

/// Reads and writes per-session message history to the Documents directory.
final class ChatHistoryStore {

    private let baseURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseURL = docs.appendingPathComponent("chat-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Load persisted messages for a session. Returns [] if none exist.
    func load(sessionId: String) -> [ConversationMessage] {
        let url = fileURL(for: sessionId)
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([ConversationMessage].self, from: data) else {
            return []
        }
        return messages
    }

    /// Overwrite the stored messages for a session.
    func save(_ messages: [ConversationMessage], sessionId: String) {
        let url = fileURL(for: sessionId)
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Delete stored history for a session (called when user deletes a chat).
    func delete(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
    }

    private func fileURL(for sessionId: String) -> URL {
        baseURL.appendingPathComponent("\(sessionId).json")
    }
}
