import Foundation

struct CalendarUpdateConfirmTool: Tool, @unchecked Sendable {
    static let name = "calendar.update.confirm"

    struct Arguments: Codable, Sendable {
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
        let callId = UUID().uuidString
        let attendeeList = arguments.attendees?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        do {
            let confirmed = try await draftManager.requestConfirmation(
                callId: callId,
                action: .update,
                summary: arguments.summary ?? "Updated Event",
                startTime: arguments.startTime,
                endTime: arguments.endTime,
                location: arguments.location,
                description: arguments.description,
                attendees: attendeeList,
                eventId: arguments.eventId,
                anchorMessageID: nil
            )
            return Result(confirmed: confirmed, message: "User confirmed. Event updated.")
        } catch is CalendarDraftManager.DraftError {
            return Result(confirmed: false, message: "User cancelled event update.")
        }
    }
}
