import Foundation

struct GmailReplyConfirmTool: Tool, @unchecked Sendable {
    static let name = "gmail.reply.confirm"

    struct Arguments: Codable, Sendable {
        let callId: String?
        let messageId: String
        let body: String
        let to: String?
        let cc: String?
    }

    struct Result: Codable, Sendable {
        let confirmed: Bool
        let message: String
    }

    private let draftManager: EmailDraftManager

    init(draftManager: EmailDraftManager) {
        self.draftManager = draftManager
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let resolvedCallId = arguments.callId ?? UUID().uuidString
        AppLogger.tooling.info("gmail.reply.confirm execute: callId=\(resolvedCallId, privacy: .public) messageId=\(arguments.messageId, privacy: .public)")

        draftManager.addDraft(
            callId: resolvedCallId,
            to: arguments.to ?? "",
            cc: arguments.cc,
            subject: "Re:",
            body: arguments.body,
            messageId: arguments.messageId,
            anchorMessageID: nil
        )
        return Result(confirmed: true, message: "Draft reply card shown to user for review. Awaiting their confirmation before sending.")
    }
}
