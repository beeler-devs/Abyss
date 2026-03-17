import Foundation

struct CalendarUpdateConfirmTool: Tool, @unchecked Sendable {
    static let name = "calendar.update.confirm"

    struct Arguments: Codable, Sendable {
        let callId: String?
        let eventId: String
        let summary: String?
        let startTime: String?
        let endTime: String?
        let description: String?
        let location: String?
        let attendees: String?
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
        let attendeeList = arguments.attendees?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []

        draftManager.addDraft(
            callId: resolvedCallId,
            action: .update,
            summary: arguments.summary ?? "Updated Event",
            startTime: arguments.startTime,
            endTime: arguments.endTime,
            location: arguments.location,
            description: arguments.description,
            attendees: attendeeList,
            eventId: arguments.eventId,
            serverCardId: resolvedCallId
        )

        return Result(confirmed: true, message: "Draft shown to user for confirmation.")
    }
}
