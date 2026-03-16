import Foundation

@MainActor
final class EmailDraftManager: ObservableObject {

    @Published var activeDrafts: [EmailDraftCard] = []

    /// Add a draft card (non-blocking). Returns immediately.
    func addDraft(
        callId: String,
        to: String,
        cc: String?,
        subject: String,
        body: String,
        messageId: String?
    ) {
        let card = EmailDraftCard(
            callId: callId,
            to: to,
            cc: cc,
            subject: subject,
            body: body,
            messageId: messageId,
            serverCardId: callId
        )
        activeDrafts.append(card)
    }

    /// Persists edited values and transitions to .sending state.
    func confirmSend(callId: String, to: String, subject: String, body: String) -> EmailDraftCard? {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return nil }
        activeDrafts[index].to = to
        activeDrafts[index].subject = subject
        activeDrafts[index].body = body
        activeDrafts[index].sendState = .sending
        return activeDrafts[index]
    }

    func cancelDraft(callId: String) {
        if let index = activeDrafts.firstIndex(where: { $0.callId == callId }) {
            activeDrafts[index].sendState = .cancelled
        }
    }

    func markSent(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].sendState = .sent
    }

    func markFailed(callId: String, error: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].sendState = .failed(error)
    }
}
