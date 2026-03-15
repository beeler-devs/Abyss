import Foundation

@MainActor
final class EmailDraftManager: ObservableObject {

    enum DraftError: LocalizedError {
        case cancelled
        case timeout

        var errorDescription: String? {
            switch self {
            case .cancelled: return "User cancelled the email."
            case .timeout: return "Email confirmation timed out."
            }
        }
    }

    @Published private(set) var activeDrafts: [EmailDraftCard] = []

    private var pendingContinuations: [String: CheckedContinuation<Bool, Error>] = [:]

    func requestConfirmation(
        callId: String,
        to: String,
        cc: String?,
        subject: String,
        body: String,
        messageId: String?,
        anchorMessageID: UUID?
    ) async throws -> Bool {
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

        let confirmed = try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuations[callId] = continuation
        }

        // After user confirms, mark as sending then auto-transition to sent
        // (the server will actually send the email when it receives confirmed=true)
        if confirmed, let index = activeDrafts.firstIndex(where: { $0.callId == callId }) {
            activeDrafts[index].sendState = .sent
            // Auto-dismiss after a short delay
            let capturedCallId = callId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.activeDrafts.removeAll { $0.callId == capturedCallId }
            }
        }

        return confirmed
    }

    func confirmSend(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].sendState = .sending

        if let continuation = pendingContinuations.removeValue(forKey: callId) {
            continuation.resume(returning: true)
        }
    }

    func cancelDraft(callId: String) {
        if let continuation = pendingContinuations.removeValue(forKey: callId) {
            continuation.resume(throwing: DraftError.cancelled)
        }
        activeDrafts.removeAll { $0.callId == callId }
    }
}
