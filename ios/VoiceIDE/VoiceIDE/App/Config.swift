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
    static var isElevenLabsAPIKeyConfigured: Bool {
        elevenLabsAPIKey != nil
    }

    /// Cursor API key, loaded from in-app settings, Secrets.plist, or environment.
    static var cursorAPIKey: String? {
        // 1. Check in-app settings (persisted in UserDefaults via @AppStorage)
        if let key = UserDefaults.standard.string(forKey: "cursorAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        // 2. Check Secrets.plist in the bundle
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let key = dict["CURSOR_API_KEY"] as? String,
           !key.isEmpty {
            return key
        }

        // 3. Check environment variable (useful for CI/testing)
        if let key = ProcessInfo.processInfo.environment["CURSOR_API_KEY"],
           !key.isEmpty {
            return key
        }

        return nil
    }

    /// Whether the Cursor API key is configured.
    static var isCursorAPIKeyConfigured: Bool {
        cursorAPIKey != nil
    }

    /// Backward-compatible alias for existing code paths.
    static var isAPIKeyConfigured: Bool {
        isElevenLabsAPIKeyConfigured
    }
}
