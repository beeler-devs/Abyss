import Foundation

enum EmailDraftSendState: Equatable, Sendable {
    case pending
    case sending
    case sent
    case cancelled
    case failed(String)
}

struct EmailDraftCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let callId: String
    var to: String
    let cc: String?
    var subject: String
    var body: String
    let messageId: String?
    var sendState: EmailDraftSendState
    var serverCardId: String?

    var isReply: Bool { messageId != nil }

    init(
        id: UUID = UUID(),
        callId: String,
        to: String,
        cc: String? = nil,
        subject: String,
        body: String,
        messageId: String? = nil,
        sendState: EmailDraftSendState = .pending,
        serverCardId: String? = nil
    ) {
        self.id = id
        self.callId = callId
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.messageId = messageId
        self.sendState = sendState
        self.serverCardId = serverCardId
    }
}
