import Foundation

/// Tool: canvas.authenticate
/// Prompts the user to connect their Canvas LMS account via Settings.
struct CanvasAuthenticateTool: Tool, @unchecked Sendable {
    static let name = "canvas.authenticate"

    struct Arguments: Codable, Sendable {}

    struct Result: Codable, Sendable {
        let authenticated: Bool
        let message: String
    }

    private let canvasManager: CanvasManager
    private let onAuthenticated: @MainActor @Sendable () async -> Void

    init(canvasManager: CanvasManager, onAuthenticated: @escaping @MainActor @Sendable () async -> Void) {
        self.canvasManager = canvasManager
        self.onAuthenticated = onAuthenticated
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        if canvasManager.isConnected {
            return Result(authenticated: true, message: "Canvas is already connected.")
        }

        return Result(
            authenticated: false,
            message: "Canvas is not connected. The user has been directed to Settings → Connections → Canvas to enter their personal access token. Do NOT call canvas.authenticate again — wait for the user to complete setup and ask again later."
        )
    }
}
