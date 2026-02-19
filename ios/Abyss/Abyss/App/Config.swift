import Foundation

/// Centralized configuration loader.
/// Reads runtime values from UserDefaults, Secrets.plist (git-ignored), Info.plist, or environment.
enum Config {
    // MARK: - Shared Lookup

    private static func valueFromSecretsPlist(_ key: String) -> String? {
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let value = dict[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func valueFromInfoPlist(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return nil
        }
        return trimmed
    }

    private static func valueFromEnvironment(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - ElevenLabs

    /// ElevenLabs API key, loaded from Secrets.plist or environment.
    static var elevenLabsAPIKey: String? {
        valueFromSecretsPlist("ELEVENLABS_API_KEY")
            ?? valueFromEnvironment("ELEVENLABS_API_KEY")
    }

    /// Default ElevenLabs voice ID.
    static var elevenLabsVoiceId: String {
        if let value = UserDefaults.standard.string(forKey: "elevenLabsVoiceId")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return valueFromSecretsPlist("ELEVENLABS_VOICE_ID")
            ?? "21m00Tcm4TlvDq8ikWAM"
    }

    /// Default ElevenLabs model ID.
    static var elevenLabsModelId: String {
        if let value = UserDefaults.standard.string(forKey: "elevenLabsModelId")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return valueFromSecretsPlist("ELEVENLABS_MODEL_ID")
            ?? "eleven_turbo_v2_5"
    }

    /// Whether the API key is configured.
    static var isElevenLabsAPIKeyConfigured: Bool {
        elevenLabsAPIKey != nil
    }

    // MARK: - Cursor

    /// Cursor API key, loaded from in-app settings, Secrets.plist, or environment.
    static var cursorAPIKey: String? {
        if let key = UserDefaults.standard.string(forKey: "cursorAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        return valueFromSecretsPlist("CURSOR_API_KEY")
            ?? valueFromEnvironment("CURSOR_API_KEY")
    }

    static var isCursorAPIKeyConfigured: Bool {
        cursorAPIKey != nil
    }

    // MARK: - Conductor Backend

    /// WebSocket URL used by the Phase 2 server conductor (e.g. ws://192.168.1.20:8080/ws).
    static var backendWSURL: URL? {
        let raw = valueFromSecretsPlist("BACKEND_WS_URL")
            ?? valueFromInfoPlist("BACKEND_WS_URL")
            ?? valueFromEnvironment("BACKEND_WS_URL")

        guard let raw,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme) else {
            return nil
        }

        return url
    }

    static var backendWSURLString: String? {
        backendWSURL?.absoluteString
    }

    static var isBackendWSConfigured: Bool {
        backendWSURL != nil
    }

    // MARK: - GitHub

    /// GitHub OAuth App client ID.
    static var githubClientId: String? {
        valueFromSecretsPlist("GITHUB_CLIENT_ID")
            ?? valueFromInfoPlist("GITHUB_CLIENT_ID")
            ?? valueFromEnvironment("GITHUB_CLIENT_ID")
    }

    /// HTTP base URL of the backend, derived from the WebSocket URL by swapping scheme.
    /// e.g. ws://192.168.1.20:8080/ws → http://192.168.1.20:8080
    static var backendBaseURL: URL? {
        guard let wsURL = backendWSURL,
              var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (wsURL.scheme == "wss") ? "https" : "http"
        components.path = ""
        return components.url
    }

    // MARK: - Backward Compatibility

    static var isAPIKeyConfigured: Bool {
        isElevenLabsAPIKeyConfigured
    }
}
