import Foundation

@MainActor
final class CalendarDraftManager: ObservableObject {

    enum DraftError: LocalizedError {
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cancelled: return "User cancelled the calendar action."
            }
        }
    }

    @Published private(set) var activeDrafts: [CalendarDraftCard] = []

    private var pendingContinuations: [String: CheckedContinuation<Bool, Error>] = [:]

    func requestConfirmation(
        callId: String,
        action: CalendarDraftAction,
        summary: String,
        startTime: String?,
        endTime: String?,
        location: String?,
        description: String?,
        attendees: [String],
        eventId: String?,
        anchorMessageID: UUID?
    ) async throws -> Bool {
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
            anchorMessageID: anchorMessageID
        )

        activeDrafts.append(card)

        let confirmed = try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuations[callId] = continuation
        }

        if confirmed, let index = activeDrafts.firstIndex(where: { $0.callId == callId }) {
            activeDrafts[index].state = .confirmed
            let capturedCallId = callId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.activeDrafts.removeAll { $0.callId == capturedCallId }
            }
        }

        return confirmed
    }

    func confirm(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].state = .confirming

        if let continuation = pendingContinuations.removeValue(forKey: callId) {
            continuation.resume(returning: true)
        }
    }

    func cancel(callId: String) {
        if let continuation = pendingContinuations.removeValue(forKey: callId) {
            continuation.resume(throwing: DraftError.cancelled)
        }
        activeDrafts.removeAll { $0.callId == callId }
    }
}
