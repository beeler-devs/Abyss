import Foundation

/// Wire-format event envelope for WebSocket transport.
/// Transport uses explicit `type` + `payload`, while app runtime uses `Event.Kind`.
struct EventEnvelope: Codable, Sendable {
    let id: String
    let type: String
    let timestamp: Date
    let sessionId: String?
    let payload: [String: JSONValue]

    init(id: String, type: String, timestamp: Date, sessionId: String?, payload: [String: JSONValue]) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.payload = payload
    }

    init(event: Event) {
        id = event.id
        timestamp = event.timestamp
        sessionId = event.sessionId

        let isoTimestamp = Self.iso8601.string(from: event.timestamp)
        switch event.kind {
        case .sessionStart(let value):
            type = "session.start"
            payload = ["sessionId": .string(value.sessionId)]
        case .userAudioTranscriptPartial(let value):
            type = "user.audio.transcript.partial"
            payload = Self.withEnvelopeMetadata(base: ["text": .string(value.text)], sessionId: event.sessionId, timestamp: isoTimestamp)
        case .userAudioTranscriptFinal(let value):
            type = "user.audio.transcript.final"
            payload = Self.withEnvelopeMetadata(base: ["text": .string(value.text)], sessionId: event.sessionId, timestamp: isoTimestamp)
        case .assistantSpeechPartial(let value):
            type = "assistant.speech.partial"
            payload = ["text": .string(value.text)]
        case .assistantSpeechFinal(let value):
            type = "assistant.speech.final"
            payload = ["text": .string(value.text)]
        case .assistantUIPatch(let value):
            type = "assistant.ui.patch"
            payload = ["patch": .string(value.patch)]
        case .agentStatus(let value):
            type = "agent.status"
            payload = [
                "status": .string(value.status),
                "detail": value.detail.map(JSONValue.string) ?? .null
            ]
        case .audioOutputInterrupted(let value):
            type = "audio.output.interrupted"
            payload = ["reason": .string(value.reason)]
        case .toolCall(let value):
            type = "tool.call"
            payload = [
                "callId": .string(value.callId),
                "name": .string(value.name),
                "arguments": .string(value.arguments)
            ]
        case .toolResult(let value):
            type = "tool.result"
            payload = [
                "callId": .string(value.callId),
                "result": value.result.map(JSONValue.string) ?? .null,
                "error": value.error.map(JSONValue.string) ?? .null
            ]
        case .error(let value):
            type = "error"
            payload = ["code": .string(value.code), "message": .string(value.message)]
        }
    }

    func toEvent() throws -> Event {
        let kind: Event.Kind

        switch type {
        case "session.start":
            let session = payload["sessionId"]?.stringValue ?? sessionId ?? UUID().uuidString
            kind = .sessionStart(Event.SessionStart(sessionId: session))
        case "session.started":
            let session = payload["sessionId"]?.stringValue ?? sessionId ?? UUID().uuidString
            kind = .sessionStart(Event.SessionStart(sessionId: session))
        case "user.audio.transcript.partial":
            kind = .userAudioTranscriptPartial(Event.TranscriptPartial(text: try requireString("text")))
        case "user.audio.transcript.final":
            kind = .userAudioTranscriptFinal(Event.TranscriptFinal(text: try requireString("text")))
        case "assistant.speech.partial":
            kind = .assistantSpeechPartial(Event.SpeechPartial(text: try requireString("text")))
        case "assistant.speech.final":
            kind = .assistantSpeechFinal(Event.SpeechFinal(text: try requireString("text")))
        case "assistant.ui.patch":
            kind = .assistantUIPatch(Event.UIPatch(patch: try requireString("patch")))
        case "agent.status":
            kind = .agentStatus(Event.AgentStatus(
                status: try requireString("status"),
                detail: payload["detail"]?.stringValue
            ))
        case "audio.output.interrupted":
            kind = .audioOutputInterrupted(Event.AudioOutputInterrupted(reason: payload["reason"]?.stringValue ?? "unknown"))
        case "tool.call":
            kind = .toolCall(Event.ToolCall(
                callId: try requireString("callId"),
                name: try requireString("name"),
                arguments: try requireString("arguments")
            ))
        case "tool.result":
            kind = .toolResult(Event.ToolResult(
                callId: try requireString("callId"),
                result: payload["result"]?.stringValue,
                error: payload["error"]?.stringValue
            ))
        case "error":
            kind = .error(Event.ErrorInfo(
                code: payload["code"]?.stringValue ?? "unknown",
                message: payload["message"]?.stringValue ?? "Unknown error"
            ))
        default:
            throw ConversionError.unsupportedType(type)
        }

        return Event(id: id, timestamp: timestamp, sessionId: sessionId, kind: kind)
    }

    private func requireString(_ key: String) throws -> String {
        guard let value = payload[key]?.stringValue else {
            throw ConversionError.missingField(key, type)
        }
        return value
    }

    private static func withEnvelopeMetadata(base: [String: JSONValue], sessionId: String?, timestamp: String) -> [String: JSONValue] {
        var payload = base
        payload["timestamp"] = .string(timestamp)
        if let sessionId {
            payload["sessionId"] = .string(sessionId)
        }
        return payload
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum ConversionError: Error, LocalizedError {
        case unsupportedType(String)
        case missingField(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let type):
                return "Unsupported event type: \(type)"
            case .missingField(let field, let type):
                return "Missing required field '\(field)' for type '\(type)'"
            }
        }
    }
}

/// Small JSON value type for envelope payloads.
enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
