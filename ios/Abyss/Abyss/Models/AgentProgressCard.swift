import Foundation

/// UI-facing model for tracking Cursor Cloud Agent progress.
struct AgentProgressCard: Identifiable, Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        enum State: Sendable {
            case complete
            case active
            case pending
            case failed
        }

        let id: String
        let text: String
        let state: State
    }

    let id: UUID
    let spawnCallId: String

    var agentId: String?
    var title: String
    var repository: String?
    var prompt: String
    var status: String
    var summary: String
    var branchName: String?
    var agentURL: String?
    var prURL: String?
    var autoCreatePR: Bool
    var createdAt: String?
    var updatedAt: Date
    var errorMessage: String?

    static func pending(
        spawnCallId: String,
        prompt: String,
        repository: String?,
        autoCreatePR: Bool
    ) -> AgentProgressCard {
        let repoTitle = shortRepositoryName(from: repository)
        return AgentProgressCard(
            id: UUID(),
            spawnCallId: spawnCallId,
            agentId: nil,
            title: repoTitle ?? "Cursor Cloud Agent",
            repository: repository,
            prompt: prompt,
            status: "CREATING",
            summary: "Submitting request to Cursor Cloud...",
            branchName: nil,
            agentURL: nil,
            prURL: nil,
            autoCreatePR: autoCreatePR,
            createdAt: nil,
            updatedAt: Date(),
            errorMessage: nil
        )
    }

    mutating func applySpawnResult(_ result: AgentSpawnTool.Result) {
        agentId = result.id
        status = result.status
        title = (result.name?.isEmpty == false) ? (result.name ?? title) : title
        branchName = result.branchName
        agentURL = result.url
        prURL = result.prUrl
        createdAt = result.createdAt
        summary = summaryTextForStatus(currentSummary: summary)
        errorMessage = nil
        updatedAt = Date()
    }

    mutating func applyStatusResult(_ result: AgentStatusTool.Result) {
        agentId = result.id
        status = result.status

        if let name = result.name, !name.isEmpty {
            title = name
        }

        if let summary = result.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.summary = summary
        } else {
            summary = summaryTextForStatus(currentSummary: summary)
        }

        branchName = result.branchName ?? branchName
        agentURL = result.url ?? agentURL
        prURL = result.prUrl ?? prURL
        createdAt = result.createdAt ?? createdAt

        if normalizedStatus == "FINISHED" {
            errorMessage = nil
        }

        updatedAt = Date()
    }

    mutating func applyCancelled(agentID: String) {
        agentId = agentID
        status = "STOPPED"
        summary = "Agent stopped by user."
        errorMessage = nil
        updatedAt = Date()
    }

    mutating func applySpawnError(_ message: String) {
        status = "FAILED"
        summary = "Could not start Cursor Cloud Agent."
        errorMessage = message
        updatedAt = Date()
    }

    mutating func noteStatusRefreshError(_ message: String) {
        summary = "Status refresh failed: \(message)"
        updatedAt = Date()
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var isTerminal: Bool {
        ["FINISHED", "FAILED", "STOPPED", "CANCELLED"].contains(normalizedStatus)
    }

    var progress: Double {
        switch normalizedStatus {
        case "CREATING":
            return 0.2
        case "RUNNING":
            return 0.6
        case "FINISHED", "FAILED", "STOPPED", "CANCELLED":
            return 1.0
        default:
            return 0.1
        }
    }

    var statusLabel: String {
        if let errorMessage, !errorMessage.isEmpty {
            return "Failed"
        }

        switch normalizedStatus {
        case "CREATING": return "Creating"
        case "RUNNING": return "Running"
        case "FINISHED": return "Finished"
        case "FAILED": return "Failed"
        case "STOPPED", "CANCELLED": return "Stopped"
        default: return normalizedStatus.isEmpty ? "Pending" : normalizedStatus
        }
    }

    var steps: [Step] {
        let step3Text = autoCreatePR ? "Creating pull request" : "Preparing summary"

        switch normalizedStatus {
        case "CREATING":
            return [
                Step(id: "accepted", text: "Agent request accepted", state: .active),
                Step(id: "working", text: "Working on repository", state: .pending),
                Step(id: "result", text: step3Text, state: .pending),
            ]
        case "RUNNING":
            return [
                Step(id: "accepted", text: "Agent request accepted", state: .complete),
                Step(id: "working", text: "Working on repository", state: .active),
                Step(id: "result", text: step3Text, state: .pending),
            ]
        case "FINISHED":
            return [
                Step(id: "accepted", text: "Agent request accepted", state: .complete),
                Step(id: "working", text: "Working on repository", state: .complete),
                Step(id: "result", text: step3Text, state: .complete),
            ]
        case "FAILED":
            return [
                Step(id: "accepted", text: "Agent request accepted", state: .complete),
                Step(id: "working", text: "Working on repository", state: .failed),
                Step(id: "result", text: step3Text, state: .pending),
            ]
        case "STOPPED", "CANCELLED":
            return [
                Step(id: "accepted", text: "Agent request accepted", state: .complete),
                Step(id: "working", text: "Working on repository", state: .failed),
                Step(id: "result", text: step3Text, state: .pending),
            ]
        default:
            return [
                Step(id: "accepted", text: "Agent request accepted", state: .pending),
                Step(id: "working", text: "Working on repository", state: .pending),
                Step(id: "result", text: step3Text, state: .pending),
            ]
        }
    }

    private func summaryTextForStatus(currentSummary: String) -> String {
        if !currentSummary.isEmpty,
           !currentSummary.lowercased().contains("submitting request") {
            return currentSummary
        }

        switch normalizedStatus {
        case "CREATING":
            return "Cursor is setting up the cloud agent."
        case "RUNNING":
            return "Agent is currently working on the requested task."
        case "FINISHED":
            return "Agent finished successfully."
        case "FAILED":
            return "Agent failed. Check details in timeline or status output."
        case "STOPPED", "CANCELLED":
            return "Agent was stopped before completion."
        default:
            return "Waiting for status updates..."
        }
    }

    static func shortRepositoryName(from repository: String?) -> String? {
        guard let repository, let url = URL(string: repository) else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count >= 2 else { return nil }
        return "\(comps[comps.count - 2])/\(comps[comps.count - 1])"
    }
}
