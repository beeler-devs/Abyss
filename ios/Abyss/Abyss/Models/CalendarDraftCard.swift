import Foundation

enum CalendarDraftAction: String, Equatable, Sendable {
    case create
    case update
    case delete
}

enum CalendarDraftState: Equatable, Sendable {
    case pending
    case confirming
    case confirmed
    case cancelled
    case failed(String)
}

struct CalendarDraftCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let callId: String
    let action: CalendarDraftAction
    let summary: String
    let startTime: String?
    let endTime: String?
    let location: String?
    let description: String?
    let attendees: [String]
    let eventId: String?
    var state: CalendarDraftState
    var serverCardId: String?

    init(
        id: UUID = UUID(),
        callId: String,
        action: CalendarDraftAction,
        summary: String,
        startTime: String? = nil,
        endTime: String? = nil,
        location: String? = nil,
        description: String? = nil,
        attendees: [String] = [],
        eventId: String? = nil,
        state: CalendarDraftState = .pending,
        serverCardId: String? = nil
    ) {
        self.id = id
        self.callId = callId
        self.action = action
        self.summary = summary
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.description = description
        self.attendees = attendees
        self.eventId = eventId
        self.state = state
        self.serverCardId = serverCardId
    }
}
