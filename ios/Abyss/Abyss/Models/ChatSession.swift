import Foundation
import SwiftUI

/// A single chat session with its own conversation state, events, and tool calls.
struct ChatSession: Identifiable {
    let id: UUID
    let viewModel: ConversationViewModel
    var title: String
    let createdAt: Date

    init(id: UUID = UUID(), viewModel: ConversationViewModel, title: String = "New Chat", createdAt: Date = Date()) {
        self.id = id
        self.viewModel = viewModel
        self.title = title
        self.createdAt = createdAt
    }
}

/// Manages the list of chats and the currently selected chat.
@MainActor
final class ChatListViewModel: ObservableObject {
    @Published var chats: [ChatSession] = []
    @Published var selectedChatId: UUID?

    var selectedChat: ChatSession? {
        guard let id = selectedChatId else { return nil }
        return chats.first { $0.id == id }
    }

    /// Creates a new chat and switches to it.
    func createChat() {
        let vm = ConversationViewModel()
        let session = ChatSession(viewModel: vm)
        chats.insert(session, at: 0)
        selectedChatId = session.id
    }

    /// Selects a chat by ID.
    func selectChat(id: UUID) {
        selectedChatId = id
    }

    /// Deletes a chat. If it was selected, selects another.
    func deleteChat(id: UUID) {
        chats.removeAll { $0.id == id }
        if selectedChatId == id {
            selectedChatId = chats.first?.id
        }
    }
}
