import AuthenticationServices
import CommonCrypto
import Foundation
import Security

@MainActor
final class GmailAuthManager: NSObject, ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isAuthenticating: Bool = false
    @Published var authError: String? = nil

    private static let keychainService = "app.abyss.gmail"
    private static let accessTokenAccount = "gmail_access_token"
    private static let refreshTokenAccount = "gmail_refresh_token"
    private static let expiresAtAccount = "gmail_token_expires_at"

    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        isAuthenticated = (Self.loadAccessToken() != nil)
    }

    // MARK: - Public API

    var accessToken: String? {
        Self.loadAccessToken()
    }

    var refreshToken: String? {
        Self.loadRefreshToken()
    }

    var tokenExpiresAt: Double? {
        Self.loadExpiresAt()
    }

    func authenticate() async {
        guard !isAuthenticating else { return }
        guard let clientId = Config.googleClientId, !clientId.isEmpty else {
            authError = "Google Client ID not configured. Set GOOGLE_CLIENT_ID in Secrets.plist."
            return
        }

        isAuthenticating = true
        authError = nil
        defer { isAuthenticating = false }

        do {
            let pkce = PKCE.generate()
            let code = try await startOAuthFlow(clientId: clientId, codeChallenge: pkce.codeChallenge)
            let redirectUri = "\(Self.reversedClientIdScheme(from: clientId)):/oauthredirect"
            let tokens = try await exchangeCodeOnDevice(
                code: code,
                clientId: clientId,
                redirectUri: redirectUri,
                codeVerifier: pkce.codeVerifier
            )
            Self.saveAccessToken(tokens.accessToken)
            if let refreshToken = tokens.refreshToken {
                Self.saveRefreshToken(refreshToken)
            }
            Self.saveExpiresAt(Date().timeIntervalSince1970 + tokens.expiresIn)
            isAuthenticated = true
        } catch {
            authError = error.localizedDescription
        }
    }

    func signOut() {
        Self.deleteToken(account: Self.accessTokenAccount)
        Self.deleteToken(account: Self.refreshTokenAccount)
        Self.deleteToken(account: Self.expiresAtAccount)
        isAuthenticated = false
    }

    // MARK: - PKCE

    private struct PKCE {
        let codeVerifier: String
        let codeChallenge: String

        static func generate() -> PKCE {
            var buffer = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
            let verifier = Data(buffer).base64URLEncodedString()

            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let verifierData = Data(verifier.utf8)
            verifierData.withUnsafeBytes { ptr in
                _ = CC_SHA256(ptr.baseAddress, CC_LONG(verifierData.count), &hash)
            }
            let challenge = Data(hash).base64URLEncodedString()

            return PKCE(codeVerifier: verifier, codeChallenge: challenge)
        }
    }

    // MARK: - OAuth Flow

    /// Derives the reversed client ID scheme from a Google client ID.
    /// e.g. "123456789-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123456789-abc"
    private static func reversedClientIdScheme(from clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    private func startOAuthFlow(clientId: String, codeChallenge: String) async throws -> String {
        let callbackScheme = Self.reversedClientIdScheme(from: clientId)
        let redirectUri = "\(callbackScheme):/oauthredirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let state = UUID().uuidString
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else {
            throw AuthError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in self?.authSession = nil }

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
            authSession = session
            session.start()
        }
    }

    // MARK: - Token Exchange (on-device, no client_secret needed for iOS clients)

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
    }

    private func exchangeCodeOnDevice(
        code: String,
        clientId: String,
        redirectUri: String,
        codeVerifier: String
    ) async throws -> TokenResponse {
        let params: [String: String] = [
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
        ]

        let body = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "unknown"
            throw AuthError.exchangeFailed(text)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.missingToken
        }

        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw AuthError.missingToken
        }

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: (json["expires_in"] as? Double) ?? 3600
        )
    }

    // MARK: - Keychain

    private static func saveAccessToken(_ token: String) {
        saveKeychainString(token, account: accessTokenAccount)
    }

    private static func saveRefreshToken(_ token: String) {
        saveKeychainString(token, account: refreshTokenAccount)
    }

    private static func saveExpiresAt(_ epochSeconds: Double) {
        saveKeychainString(String(epochSeconds), account: expiresAtAccount)
    }

    static func loadAccessToken() -> String? {
        loadKeychainString(account: accessTokenAccount)
    }

    static func loadRefreshToken() -> String? {
        loadKeychainString(account: refreshTokenAccount)
    }

    static func loadExpiresAt() -> Double? {
        guard let str = loadKeychainString(account: expiresAtAccount) else { return nil }
        return Double(str)
    }

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

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case invalidURL
        case missingCode
        case stateMismatch
        case exchangeFailed(String)
        case missingToken

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Could not construct Google authorization URL."
            case .missingCode: return "Google did not return an authorization code."
            case .stateMismatch: return "OAuth state parameter mismatch — possible CSRF."
            case .exchangeFailed(let body): return "Token exchange failed: \(body)"
            case .missingToken: return "Server response did not include an access token."
            }
        }
    }
}

extension GmailAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let findWindow = {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .compactMap { $0.keyWindow }
                .first ?? UIWindow()
        }
        if Thread.isMainThread {
            return findWindow()
        }
        return DispatchQueue.main.sync { findWindow() }
    }
}

// MARK: - Base64URL encoding for PKCE

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
