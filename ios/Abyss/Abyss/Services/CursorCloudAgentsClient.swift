import Foundation

/// Shared request/response types for Cursor Cloud Agents endpoints.
struct CursorAgent: Codable, Sendable {
    struct Source: Codable, Sendable {
        let repository: String?
        let ref: String?
    }

    struct Target: Codable, Sendable {
        let branchName: String?
        let url: String?
        let prUrl: String?
        let autoCreatePr: Bool?
        let openAsCursorGithubApp: Bool?
        let skipReviewerRequest: Bool?
    }

    let id: String
    let name: String?
    let status: String
    let source: Source?
    let target: Target?
    let summary: String?
    let createdAt: String?
}

struct CursorListAgentsResponse: Codable, Sendable {
    let agents: [CursorAgent]
    let nextCursor: String?
}

struct CursorIDOnlyResponse: Codable, Sendable {
    let id: String
}

struct CursorAPIKeyInfo: Codable, Sendable {
    let apiKeyName: String?
    let createdAt: String?
    let userEmail: String?
}

struct CursorModelsResponse: Codable, Sendable {
    let models: [String]
}

struct CursorRepositoriesResponse: Codable, Sendable {
    struct Repository: Codable, Sendable {
        let owner: String
        let name: String
        let repository: String
    }

    let repositories: [Repository]
}

struct CursorLaunchAgentRequest: Encodable, Sendable {
    struct PromptPayload: Encodable, Sendable {
        struct ImagePayload: Encodable, Sendable {
            struct Dimension: Encodable, Sendable {
                let width: Int
                let height: Int
            }

            let data: String
            let dimension: Dimension
        }

        let text: String
        let images: [ImagePayload]?
    }

    struct SourcePayload: Encodable, Sendable {
        let repository: String?
        let ref: String?
        let prUrl: String?

        init(repository: String? = nil, ref: String? = nil, prUrl: String? = nil) {
            self.repository = repository
            self.ref = ref
            self.prUrl = prUrl
        }
    }

    struct TargetPayload: Encodable, Sendable {
        let autoCreatePr: Bool?
        let openAsCursorGithubApp: Bool?
        let skipReviewerRequest: Bool?
        let branchName: String?
        let autoBranch: Bool?
    }

    let prompt: PromptPayload
    let model: String?
    let source: SourcePayload
    let target: TargetPayload?
}

struct CursorFollowUpRequest: Encodable, Sendable {
    let prompt: CursorLaunchAgentRequest.PromptPayload
}

protocol CursorCloudAgentsProviding: Sendable {
    func listAgents(limit: Int?, cursor: String?, prURL: String?) async throws -> CursorListAgentsResponse
    func agentStatus(id: String) async throws -> CursorAgent
    func launchAgent(request: CursorLaunchAgentRequest) async throws -> CursorAgent
    func addFollowUp(agentID: String, prompt: CursorFollowUpRequest) async throws -> CursorIDOnlyResponse
    func stopAgent(id: String) async throws -> CursorIDOnlyResponse
    func deleteAgent(id: String) async throws -> CursorIDOnlyResponse
    func apiKeyInfo() async throws -> CursorAPIKeyInfo
    func models() async throws -> CursorModelsResponse
    func repositories() async throws -> CursorRepositoriesResponse
}

