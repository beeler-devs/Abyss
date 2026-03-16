import Foundation

struct CalendarEventCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let eventId: String
    let summary: String
    let startTime: String
    let endTime: String
    let location: String?
    let description: String?
    let attendees: [String]
    let htmlLink: String?
    let isAllDay: Bool
    var isExpanded: Bool
    var anchorMessageID: UUID?

    init(
        id: UUID = UUID(),
        eventId: String,
        summary: String,
        startTime: String,
        endTime: String,
        location: String? = nil,
        description: String? = nil,
        attendees: [String] = [],
        htmlLink: String? = nil,
        isAllDay: Bool = false,
        isExpanded: Bool = false,
        anchorMessageID: UUID? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.summary = summary
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.description = description
        self.attendees = attendees
        self.htmlLink = htmlLink
        self.isAllDay = isAllDay
        self.isExpanded = isExpanded
        self.anchorMessageID = anchorMessageID
    }
}
