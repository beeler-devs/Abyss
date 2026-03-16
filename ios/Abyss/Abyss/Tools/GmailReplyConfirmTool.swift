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

        draftManager.addDraft(
            callId: resolvedCallId,
            to: arguments.to ?? "",
            cc: arguments.cc,
            subject: "Re:",
            body: arguments.body,
            messageId: arguments.messageId
        )

        // Return immediately — non-blocking. Server doesn't wait for this result.
        return Result(confirmed: true, message: "Draft reply shown to user for confirmation.")
    }
}
