import Foundation

/// Centralized configuration loader.
/// Reads secrets from Secrets.plist (git-ignored) or environment variables.
/// Never hardcode API keys.
enum Config {
    /// ElevenLabs API key, loaded from Secrets.plist or environment.
    static var elevenLabsAPIKey: String? {
        // 1. Check Secrets.plist in the bundle
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let key = dict["ELEVENLABS_API_KEY"] as? String,
           !key.isEmpty {
            return key
        }

        // 2. Check environment variable (useful for CI/testing)
        if let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"],
           !key.isEmpty {
            return key
        }

        return nil
    }

    /// Default ElevenLabs voice ID.
    static var elevenLabsVoiceId: String {
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let voiceId = dict["ELEVENLABS_VOICE_ID"] as? String,
           !voiceId.isEmpty {
            return voiceId
        }
        return "21m00Tcm4TlvDq8ikWAM" // Rachel (default)
    }

    /// Default ElevenLabs model ID.
    static var elevenLabsModelId: String {
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let modelId = dict["ELEVENLABS_MODEL_ID"] as? String,
           !modelId.isEmpty {
            return modelId
        }
        return "eleven_turbo_v2_5"
    }

    /// Whether the API key is configured.
    static var isAPIKeyConfigured: Bool {
        elevenLabsAPIKey != nil
    }

    // MARK: - Backend (Phase 2)

    /// WebSocket URL for the cloud conductor backend.
    /// Configure in Secrets.plist with key BACKEND_WS_URL, or set env var.
    /// Example: wss://abc123.execute-api.us-east-1.amazonaws.com/prod
    static var backendWebSocketURL: String {
        // 1. Check Secrets.plist
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let url = dict["BACKEND_WS_URL"] as? String,
           !url.isEmpty {
            return url
        }

        // 2. Check environment variable
        if let url = ProcessInfo.processInfo.environment["BACKEND_WS_URL"],
           !url.isEmpty {
            return url
        }

        // 3. Default placeholder (must be configured for Phase 2 to work)
        return "wss://CONFIGURE-ME.execute-api.us-east-1.amazonaws.com/prod"
    }

    /// Whether the backend URL is configured (not the placeholder).
    static var isBackendConfigured: Bool {
        !backendWebSocketURL.contains("CONFIGURE-ME")
    }

    /// Whether to use the cloud conductor (Phase 2) or local stub (Phase 1).
    /// Set USE_CLOUD_CONDUCTOR=true in Secrets.plist or env to enable.
    static var useCloudConductor: Bool {
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let value = dict["USE_CLOUD_CONDUCTOR"] as? String {
            return value.lowercased() == "true" || value == "1"
        }

        if let value = ProcessInfo.processInfo.environment["USE_CLOUD_CONDUCTOR"] {
            return value.lowercased() == "true" || value == "1"
        }

        return false
    }
}
