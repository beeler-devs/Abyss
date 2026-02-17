import Foundation

/// Strongly-typed event model representing every action in the system.
/// All state changes, tool calls, and assistant outputs flow through events.
struct Event: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: Kind

    init(id: UUID = UUID(), timestamp: Date = Date(), kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
        kind = try c.decode(Kind.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind, forKey: .kind)
    }

    // MARK: - Event Kinds

    enum Kind: Sendable {
        case sessionStart(SessionStart)
        case userAudioTranscriptPartial(TranscriptPartial)
        case userAudioTranscriptFinal(TranscriptFinal)
        case assistantSpeechPartial(SpeechPartial)
        case assistantSpeechFinal(SpeechFinal)
        case assistantUIPatch(UIPatch)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case error(ErrorInfo)
    }

    // MARK: - Payloads

    struct SessionStart: Codable, Sendable {
        let sessionId: String
    }

    struct TranscriptPartial: Codable, Sendable {
        let text: String
    }

    struct TranscriptFinal: Codable, Sendable {
        let text: String
    }

    struct SpeechPartial: Codable, Sendable {
        let text: String
    }

    struct SpeechFinal: Codable, Sendable {
        let text: String
    }

    struct UIPatch: Codable, Sendable {
        let patch: String // Placeholder JSON patch for Phase 2+
    }

    struct ToolCall: Codable, Sendable, Equatable {
        let callId: String
        let name: String
        let arguments: String // JSON-encoded arguments

        init(callId: String = UUID().uuidString, name: String, arguments: String) {
            self.callId = callId
            self.name = name
            self.arguments = arguments
        }
    }

    struct ToolResult: Codable, Sendable {
        let callId: String
        let result: String? // JSON-encoded result
        let error: String?

        var isError: Bool { error != nil }

        static func success(callId: String, result: String) -> ToolResult {
            ToolResult(callId: callId, result: result, error: nil)
        }

        static func failure(callId: String, error: String) -> ToolResult {
            ToolResult(callId: callId, result: nil, error: error)
        }
    }

    struct ErrorInfo: Codable, Sendable {
        let code: String
        let message: String
    }
}

// MARK: - Custom Codable for Event.Kind

extension Event.Kind: Codable {
    enum CodingKeys: String, CodingKey {
        case sessionStart
        case userAudioTranscriptPartial
        case userAudioTranscriptFinal
        case assistantSpeechPartial
        case assistantSpeechFinal
        case assistantUIPatch
        case toolCall
        case toolResult
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let value = try? container.decode(Event.SessionStart.self, forKey: .sessionStart) {
            self = .sessionStart(value)
        } else if let value = try? container.decode(Event.TranscriptPartial.self, forKey: .userAudioTranscriptPartial) {
            self = .userAudioTranscriptPartial(value)
        } else if let value = try? container.decode(Event.TranscriptFinal.self, forKey: .userAudioTranscriptFinal) {
            self = .userAudioTranscriptFinal(value)
        } else if let value = try? container.decode(Event.SpeechPartial.self, forKey: .assistantSpeechPartial) {
            self = .assistantSpeechPartial(value)
        } else if let value = try? container.decode(Event.SpeechFinal.self, forKey: .assistantSpeechFinal) {
            self = .assistantSpeechFinal(value)
        } else if let value = try? container.decode(Event.UIPatch.self, forKey: .assistantUIPatch) {
            self = .assistantUIPatch(value)
        } else if let value = try? container.decode(Event.ToolCall.self, forKey: .toolCall) {
            self = .toolCall(value)
        } else if let value = try? container.decode(Event.ToolResult.self, forKey: .toolResult) {
            self = .toolResult(value)
        } else if let value = try? container.decode(Event.ErrorInfo.self, forKey: .error) {
            self = .error(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown event kind")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .sessionStart(let value):
            try container.encode(value, forKey: .sessionStart)
        case .userAudioTranscriptPartial(let value):
            try container.encode(value, forKey: .userAudioTranscriptPartial)
        case .userAudioTranscriptFinal(let value):
            try container.encode(value, forKey: .userAudioTranscriptFinal)
        case .assistantSpeechPartial(let value):
            try container.encode(value, forKey: .assistantSpeechPartial)
        case .assistantSpeechFinal(let value):
            try container.encode(value, forKey: .assistantSpeechFinal)
        case .assistantUIPatch(let value):
            try container.encode(value, forKey: .assistantUIPatch)
        case .toolCall(let value):
            try container.encode(value, forKey: .toolCall)
        case .toolResult(let value):
            try container.encode(value, forKey: .toolResult)
        case .error(let value):
            try container.encode(value, forKey: .error)
        }
    }
}

// MARK: - Convenience Factories

extension Event {
    static func sessionStart(sessionId: String = UUID().uuidString) -> Event {
        Event(kind: .sessionStart(SessionStart(sessionId: sessionId)))
    }

    static func transcriptPartial(_ text: String) -> Event {
        Event(kind: .userAudioTranscriptPartial(TranscriptPartial(text: text)))
    }

    static func transcriptFinal(_ text: String) -> Event {
        Event(kind: .userAudioTranscriptFinal(TranscriptFinal(text: text)))
    }

    static func speechPartial(_ text: String) -> Event {
        Event(kind: .assistantSpeechPartial(SpeechPartial(text: text)))
    }

    static func speechFinal(_ text: String) -> Event {
        Event(kind: .assistantSpeechFinal(SpeechFinal(text: text)))
    }

    static func uiPatch(_ patch: String) -> Event {
        Event(kind: .assistantUIPatch(UIPatch(patch: patch)))
    }

    static func toolCall(name: String, arguments: String, callId: String = UUID().uuidString) -> Event {
        Event(kind: .toolCall(ToolCall(callId: callId, name: name, arguments: arguments)))
    }

    static func toolResult(callId: String, result: String) -> Event {
        Event(kind: .toolResult(ToolResult.success(callId: callId, result: result)))
    }

    static func toolError(callId: String, error: String) -> Event {
        Event(kind: .toolResult(ToolResult.failure(callId: callId, error: error)))
    }

    static func error(code: String, message: String) -> Event {
        Event(kind: .error(ErrorInfo(code: code, message: message)))
    }
}

// MARK: - Display Helpers

extension Event.Kind {
    var displayName: String {
        switch self {
        case .sessionStart: return "session.start"
        case .userAudioTranscriptPartial: return "user.audio.transcript.partial"
        case .userAudioTranscriptFinal: return "user.audio.transcript.final"
        case .assistantSpeechPartial: return "assistant.speech.partial"
        case .assistantSpeechFinal: return "assistant.speech.final"
        case .assistantUIPatch: return "assistant.ui.patch"
        case .toolCall(let tc): return "tool.call: \(tc.name)"
        case .toolResult(let tr): return tr.isError ? "tool.result: ERROR" : "tool.result: OK"
        case .error(let e): return "error: \(e.code)"
        }
    }
}
