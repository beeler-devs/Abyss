import AuthenticationServices
import Foundation
import Security

@MainActor
final class GitHubAuthManager: NSObject, ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isAuthenticating: Bool = false
    @Published var authError: String? = nil

    private static let keychainService = "app.abyss.github"
    private static let keychainAccount = "github_access_token"

    override init() {
        super.init()
        isAuthenticated = (Self.loadToken() != nil)
    }

    // MARK: - Public API

    var token: String? {
        Self.loadToken()
    }

    func authenticate() async {
        guard !isAuthenticating else { return }
        guard let clientId = Config.githubClientId, !clientId.isEmpty else {
            authError = "GitHub Client ID not configured. Set GITHUB_CLIENT_ID in Secrets.plist."
            return
        }

        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }

        do {
            let code = try await startOAuthFlow(clientId: clientId)
            let accessToken = try await exchangeCode(code)
            Self.saveToken(accessToken)
            isAuthenticated = true
        } catch {
            authError = error.localizedDescription
        }
    }

    func signOut() {
        Self.deleteToken()
        isAuthenticated = false
    }

    // MARK: - OAuth Flow

    private func startOAuthFlow(clientId: String) async throws -> String {
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        let state = UUID().uuidString
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: "abyss://oauth-callback"),
            URLQueryItem(name: "scope", value: "repo read:org read:user"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authURL = components.url else {
            throw AuthError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "abyss"
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: AuthError.missingCode)
                    return
                }

                let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
                guard returnedState == state else {
                    continuation.resume(throwing: AuthError.stateMismatch)
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchangeCode(_ code: String) async throws -> String {
        guard let baseURL = Config.backendBaseURL else {
            throw AuthError.noBackendURL
        }

        let exchangeURL = baseURL.appendingPathComponent("github/exchange")
        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AuthError.exchangeFailed(body)
        }

        let payload = try JSONDecoder().decode([String: String].self, from: data)
        guard let token = payload["token"] else {
            throw AuthError.missingToken
        }
        return token
    }

    // MARK: - Keychain

    private static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        deleteToken()
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    private static func deleteToken() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case invalidURL
        case missingCode
        case stateMismatch
        case noBackendURL
        case exchangeFailed(String)
        case missingToken

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Could not construct GitHub authorization URL."
            case .missingCode: return "GitHub did not return an authorization code."
            case .stateMismatch: return "OAuth state parameter mismatch — possible CSRF."
            case .noBackendURL: return "Backend URL not configured. Set BACKEND_WS_URL in Secrets.plist."
            case .exchangeFailed(let body): return "Token exchange failed: \(body)"
            case .missingToken: return "Server response did not include an access token."
            }
        }
    }
}

extension GitHubAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        DispatchQueue.main.sync {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
                ?? UIWindow()
        }
    }
}
