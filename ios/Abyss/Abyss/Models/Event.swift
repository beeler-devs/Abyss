import Foundation

/// Strongly-typed event model representing every action in the system.
/// All state changes, tool calls, and assistant outputs flow through events.
struct Event: Identifiable, Codable, Sendable {
    let id: String
    let timestamp: Date
    let sessionId: String?
    let kind: Kind

    init(id: String = UUID().uuidString, timestamp: Date = Date(), sessionId: String? = nil, kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.kind = kind
    }

    // MARK: - Event Kinds

    enum Kind: Codable, Sendable {
        case sessionStart(SessionStart)
        case userAudioTranscriptPartial(TranscriptPartial)
        case userAudioTranscriptFinal(TranscriptFinal)
        case assistantSpeechPartial(SpeechPartial)
        case assistantSpeechFinal(SpeechFinal)
        case assistantUIPatch(UIPatch)
        case agentStatus(AgentStatus)
        case audioOutputInterrupted(AudioOutputInterrupted)
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
        let patch: String
    }

    struct AgentStatus: Codable, Sendable {
        let status: String
        let detail: String?
    }

    struct AudioOutputInterrupted: Codable, Sendable {
        let reason: String
    }

    struct ToolCall: Codable, Sendable, Equatable {
        let callId: String
        let name: String
        let arguments: String

        init(callId: String = UUID().uuidString, name: String, arguments: String) {
            self.callId = callId
            self.name = name
            self.arguments = arguments
        }
    }

    struct ToolResult: Codable, Sendable {
        let callId: String
        let result: String?
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

// MARK: - Convenience Factories

extension Event {
    static func sessionStart(sessionId: String = UUID().uuidString) -> Event {
        Event(sessionId: sessionId, kind: .sessionStart(SessionStart(sessionId: sessionId)))
    }

    static func transcriptPartial(_ text: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .userAudioTranscriptPartial(TranscriptPartial(text: text)))
    }

    static func transcriptFinal(_ text: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .userAudioTranscriptFinal(TranscriptFinal(text: text)))
    }

    static func speechPartial(_ text: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantSpeechPartial(SpeechPartial(text: text)))
    }

    static func speechFinal(_ text: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantSpeechFinal(SpeechFinal(text: text)))
    }

    static func uiPatch(_ patch: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantUIPatch(UIPatch(patch: patch)))
    }

    static func agentStatus(_ status: String, detail: String? = nil, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .agentStatus(AgentStatus(status: status, detail: detail)))
    }

    static func audioOutputInterrupted(_ reason: String = "barge_in", sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .audioOutputInterrupted(AudioOutputInterrupted(reason: reason)))
    }

    static func toolCall(name: String, arguments: String, callId: String = UUID().uuidString, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .toolCall(ToolCall(callId: callId, name: name, arguments: arguments)))
    }

    static func toolResult(callId: String, result: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .toolResult(ToolResult.success(callId: callId, result: result)))
    }

    static func toolError(callId: String, error: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .toolResult(ToolResult.failure(callId: callId, error: error)))
    }

    static func error(code: String, message: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .error(ErrorInfo(code: code, message: message)))
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
        case .agentStatus: return "agent.status"
        case .audioOutputInterrupted: return "audio.output.interrupted"
        case .toolCall(let tc): return "tool.call: \(tc.name)"
        case .toolResult(let tr): return tr.isError ? "tool.result: ERROR" : "tool.result: OK"
        case .error(let e): return "error: \(e.code)"
        }
    }
}
