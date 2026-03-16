import Foundation

/// Tool: preferences.get
/// Allows the LLM to read all stored user preferences.
struct PreferencesGetTool: Tool, @unchecked Sendable {
    static let name = "preferences.get"

    struct Arguments: Codable, Sendable {}

    struct Result: Codable, Sendable {
        let preferences: [String: String]
    }

    private let store: UserPreferencesStore

    init(store: UserPreferencesStore) {
        self.store = store
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        Result(preferences: store.getAll())
    }
}
