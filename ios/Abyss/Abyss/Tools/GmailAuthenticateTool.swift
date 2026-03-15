import Foundation

/// Tool: gmail.authenticate
/// Triggers the Gmail OAuth flow so the user can connect their account.
struct GmailAuthenticateTool: Tool, @unchecked Sendable {
    static let name = "gmail.authenticate"

    struct Arguments: Codable, Sendable {}

    struct Result: Codable, Sendable {
        let authenticated: Bool
        let message: String
    }

    private let authManager: GmailAuthManager
    private let onAuthenticated: @MainActor @Sendable () async -> Void

    init(authManager: GmailAuthManager, onAuthenticated: @escaping @MainActor @Sendable () async -> Void) {
        self.authManager = authManager
        self.onAuthenticated = onAuthenticated
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        if authManager.isAuthenticated {
            return Result(authenticated: true, message: "Gmail is already connected.")
        }

        await authManager.authenticate()

        if authManager.isAuthenticated {
            await onAuthenticated()
            return Result(authenticated: true, message: "Gmail connected successfully. Gmail tools are now available.")
        } else {
            let error = authManager.authError ?? "Authentication was cancelled or failed."
            return Result(authenticated: false, message: error)
        }
    }
}
