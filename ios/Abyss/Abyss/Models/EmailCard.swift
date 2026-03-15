import Foundation

struct EmailCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let messageId: String
    let from: String
    let to: [String]
    let subject: String
    let date: String
    let snippet: String
    var body: String?
    var isExpanded: Bool
    var anchorMessageID: UUID?

    init(
        id: UUID = UUID(),
        messageId: String,
        from: String,
        to: [String] = [],
        subject: String,
        date: String,
        snippet: String,
        body: String? = nil,
        isExpanded: Bool = false,
        anchorMessageID: UUID? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.snippet = snippet
        self.body = body
        self.isExpanded = isExpanded
        self.anchorMessageID = anchorMessageID
    }
}
