import Foundation

/// UserDefaults-backed key-value store for user preferences.
/// iOS is the source of truth — preferences are sent to the server on connect
/// and synced mid-session when changed.
@MainActor
final class UserPreferencesStore: ObservableObject {
    private static let storageKey = "userPreferences.v1"

    @Published private(set) var preferences: [String: String]

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String]
        self.preferences = stored ?? [:]
    }

    func set(key: String, value: String) {
        preferences[key] = value
        persist()
    }

    func remove(key: String) {
        preferences.removeValue(forKey: key)
        persist()
    }

    func getAll() -> [String: String] {
        preferences
    }

    private func persist() {
        UserDefaults.standard.set(preferences, forKey: Self.storageKey)
    }
}
