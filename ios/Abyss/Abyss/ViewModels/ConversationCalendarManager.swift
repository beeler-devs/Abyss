import Combine
import Foundation

/// Parses calendar.* tool results into CalendarEventCard models for inline display.
@MainActor
final class ConversationCalendarManager: ObservableObject {
    @Published private(set) var calendarCards: [CalendarEventCard] = []

    private let eventBus: EventBus
    private var pendingToolCalls: [String: Event.ToolCall] = [:]
    private var lastAssistantMessageID: UUID?

    init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    func updateLastAssistantMessageID(_ id: UUID) {
        lastAssistantMessageID = id
    }

    func handleEventStream(_ event: Event) {
        switch event.kind {
        case .toolCall(let toolCall):
            if toolCall.name.hasPrefix("calendar.") {
                pendingToolCalls[toolCall.callId] = toolCall
            }
        case .toolResult(let toolResult):
            guard let toolCall = pendingToolCalls.removeValue(forKey: toolResult.callId) else { return }
            handleCalendarResult(toolResult, for: toolCall)
        default:
            break
        }
    }

    func toggleExpanded(cardId: UUID) {
        guard let index = calendarCards.firstIndex(where: { $0.id == cardId }) else { return }
        calendarCards[index].isExpanded.toggle()
    }

    private func handleCalendarResult(_ result: Event.ToolResult, for toolCall: Event.ToolCall) {
        guard result.error == nil, let json = result.result else { return }
        guard let data = json.data(using: .utf8) else { return }

        switch toolCall.name {
        case "calendar.list":
            parseEventList(data)
        case "calendar.get":
            parseSingleEvent(data)
        default:
            break
        }
    }

    private func parseEventList(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(CalendarListPayload.self, from: data) else { return }
        for event in payload.events {
            guard !calendarCards.contains(where: { $0.eventId == event.eventId }) else { continue }
            calendarCards.append(CalendarEventCard(
                eventId: event.eventId,
                summary: event.summary,
                startTime: event.start,
                endTime: event.end,
                location: event.location,
                description: event.description,
                attendees: event.attendees,
                htmlLink: event.htmlLink,
                isAllDay: event.isAllDay,
                anchorMessageID: lastAssistantMessageID,
                serverCardId: event.cardId
            ))
        }
    }

    private func parseSingleEvent(_ data: Data) {
        guard let event = try? JSONDecoder().decode(CalendarEventPayload.self, from: data) else { return }
        if let index = calendarCards.firstIndex(where: { $0.eventId == event.eventId }) {
            calendarCards[index].isExpanded = true
            if let cardId = event.cardId { calendarCards[index].serverCardId = cardId }
        } else {
            calendarCards.append(CalendarEventCard(
                eventId: event.eventId,
                summary: event.summary,
                startTime: event.start,
                endTime: event.end,
                location: event.location,
                description: event.description,
                attendees: event.attendees,
                htmlLink: event.htmlLink,
                isAllDay: event.isAllDay,
                isExpanded: true,
                anchorMessageID: lastAssistantMessageID,
                serverCardId: event.cardId
            ))
        }
    }
}

// MARK: - Decodable helpers

private struct CalendarListPayload: Decodable {
    let events: [CalendarEventPayload]
}

private struct CalendarEventPayload: Decodable {
    let eventId: String
    let summary: String
    let start: String
    let end: String
    let location: String?
    let description: String?
    let attendees: [String]
    let htmlLink: String?
    let isAllDay: Bool
    let cardId: String?

    private enum CodingKeys: String, CodingKey {
        case eventId, summary, start, end, location, description, attendees, htmlLink, isAllDay, cardId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try container.decode(String.self, forKey: .eventId)
        summary = try container.decode(String.self, forKey: .summary)
        start = try container.decode(String.self, forKey: .start)
        end = try container.decode(String.self, forKey: .end)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        attendees = (try? container.decode([String].self, forKey: .attendees)) ?? []
        htmlLink = try container.decodeIfPresent(String.self, forKey: .htmlLink)
        isAllDay = (try? container.decode(Bool.self, forKey: .isAllDay)) ?? false
        cardId = try container.decodeIfPresent(String.self, forKey: .cardId)
    }
}
