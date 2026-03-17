import Foundation

struct CalendarDeleteConfirmTool: Tool, @unchecked Sendable {
    static let name = "calendar.delete.confirm"

    struct Arguments: Codable, Sendable {
        let callId: String?
        let eventId: String
        let summary: String?
    }

    struct Result: Codable, Sendable {
        let confirmed: Bool
        let message: String
    }

    private let draftManager: CalendarDraftManager

    init(draftManager: CalendarDraftManager) {
        self.draftManager = draftManager
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let resolvedCallId = arguments.callId ?? UUID().uuidString

        draftManager.addDraft(
            callId: resolvedCallId,
            action: .delete,
            summary: arguments.summary ?? "Event",
            startTime: nil,
            endTime: nil,
            location: nil,
            description: nil,
            attendees: [],
            eventId: arguments.eventId,
            serverCardId: resolvedCallId
        )

        return Result(confirmed: true, message: "Draft shown to user for confirmation.")
    }
}
