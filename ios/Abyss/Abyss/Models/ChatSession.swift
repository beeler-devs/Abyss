import Foundation
import SwiftUI

/// A single chat session with its own conversation state, events, and tool calls.
struct ChatSession: Identifiable {
    let id: UUID
    let sessionId: String
    let viewModel: ConversationViewModel
    var title: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: String,
        viewModel: ConversationViewModel,
        title: String = "New Chat",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.viewModel = viewModel
        self.title = title
        self.createdAt = createdAt
    }
}

/// Manages the list of chats and the currently selected chat.
@MainActor
final class ChatListViewModel: ObservableObject {
    private struct PersistedChatSession: Codable {
        let id: UUID
        let sessionId: String
        let title: String
        let createdAt: Date
    }

    private static let persistedChatsKey = "chatSessions.v1"
    private static let selectedChatIdKey = "chatSessions.selectedChatId.v1"

    @Published var chats: [ChatSession] = []
    @Published var selectedChatId: UUID?

    private let defaults: UserDefaults
    private let viewModelFactory: @MainActor (String) -> ConversationViewModel

    init(
        defaults: UserDefaults = .standard,
        viewModelFactory: (@MainActor (String) -> ConversationViewModel)? = nil
    ) {
        self.defaults = defaults
        self.viewModelFactory = viewModelFactory ?? { sessionId in
            ConversationViewModel(sessionId: sessionId)
        }
        loadPersistedChats()
    }

    var selectedChat: ChatSession? {
        guard let id = selectedChatId else { return nil }
        return chats.first { $0.id == id }
    }

    /// Creates a new chat and switches to it.
    func createChat() {
        let sessionId = UUID().uuidString
        let vm = viewModelFactory(sessionId)
        let session = ChatSession(sessionId: sessionId, viewModel: vm)
        chats.insert(session, at: 0)
        selectedChatId = session.id
        persistChats()
    }

    /// Selects a chat by ID.
    func selectChat(id: UUID) {
        selectedChatId = id
        persistChats()
    }

    /// Deletes a chat. If it was selected, selects another.
    func deleteChat(id: UUID) {
        chats.removeAll { $0.id == id }
        if selectedChatId == id {
            selectedChatId = chats.first?.id
        }
        persistChats()
    }

    private func loadPersistedChats() {
        guard let data = defaults.data(forKey: Self.persistedChatsKey),
              let decoded = try? JSONDecoder().decode([PersistedChatSession].self, from: data) else {
            chats = []
            selectedChatId = nil
            return
        }

        chats = decoded.map { persisted in
            ChatSession(
                id: persisted.id,
                sessionId: persisted.sessionId,
                viewModel: viewModelFactory(persisted.sessionId),
                title: persisted.title,
                createdAt: persisted.createdAt
            )
        }

        guard let rawSelectedChatId = defaults.string(forKey: Self.selectedChatIdKey),
              let restoredSelectedChatId = UUID(uuidString: rawSelectedChatId),
              chats.contains(where: { $0.id == restoredSelectedChatId }) else {
            selectedChatId = chats.first?.id
            return
        }

        selectedChatId = restoredSelectedChatId
    }

    private func persistChats() {
        let payload = chats.map { chat in
            PersistedChatSession(
                id: chat.id,
                sessionId: chat.sessionId,
                title: chat.title,
                createdAt: chat.createdAt
            )
        }

        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.persistedChatsKey)
        }

        if let selectedChatId {
            defaults.set(selectedChatId.uuidString, forKey: Self.selectedChatIdKey)
        } else {
            defaults.removeObject(forKey: Self.selectedChatIdKey)
        }
    }
}
