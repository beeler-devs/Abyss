import Foundation

@MainActor
final class CalendarDraftManager: ObservableObject {

    @Published private(set) var activeDrafts: [CalendarDraftCard] = []

    /// Add a draft card (non-blocking). Returns immediately.
    func addDraft(
        callId: String,
        action: CalendarDraftAction,
        summary: String,
        startTime: String?,
        endTime: String?,
        location: String?,
        description: String?,
        attendees: [String],
        eventId: String?,
        serverCardId: String?
    ) {
        let card = CalendarDraftCard(
            callId: callId,
            action: action,
            summary: summary,
            startTime: startTime,
            endTime: endTime,
            location: location,
            description: description,
            attendees: attendees,
            eventId: eventId,
            serverCardId: serverCardId ?? callId
        )
        activeDrafts.append(card)
    }

    func confirm(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].state = .confirming
    }

    func cancel(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].state = .cancelled
    }

    func markConfirmed(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].state = .confirmed
    }

    func markFailed(callId: String, error: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].state = .failed(error)
    }
}
