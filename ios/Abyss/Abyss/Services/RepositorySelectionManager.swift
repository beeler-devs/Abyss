import Foundation

/// Manages pending repository selection requests, bridging tool execution with UI interaction.
@MainActor
final class RepositorySelectionManager: ObservableObject {

    enum SelectionError: LocalizedError {
        case cancelled
        case timeout
        case noRepositories

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Repository selection was cancelled by the user."
            case .timeout: return "Repository selection timed out."
            case .noRepositories: return "No repositories available to select from."
            }
        }
    }

    /// Currently displayed selection card (nil when no selection is pending)
    @Published private(set) var activeCard: RepositorySelectionCard?

    /// Pending continuation waiting for user selection
    private var pendingContinuation: CheckedContinuation<RepositorySelectionCard.Repository, Error>?
    private var pendingCallId: String?

    /// Request user selection from the given repositories.
    /// This suspends until the user selects a repository or cancels.
    func requestSelection(
        callId: String,
        repositories: [RepositorySelectionCard.Repository],
        prompt: String?,
        filter: String?
    ) async throws -> RepositorySelectionCard.Repository {

        guard !repositories.isEmpty else {
            throw SelectionError.noRepositories
        }

        // Filter repositories if filter is provided
        let filteredRepos: [RepositorySelectionCard.Repository]
        if let filter = filter?.lowercased(), !filter.isEmpty {
            filteredRepos = repositories.filter {
                $0.name.lowercased().contains(filter) ||
                $0.owner.lowercased().contains(filter) ||
                $0.repository.lowercased().contains(filter)
            }
        } else {
            filteredRepos = repositories
        }

        guard !filteredRepos.isEmpty else {
            throw SelectionError.noRepositories
        }

        // Create and publish the selection card
        let card = RepositorySelectionCard(
            id: UUID(),
            callId: callId,
            repositories: filteredRepos,
            prompt: prompt,
            filter: filter,
            createdAt: Date()
        )

        activeCard = card
        pendingCallId = callId

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
        }
    }

    /// Complete the selection with the user's choice.
    func completeSelection(repository: RepositorySelectionCard.Repository) {
        guard let continuation = pendingContinuation else { return }

        pendingContinuation = nil
        pendingCallId = nil
        activeCard = nil

        continuation.resume(returning: repository)
    }

    /// Cancel the pending selection (user dismissed the card).
    func cancelSelection() {
        guard let continuation = pendingContinuation else { return }

        pendingContinuation = nil
        pendingCallId = nil
        activeCard = nil

        continuation.resume(throwing: SelectionError.cancelled)
    }

    /// Check if there's a pending selection for the given callId.
    func hasPendingSelection(callId: String) -> Bool {
        pendingCallId == callId
    }
}
