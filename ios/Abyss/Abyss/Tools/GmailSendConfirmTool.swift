import Foundation

struct GmailSendConfirmTool: Tool, @unchecked Sendable {
    static let name = "gmail.send.confirm"

    struct Arguments: Codable, Sendable {
        let to: String
        let cc: String?
        let subject: String
        let body: String
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
                to: arguments.to,
                cc: arguments.cc,
                subject: arguments.subject,
                body: arguments.body,
                messageId: nil,
                anchorMessageID: nil
            )
            return Result(confirmed: confirmed, message: "User confirmed. Email sent.")
        } catch is EmailDraftManager.DraftError {
            return Result(confirmed: false, message: "User cancelled the email.")
        }
    }
}
