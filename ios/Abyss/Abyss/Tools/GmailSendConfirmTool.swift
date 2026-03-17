import Foundation

struct GmailSendConfirmTool: Tool, @unchecked Sendable {
    static let name = "gmail.send.confirm"

    struct Arguments: Codable, Sendable {
        let callId: String?
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
        let resolvedCallId = arguments.callId ?? UUID().uuidString
        AppLogger.tooling.info("gmail.send.confirm execute: callId=\(resolvedCallId, privacy: .public) to=\(arguments.to, privacy: .public) subject=\(arguments.subject, privacy: .public)")

        draftManager.addDraft(
            callId: resolvedCallId,
            to: arguments.to,
            cc: arguments.cc,
            subject: arguments.subject,
            body: arguments.body,
            messageId: nil,
            anchorMessageID: nil
        )
        return Result(confirmed: true, message: "Draft card shown to user for review. Awaiting their confirmation before sending.")
    }
}
