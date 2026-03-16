import Foundation

/// Tool: preferences.set
/// Allows the LLM to persist user preferences (name, timezone, style, etc.)
struct PreferencesSetTool: Tool, @unchecked Sendable {
    static let name = "preferences.set"

    struct Arguments: Codable, Sendable {
        let key: String
        let value: String
    }

    struct Result: Codable, Sendable {
        let success: Bool
        let key: String
        let value: String
    }

    private let store: UserPreferencesStore
    private let onUpdate: @MainActor @Sendable ([String: String]) async -> Void

    init(store: UserPreferencesStore, onUpdate: @escaping @MainActor @Sendable ([String: String]) async -> Void) {
        self.store = store
        self.onUpdate = onUpdate
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        store.set(key: arguments.key, value: arguments.value)
        await onUpdate(store.getAll())
        return Result(success: true, key: arguments.key, value: arguments.value)
    }
}
