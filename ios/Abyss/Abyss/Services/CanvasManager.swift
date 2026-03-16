import Foundation
import Security

@MainActor
final class CanvasManager: ObservableObject {
    @Published var isConnected: Bool = false

    private static let keychainService = "app.abyss.canvas"
    private static let tokenAccount = "canvas_access_token"
    private static let baseURLAccount = "canvas_base_url"

    static let defaultBaseURL = "https://canvas.cmu.edu"

    init() {
        isConnected = (Self.loadAccessToken() != nil)
    }

    // MARK: - Public API

    func connect(token: String, baseURL: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }

        Self.saveKeychainString(trimmedToken, account: Self.tokenAccount)
        let urlToSave = trimmedURL.isEmpty ? Self.defaultBaseURL : trimmedURL
        Self.saveKeychainString(urlToSave, account: Self.baseURLAccount)
        isConnected = true
    }

    func disconnect() {
        Self.deleteToken(account: Self.tokenAccount)
        Self.deleteToken(account: Self.baseURLAccount)
        isConnected = false
    }

    // MARK: - Static Accessors

    static func loadAccessToken() -> String? {
        loadKeychainString(account: tokenAccount)
    }

    static func loadBaseURL() -> String? {
        loadKeychainString(account: baseURLAccount) ?? defaultBaseURL
    }

    // MARK: - Keychain

    private static func saveKeychainString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        deleteToken(account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadKeychainString(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func deleteToken(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
