import Foundation

/// Tool: repositories.select
/// Presents an interactive repository selection UI and returns the user's choice.
struct RepositoriesSelectTool: Tool, @unchecked Sendable {
    static let name = "repositories.select"

    struct Arguments: Codable, Sendable {
        let prompt: String?
        let filter: String?
    }

    struct Result: Codable, Sendable {
        let repository: String  // "owner/name" format
        let owner: String
        let name: String
        let selected: Bool  // Always true on success, for clarity in model response
    }

    private let client: CursorCloudAgentsProviding
    private let selectionManager: RepositorySelectionManager

    init(
        client: CursorCloudAgentsProviding,
        selectionManager: RepositorySelectionManager
    ) {
        self.client = client
        self.selectionManager = selectionManager
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        // 1. Fetch repositories from Cursor API
        let response = try await client.repositories()

        guard !response.repositories.isEmpty else {
            throw RepositorySelectionManager.SelectionError.noRepositories
        }

        // 2. Convert to selection card format
        let repos = response.repositories.map { repo in
            RepositorySelectionCard.Repository(
                repository: repo.repository,
                owner: repo.owner,
                name: repo.name
            )
        }

        // 3. Request selection from user (this suspends until selection)
        let callId = UUID().uuidString
        let selected = try await selectionManager.requestSelection(
            callId: callId,
            repositories: repos,
            prompt: arguments.prompt,
            filter: arguments.filter
        )

        // 4. Return the selected repository
        return Result(
            repository: selected.repository,
            owner: selected.owner,
            name: selected.name,
            selected: true
        )
    }
}