final class CursorCloudAgentsClient: CursorCloudAgentsProviding, @unchecked Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.cursor.com")

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listAgents(limit: Int?, cursor: String?, prURL: String?) async throws -> CursorListAgentsResponse {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let prURL, !prURL.isEmpty {
            queryItems.append(URLQueryItem(name: "prUrl", value: prURL))
        }

        let data = try await requestData(
            method: "GET",
            path: "/v0/agents",
            queryItems: queryItems,
            body: nil as Data?
        )
        return try decode(CursorListAgentsResponse.self, from: data)
    }

    func agentStatus(id: String) async throws -> CursorAgent {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw CursorAPIError.invalidArgument("Agent ID is required")
        }

        let data = try await requestData(method: "GET", path: "/v0/agents/\(normalizedID)", body: nil as Data?)
        return try decode(CursorAgent.self, from: data)
    }

    func launchAgent(request: CursorLaunchAgentRequest) async throws -> CursorAgent {
        let body = try JSONEncoder().encode(request)
        let data = try await requestData(method: "POST", path: "/v0/agents", body: body)
        return try decode(CursorAgent.self, from: data)
    }

    func addFollowUp(agentID: String, prompt: CursorFollowUpRequest) async throws -> CursorIDOnlyResponse {
        let normalizedID = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw CursorAPIError.invalidArgument("Agent ID is required")
        }

        let body = try JSONEncoder().encode(prompt)
        let data = try await requestData(method: "POST", path: "/v0/agents/\(normalizedID)/followup", body: body)
        return try decode(CursorIDOnlyResponse.self, from: data)
    }

    func stopAgent(id: String) async throws -> CursorIDOnlyResponse {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw CursorAPIError.invalidArgument("Agent ID is required")
        }

        let data = try await requestData(method: "POST", path: "/v0/agents/\(normalizedID)/stop", body: nil as Data?)
        return try decode(CursorIDOnlyResponse.self, from: data)
    }

    func deleteAgent(id: String) async throws -> CursorIDOnlyResponse {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw CursorAPIError.invalidArgument("Agent ID is required")
        }

        let data = try await requestData(method: "DELETE", path: "/v0/agents/\(normalizedID)", body: nil as Data?)
        return try decode(CursorIDOnlyResponse.self, from: data)
    }

    func apiKeyInfo() async throws -> CursorAPIKeyInfo {
        let data = try await requestData(method: "GET", path: "/v0/me", body: nil as Data?)
        return try decode(CursorAPIKeyInfo.self, from: data)
    }

    func models() async throws -> CursorModelsResponse {
        let data = try await requestData(method: "GET", path: "/v0/models", body: nil as Data?)
        return try decode(CursorModelsResponse.self, from: data)
    }

    func repositories() async throws -> CursorRepositoriesResponse {
        let data = try await requestData(method: "GET", path: "/v0/repositories", body: nil as Data?)
        return try decode(CursorRepositoriesResponse.self, from: data)
    }

    private func requestData(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data?
    ) async throws -> Data {
        let apiKey = try configuredAPIKey()
        var request = try buildRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            apiKey: apiKey,
            body: body
        )

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CursorAPIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let serverMessage: String?
            if let decoded = try? JSONDecoder().decode(CursorErrorPayload.self, from: data) {
                serverMessage = decoded.error ?? decoded.message
            } else {
                serverMessage = String(data: data, encoding: .utf8)
            }
            throw CursorAPIError.httpError(code: http.statusCode, message: serverMessage)
        }

        return data
    }

    private func configuredAPIKey() throws -> String {
        guard let key = Config.cursorAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw CursorAPIError.missingAPIKey
        }
        return key
    }

    private func buildRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        apiKey: String,
        body: Data?
    ) throws -> URLRequest {
        guard let baseURL else {
            throw CursorAPIError.invalidURL
        }

        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let url = components?.url else {
            throw CursorAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Basic \(basicAuthToken(apiKey: apiKey))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func basicAuthToken(apiKey: String) -> String {
        let raw = "\(apiKey):"
        return Data(raw.utf8).base64EncodedString()
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CursorAPIError.decodingFailed(error.localizedDescription)
        }
    }
}

private struct CursorErrorPayload: Decodable {
    let error: String?
    let message: String?
}

enum CursorAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidResponse
    case httpError(code: Int, message: String?)
    case invalidArgument(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Cursor API key is not configured. Add it in Settings."
        case .invalidURL:
            return "Invalid Cursor API URL."
        case .invalidResponse:
            return "Invalid response from Cursor API."
        case .httpError(let code, let message):
            if let message, !message.isEmpty {
                return "Cursor API error \(code): \(message)"
            }
            return "Cursor API error \(code)."
        case .invalidArgument(let message):
            return message
        case .decodingFailed(let message):
            return "Failed to parse Cursor API response: \(message)"
        }
    }
}
