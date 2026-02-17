import Foundation

/// Tool: convo.setState
/// Sets the app-level state (idle, listening, etc).
struct ConvoSetStateTool: Tool {
    static let name = "convo.setState"

    struct Arguments: Codable, Sendable {
        let state: String // AppState raw value
    }

    struct Result: Codable, Sendable {
        let previousState: String
        let newState: String
    }

    private let stateStore: AppStateStore

    init(stateStore: AppStateStore) {
        self.stateStore = stateStore
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        guard let newState = AppState(rawValue: arguments.state) else {
            throw ToolError.executionFailed(Self.name, NSError(
                domain: "ConvoSetState",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid state: \(arguments.state)"]
            ))
        }

        let previous = stateStore.current
        stateStore.current = newState

        return Result(
            previousState: previous.rawValue,
            newState: newState.rawValue
        )
    }
}

/// Shared mutable holder for app state, owned by the ViewModel.
@MainActor
final class AppStateStore: Sendable {
    var current: AppState = .idle
}
