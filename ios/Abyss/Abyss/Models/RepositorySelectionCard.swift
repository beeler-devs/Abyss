import Foundation

/// Model for presenting a repository selection UI to the user.
struct RepositorySelectionCard: Identifiable, Equatable, Sendable {
    struct Repository: Identifiable, Equatable, Sendable, Codable {
        var id: String { repository }
        let repository: String  // "owner/name" format
        let owner: String
        let name: String
    }

    let id: UUID
    let callId: String  // Links back to the tool call for result routing
    let repositories: [Repository]
    let prompt: String?  // Optional context message from the model
    let filter: String?  // Optional filter applied
    let createdAt: Date

    /// Repositories grouped by owner, sorted alphabetically.
    var groupedByOwner: [(owner: String, repos: [Repository])] {
        let grouped = Dictionary(grouping: repositories, by: { $0.owner })
        return grouped.keys.sorted().map { owner in
            (owner: owner, repos: grouped[owner]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    /// Total count of repositories
    var repositoryCount: Int { repositories.count }

    /// Count of unique owners/organizations
    var ownerCount: Int { Set(repositories.map(\.owner)).count }
}
