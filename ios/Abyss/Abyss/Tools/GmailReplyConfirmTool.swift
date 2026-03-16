import Foundation

struct GmailReplyConfirmTool: Tool, @unchecked Sendable {
    static let name = "gmail.reply.confirm"

    struct Arguments: Codable, Sendable {
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
        let callId = UUID().uuidString
        do {
            let confirmed = try await draftManager.requestConfirmation(
                callId: callId,
                to: arguments.to ?? "",
                cc: arguments.cc,
                subject: "Re:",
                body: arguments.body,
                messageId: arguments.messageId,
                anchorMessageID: nil
            )
            return Result(confirmed: confirmed, message: "User confirmed. Reply sent.")
        } catch is EmailDraftManager.DraftError {
            return Result(confirmed: false, message: "User cancelled the reply.")
        }
    }
}
