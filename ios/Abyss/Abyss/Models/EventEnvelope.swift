import Foundation

/// Wire-format event envelope for WebSocket transport.
/// Transport uses explicit `type` + `payload`, while app runtime uses `Event.Kind`.
struct EventEnvelope: Codable, Sendable {
    let id: String
    let type: String
    let timestamp: Date
    let sessionId: String?
    let protocolVersion: Int
    let payload: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case id, type, timestamp, sessionId, protocolVersion, payload
    }

    init(
        id: String,
        type: String,
        timestamp: Date,
        sessionId: String?,
        protocolVersion: Int = 1,
        payload: [String: JSONValue]
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.protocolVersion = protocolVersion
        self.payload = payload
    }

    init(event: Event) {
        id = event.id
        timestamp = event.timestamp
        sessionId = event.sessionId
        protocolVersion = 1

        let isoTimestamp = Self.iso8601.string(from: event.timestamp)
        switch event.kind {
        case .sessionStart(let value):
            type = "session.start"
            var sessionPayload: [String: JSONValue] = ["sessionId": .string(value.sessionId)]
            if let token = value.githubToken {
                sessionPayload["githubToken"] = .string(token)
            }
            payload = sessionPayload
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
            var statusPayload: [String: JSONValue] = [
                "status": .string(value.status),
                "detail": value.detail.map(JSONValue.string) ?? .null
            ]
            if let agentId = value.agentId { statusPayload["agentId"] = .string(agentId) }
            if let summary = value.summary { statusPayload["summary"] = .string(summary) }
            if let runUrl = value.runUrl { statusPayload["runUrl"] = .string(runUrl) }
            if let prUrl = value.prUrl { statusPayload["prUrl"] = .string(prUrl) }
            if let branchName = value.branchName { statusPayload["branchName"] = .string(branchName) }
            if let webhookDriven = value.webhookDriven { statusPayload["webhookDriven"] = .bool(webhookDriven) }
            payload = statusPayload
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
        case .agentCompleted(let value):
            type = "agent.completed"
            var p: [String: JSONValue] = [
                "agentId": .string(value.agentId),
                "status":  .string(value.status),
                "summary": .string(value.summary),
            ]
            if let name   = value.name   { p["name"]   = .string(name) }
            if let prompt = value.prompt { p["prompt"] = .string(prompt) }
            payload = p
        case .agentConversation(let value):
            type = "agent.conversation"
            payload = [
                "agentId": .string(value.agentId),
                "messages": .array(value.messages.map { msg in
                    .object([
                        "id": .string(msg.id),
                        "type": .string(msg.type),
                        "text": .string(msg.text),
                    ])
                }),
            ]
        case .bridgePairRequest(let value):
            type = "bridge.pair.request"
            var p: [String: JSONValue] = ["pairingCode": .string(value.pairingCode)]
            if let deviceName = value.deviceName {
                p["deviceName"] = .string(deviceName)
            }
            payload = p
        case .bridgePairPending(let value):
            type = "bridge.pair.pending"
            var p: [String: JSONValue] = ["pairingCode": .string(value.pairingCode)]
            if let expiresInSec = value.expiresInSec {
                p["expiresInSec"] = .number(Double(expiresInSec))
            }
            payload = p
        case .bridgePaired(let value):
            type = "bridge.paired"
            payload = [
                "deviceId": .string(value.deviceId),
                "deviceName": .string(value.deviceName),
                "status": .string(value.status),
            ]
        case .bridgeStatus(let value):
            var p: [String: JSONValue] = [
                "deviceId": .string(value.deviceId),
                "status": .string(value.status),
            ]
            if let lastSeen = value.lastSeen {
                p["lastSeen"] = .string(lastSeen)
            }
            type = "bridge.status"
            payload = p
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        payload = try container.decode([String: JSONValue].self, forKey: .payload)
    }

    func toEvent() throws -> Event {
        let kind: Event.Kind

        switch type {
        case "session.start":
            let session = payload["sessionId"]?.stringValue ?? sessionId ?? UUID().uuidString
            kind = .sessionStart(Event.SessionStart(sessionId: session, githubToken: nil))
        case "session.started":
            let session = payload["sessionId"]?.stringValue ?? sessionId ?? UUID().uuidString
            kind = .sessionStart(Event.SessionStart(sessionId: session, githubToken: nil))
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
                agentId: payload["agentId"]?.stringValue,
                status: try requireString("status"),
                detail: payload["detail"]?.stringValue,
                summary: payload["summary"]?.stringValue,
                runUrl: payload["runUrl"]?.stringValue,
                prUrl: payload["prUrl"]?.stringValue,
                branchName: payload["branchName"]?.stringValue,
                webhookDriven: payload["webhookDriven"]?.boolValue
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
        case "agent.completed":
            kind = .agentCompleted(Event.AgentCompleted(
                agentId: try requireString("agentId"),
                status: payload["status"]?.stringValue ?? "UNKNOWN",
                summary: payload["summary"]?.stringValue ?? "",
                name: payload["name"]?.stringValue,
                prompt: payload["prompt"]?.stringValue
            ))
        case "agent.conversation":
            let agentId = try requireString("agentId")
            var messages: [Event.AgentConversationMessage] = []
            if case .array(let arr) = payload["messages"] {
                for item in arr {
                    if case .object(let obj) = item,
                       let msgId = obj["id"]?.stringValue,
                       let msgType = obj["type"]?.stringValue,
                       let msgText = obj["text"]?.stringValue {
                        messages.append(Event.AgentConversationMessage(id: msgId, type: msgType, text: msgText))
                    }
                }
            }
            kind = .agentConversation(Event.AgentConversation(agentId: agentId, messages: messages))
        case "bridge.pair.request":
            kind = .bridgePairRequest(Event.BridgePairRequest(
                pairingCode: try requireString("pairingCode"),
                deviceName: payload["deviceName"]?.stringValue
            ))
        case "bridge.pair.pending":
            kind = .bridgePairPending(Event.BridgePairPending(
                pairingCode: try requireString("pairingCode"),
                expiresInSec: payload["expiresInSec"]?.intValue
            ))
        case "bridge.paired":
            kind = .bridgePaired(Event.BridgePaired(
                deviceId: try requireString("deviceId"),
                deviceName: try requireString("deviceName"),
                status: payload["status"]?.stringValue ?? "online"
            ))
        case "bridge.status":
            kind = .bridgeStatus(Event.BridgeStatus(
                deviceId: try requireString("deviceId"),
                status: payload["status"]?.stringValue ?? "offline",
                lastSeen: payload["lastSeen"]?.stringValue
            ))
        case "bridge.device.selection.required":
            kind = .error(Event.ErrorInfo(
                code: "bridge_device_selection_required",
                message: "Multiple paired computers are available. Please choose one."
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

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
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
