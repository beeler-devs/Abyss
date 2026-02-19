import Foundation

/// Tool: agent.spawn
/// Launches a new Cursor Cloud Agent.
struct AgentSpawnTool: Tool, @unchecked Sendable {
    static let name = "agent.spawn"

    struct Arguments: Codable, Sendable {
        let prompt: String
        let repository: String?
        let ref: String?
        let prUrl: String?
        let model: String?
        let autoCreatePr: Bool?
        let openAsCursorGithubApp: Bool?
        let skipReviewerRequest: Bool?
        let branchName: String?
        let autoBranch: Bool?
    }

    struct Result: Codable, Sendable {
        let id: String
        let name: String?
        let status: String
        let url: String?
        let prUrl: String?
        let branchName: String?
        let createdAt: String?
    }

    private let client: CursorCloudAgentsProviding

    init(client: CursorCloudAgentsProviding) {
        self.client = client
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let promptText = arguments.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else {
            throw CursorAPIError.invalidArgument("Prompt is required")
        }

        let repository = arguments.repository?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prUrl = arguments.prUrl?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (repository?.isEmpty == false) || (prUrl?.isEmpty == false) else {
            throw CursorAPIError.invalidArgument("Either repository or prUrl is required")
        }

        let source = CursorLaunchAgentRequest.SourcePayload(
            repository: repository,
            ref: arguments.ref,
            prUrl: prUrl
        )

        let hasTargetConfig = arguments.autoCreatePr != nil
            || arguments.openAsCursorGithubApp != nil
            || arguments.skipReviewerRequest != nil
            || arguments.branchName?.isEmpty == false
            || arguments.autoBranch != nil

        let target: CursorLaunchAgentRequest.TargetPayload? = hasTargetConfig
            ? CursorLaunchAgentRequest.TargetPayload(
                autoCreatePr: arguments.autoCreatePr,
                openAsCursorGithubApp: arguments.openAsCursorGithubApp,
                skipReviewerRequest: arguments.skipReviewerRequest,
                branchName: arguments.branchName,
                autoBranch: arguments.autoBranch
            )
            : nil

        let request = CursorLaunchAgentRequest(
            prompt: .init(text: promptText, images: nil),
            model: arguments.model,
            source: source,
            target: target
        )

        let launched = try await client.launchAgent(request: request)

        return Result(
            id: launched.id,
            name: launched.name,
            status: launched.status,
            url: launched.target?.url,
            prUrl: launched.target?.prUrl,
            branchName: launched.target?.branchName,
            createdAt: launched.createdAt
        )
    }
}

/// Tool: agent.status
/// Retrieves status for a Cursor Cloud Agent by ID.
struct AgentStatusTool: Tool, @unchecked Sendable {
    static let name = "agent.status"

    struct Arguments: Codable, Sendable {
        let id: String
    }

    struct Result: Codable, Sendable {
        let id: String
        let name: String?
        let status: String
        let summary: String?
        let url: String?
        let prUrl: String?
        let branchName: String?
        let createdAt: String?
    }

    private let client: CursorCloudAgentsProviding

    init(client: CursorCloudAgentsProviding) {
        self.client = client
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let agent = try await client.agentStatus(id: arguments.id)

        return Result(
            id: agent.id,
            name: agent.name,
            status: agent.status,
            summary: agent.summary,
            url: agent.target?.url,
            prUrl: agent.target?.prUrl,
            branchName: agent.target?.branchName,
            createdAt: agent.createdAt
        )
    }
}

/// Tool: agent.cancel
/// Stops a currently running Cursor Cloud Agent.
struct AgentCancelTool: Tool, @unchecked Sendable {
    static let name = "agent.cancel"

    struct Arguments: Codable, Sendable {
        let id: String
    }

    struct Result: Codable, Sendable {
        let id: String
        let cancelled: Bool
    }

    private let client: CursorCloudAgentsProviding

    init(client: CursorCloudAgentsProviding) {
        self.client = client
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let response = try await client.stopAgent(id: arguments.id)
        return Result(id: response.id, cancelled: true)
    }
}

/// Tool: agent.followup
/// Adds a follow-up instruction to an existing Cursor Cloud Agent.
struct AgentFollowUpTool: Tool, @unchecked Sendable {
    static let name = "agent.followup"

    struct Arguments: Codable, Sendable {
        let id: String
        let prompt: String
    }

    struct Result: Codable, Sendable {
        let id: String
        let accepted: Bool
    }

    private let client: CursorCloudAgentsProviding

    init(client: CursorCloudAgentsProviding) {
        self.client = client
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let promptText = arguments.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else {
            throw CursorAPIError.invalidArgument("Follow-up prompt is required")
        }

        let response = try await client.addFollowUp(
            agentID: arguments.id,
            prompt: CursorFollowUpRequest(prompt: .init(text: promptText, images: nil))
        )
        return Result(id: response.id, accepted: true)
    }
}

/// Tool: repositories.list
/// Lists GitHub repositories the Cursor GitHub App has access to.
struct RepositoriesListTool: Tool, @unchecked Sendable {
    static let name = "repositories.list"

    struct Arguments: Codable, Sendable {}

    struct Result: Codable, Sendable {
        struct Repository: Codable, Sendable {
            let repository: String
            let owner: String
            let name: String
        }

        let repositories: [Repository]
        let count: Int
    }

    private let client: CursorCloudAgentsProviding

    init(client: CursorCloudAgentsProviding) {
        self.client = client
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let response = try await client.repositories()
        let repos = response.repositories.map {
            Result.Repository(repository: $0.repository, owner: $0.owner, name: $0.name)
        }
        return Result(repositories: repos, count: repos.count)
    }
}

/// Tool: agent.list
/// Lists Cursor Cloud Agents for the authenticated user.
struct AgentListTool: Tool, @unchecked Sendable {
    static let name = "agent.list"

    struct Arguments: Codable, Sendable {
        let limit: Int?
        let cursor: String?
        let prUrl: String?
    }

    struct Result: Codable, Sendable {
        struct AgentSummary: Codable, Sendable {
            let id: String
            let name: String?
            let status: String
            let summary: String?
            let url: String?
            let prUrl: String?
            let branchName: String?
            let createdAt: String?
        }

        let agents: [AgentSummary]
        let nextCursor: String?
    }

    private let client: CursorCloudAgentsProviding

    init(client: CursorCloudAgentsProviding) {
        self.client = client
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        let response = try await client.listAgents(
            limit: arguments.limit,
            cursor: arguments.cursor,
            prURL: arguments.prUrl
        )

        let mapped = response.agents.map {
            Result.AgentSummary(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                summary: $0.summary,
                url: $0.target?.url,
                prUrl: $0.target?.prUrl,
                branchName: $0.target?.branchName,
                createdAt: $0.createdAt
            )
        }

        return Result(agents: mapped, nextCursor: response.nextCursor)
    }
}
