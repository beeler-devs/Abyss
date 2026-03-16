import Foundation

@MainActor
final class EmailDraftManager: ObservableObject {

    @Published var activeDrafts: [EmailDraftCard] = []

    /// Add a draft card without blocking. Returns immediately.
    func addDraft(
        callId: String,
        to: String,
        cc: String?,
        subject: String,
        body: String,
        messageId: String?,
        anchorMessageID: UUID?
    ) {
        let card = EmailDraftCard(
            callId: callId,
            to: to,
            cc: cc,
            subject: subject,
            body: body,
            messageId: messageId,
            anchorMessageID: anchorMessageID
        )
        activeDrafts.append(card)
    }

    /// Mark draft as sending and return the card's current (potentially edited) values.
    func confirmSend(callId: String) -> EmailDraftCard? {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return nil }
        activeDrafts[index].sendState = .sending
        return activeDrafts[index]
    }

    func updateDraft(callId: String, to: String, subject: String, body: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].to = to
        activeDrafts[index].subject = subject
        activeDrafts[index].body = body
    }

    func cancelDraft(callId: String) {
        if let index = activeDrafts.firstIndex(where: { $0.callId == callId }) {
            activeDrafts[index].sendState = .cancelled
        }
        let capturedCallId = callId
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.activeDrafts.removeAll { $0.callId == capturedCallId }
        }
    }

    /// Called when the server reports send success.
    func markSent(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].sendState = .sent
        let capturedCallId = callId
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.activeDrafts.removeAll { $0.callId == capturedCallId }
        }
    }

    /// Called when the server reports send failure.
    func markFailed(callId: String, error: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].sendState = .failed(error)
    }
}
