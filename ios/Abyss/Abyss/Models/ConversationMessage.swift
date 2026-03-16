import Foundation

/// A single message in the conversation transcript.
struct ConversationMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let role: Role
    var text: String
    var isPartial: Bool
    let liveResponseId: String?
    let timestamp: Date

    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isPartial: Bool = false,
        liveResponseId: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isPartial = isPartial
        self.liveResponseId = liveResponseId
        self.timestamp = timestamp
    }
}
