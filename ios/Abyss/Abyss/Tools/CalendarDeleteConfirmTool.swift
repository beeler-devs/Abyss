import Foundation

struct CalendarDeleteConfirmTool: Tool, @unchecked Sendable {
    static let name = "calendar.delete.confirm"

    struct Arguments: Codable, Sendable {
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
        let callId = UUID().uuidString
        do {
            let confirmed = try await draftManager.requestConfirmation(
                callId: callId,
                action: .delete,
                summary: arguments.summary ?? "Event",
                startTime: nil,
                endTime: nil,
                location: nil,
                description: nil,
                attendees: [],
                eventId: arguments.eventId,
                anchorMessageID: nil
            )
            return Result(confirmed: confirmed, message: "User confirmed. Event deleted.")
        } catch is CalendarDraftManager.DraftError {
            return Result(confirmed: false, message: "User cancelled event deletion.")
        }
    }
}
