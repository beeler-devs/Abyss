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
            if let gmailToken = value.gmailAccessToken {
                sessionPayload["gmailAccessToken"] = .string(gmailToken)
            }
            if let gmailRefresh = value.gmailRefreshToken {
                sessionPayload["gmailRefreshToken"] = .string(gmailRefresh)
            }
            if let gmailExpires = value.gmailTokenExpiresAt {
                sessionPayload["gmailTokenExpiresAt"] = .number(gmailExpires)
            }
            if let canvasToken = value.canvasAccessToken {
                sessionPayload["canvasAccessToken"] = .string(canvasToken)
            }
            if let canvasURL = value.canvasBaseURL {
                sessionPayload["canvasBaseURL"] = .string(canvasURL)
            }
            if let memoryUserKey = value.memoryUserKey {
                sessionPayload["memoryUserKey"] = .string(memoryUserKey)
            }
            if let prefs = value.preferences, !prefs.isEmpty {
                sessionPayload["preferences"] = .object(prefs.mapValues { .string($0) })
            }
            if let overrides = value.bridgeWorkspaceOverrides, !overrides.isEmpty {
                sessionPayload["bridgeWorkspaceOverrides"] = .array(overrides.map { override in
                    .object([
                        "deviceId": .string(override.deviceId),
                        "workspacePath": .string(override.workspacePath),
                    ])
                })
            }
            payload = sessionPayload
        case .userAudioTranscriptPartial(let value):
            type = "user.audio.transcript.partial"
            payload = Self.withEnvelopeMetadata(base: ["text": .string(value.text)], sessionId: event.sessionId, timestamp: isoTimestamp)
        case .userAudioTranscriptFinal(let value):
            type = "user.audio.transcript.final"
            payload = Self.withEnvelopeMetadata(base: ["text": .string(value.text)], sessionId: event.sessionId, timestamp: isoTimestamp)
        case .userAudioStreamStart(let value):
            type = "user.audio.stream.start"
            payload = [
                "encoding": .string(value.encoding),
                "sampleRateHertz": .number(Double(value.sampleRateHertz)),
                "channelCount": .number(Double(value.channelCount)),
            ]
        case .userAudioStreamChunk(let value):
            type = "user.audio.stream.chunk"
            payload = [
                "audio": .string(value.audio),
                "encoding": .string(value.encoding),
                "sampleRateHertz": .number(Double(value.sampleRateHertz)),
                "channelCount": .number(Double(value.channelCount)),
            ]
        case .userAudioStreamEnd(let value):
            type = "user.audio.stream.end"
            var streamEndPayload: [String: JSONValue] = [:]
            if let reason = value.reason {
                streamEndPayload["reason"] = .string(reason)
            }
            payload = streamEndPayload
        case .assistantSpeechPartial(let value):
            type = "assistant.speech.partial"
            payload = Self.assistantLivePayload(base: ["text": .string(value.text)], liveResponseId: value.liveResponseId)
        case .assistantSpeechFinal(let value):
            type = "assistant.speech.final"
            payload = Self.assistantLivePayload(base: ["text": .string(value.text)], liveResponseId: value.liveResponseId)
        case .assistantAudioChunk(let value):
            type = "assistant.audio.chunk"
            payload = Self.assistantLivePayload(base: [
                "audio": .string(value.audio),
                "encoding": .string(value.encoding),
                "sampleRateHertz": .number(Double(value.sampleRateHertz)),
                "channelCount": .number(Double(value.channelCount)),
            ], liveResponseId: value.liveResponseId)
        case .assistantAudioEnd(let value):
            type = "assistant.audio.end"
            payload = Self.assistantLivePayload(base: [:], liveResponseId: value.liveResponseId)
        case .assistantAudioInterrupted(let value):
            type = "assistant.audio.interrupted"
            payload = Self.assistantLivePayload(base: ["reason": .string(value.reason)], liveResponseId: value.liveResponseId)
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
            var p: [String: JSONValue] = [
                "deviceId": .string(value.deviceId),
                "deviceName": .string(value.deviceName),
                "status": .string(value.status),
            ]
            if let workspaceRoot = value.workspaceRoot {
                p["workspaceRoot"] = .string(workspaceRoot)
            }
            payload = p
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
        case .bridgeExecOutput(let value):
            type = "bridge.exec.output"
            payload = [
                "deviceId": .string(value.deviceId),
                "commandId": .string(value.commandId),
                "stream": .string(value.stream),
                "chunk": .string(value.chunk),
                "isFinal": .bool(value.isFinal),
            ]
        case .bridgeExecFinished(let value):
            type = "bridge.exec.finished"
            payload = [
                "deviceId": .string(value.deviceId),
                "commandId": .string(value.commandId),
                "exitCode": .number(Double(value.exitCode)),
                "stdoutTail": .string(value.stdoutTail),
                "stderrTail": .string(value.stderrTail),
            ]
        case .preferencesSync(let value):
            type = "preferences.sync"
            payload = ["preferences": .object(value.preferences.mapValues { .string($0) })]
        case .bridgeWorkspaceSet(let value):
            type = "bridge.workspace.set"
            payload = [
                "deviceId": .string(value.deviceId),
                "workspacePath": .string(value.workspacePath),
            ]
        case .gmailSendExecute(let value):
            type = "gmail.send.execute"
            var p: [String: JSONValue] = [
                "callId": .string(value.callId),
                "confirmed": .bool(value.confirmed),
            ]
            if let to = value.to { p["to"] = .string(to) }
            if let cc = value.cc { p["cc"] = .string(cc) }
            if let subject = value.subject { p["subject"] = .string(subject) }
            if let body = value.body { p["body"] = .string(body) }
            if let messageId = value.messageId { p["messageId"] = .string(messageId) }
            payload = p
        case .gmailSendResult(let value):
            type = "gmail.send.result"
            var p: [String: JSONValue] = [
                "callId": .string(value.callId),
                "success": .bool(value.success),
            ]
            if let error = value.error { p["error"] = .string(error) }
            payload = p
        case .sessionTitle(let value):
            type = "session.title"
            payload = ["title": .string(value.title)]
        case .calendarMutationExecute(let value):
            type = "calendar.mutation.execute"
            payload = [
                "callId": .string(value.callId),
                "confirmed": .bool(value.confirmed),
            ]
        case .calendarMutationResult(let value):
            type = "calendar.mutation.result"
            var p: [String: JSONValue] = [
                "callId": .string(value.callId),
                "status": .string(value.status),
            ]
            if let mutationType = value.mutationType { p["mutationType"] = .string(mutationType) }
            if let error = value.error { p["error"] = .string(error) }
            payload = p
        case .assistantImage(let value):
            type = "assistant.image"
            payload = [
                "imageBase64": .string(value.imageBase64),
                "mimeType": .string(value.mimeType),
            ]
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
            kind = .sessionStart(Event.SessionStart(sessionId: session, githubToken: nil, gmailAccessToken: nil, gmailRefreshToken: nil, gmailTokenExpiresAt: nil, canvasAccessToken: nil, canvasBaseURL: nil, preferences: nil, memoryUserKey: nil, bridgeWorkspaceOverrides: nil))
        case "session.started":
            let session = payload["sessionId"]?.stringValue ?? sessionId ?? UUID().uuidString
            kind = .sessionStart(Event.SessionStart(sessionId: session, githubToken: nil, gmailAccessToken: nil, gmailRefreshToken: nil, gmailTokenExpiresAt: nil, canvasAccessToken: nil, canvasBaseURL: nil, preferences: nil, memoryUserKey: nil, bridgeWorkspaceOverrides: nil))
        case "user.audio.transcript.partial":
            kind = .userAudioTranscriptPartial(Event.TranscriptPartial(text: try requireString("text")))
        case "user.audio.transcript.final":
            kind = .userAudioTranscriptFinal(Event.TranscriptFinal(text: try requireString("text")))
        case "user.audio.stream.start":
            kind = .userAudioStreamStart(Event.UserAudioStreamStart(
                encoding: payload["encoding"]?.stringValue ?? "pcm_s16le",
                sampleRateHertz: payload["sampleRateHertz"]?.intValue ?? 16_000,
                channelCount: payload["channelCount"]?.intValue ?? 1
            ))
        case "user.audio.stream.chunk":
            kind = .userAudioStreamChunk(Event.UserAudioStreamChunk(
                audio: try requireString("audio"),
                encoding: payload["encoding"]?.stringValue ?? "pcm_s16le",
                sampleRateHertz: payload["sampleRateHertz"]?.intValue ?? 16_000,
                channelCount: payload["channelCount"]?.intValue ?? 1
            ))
        case "user.audio.stream.end":
            kind = .userAudioStreamEnd(Event.UserAudioStreamEnd(reason: payload["reason"]?.stringValue))
        case "assistant.speech.partial":
            kind = .assistantSpeechPartial(Event.SpeechPartial(
                text: try requireString("text"),
                liveResponseId: payload["liveResponseId"]?.stringValue
            ))
        case "assistant.speech.final":
            kind = .assistantSpeechFinal(Event.SpeechFinal(
                text: try requireString("text"),
                liveResponseId: payload["liveResponseId"]?.stringValue
            ))
        case "assistant.audio.chunk":
            kind = .assistantAudioChunk(Event.AssistantAudioChunk(
                audio: try requireString("audio"),
                encoding: payload["encoding"]?.stringValue ?? "pcm_s16le",
                sampleRateHertz: payload["sampleRateHertz"]?.intValue ?? 16_000,
                channelCount: payload["channelCount"]?.intValue ?? 1,
                liveResponseId: payload["liveResponseId"]?.stringValue
            ))
        case "assistant.audio.end":
            kind = .assistantAudioEnd(Event.AssistantAudioEnd(
                liveResponseId: payload["liveResponseId"]?.stringValue
            ))
        case "assistant.audio.interrupted":
            kind = .assistantAudioInterrupted(Event.AssistantAudioInterrupted(
                reason: payload["reason"]?.stringValue ?? "unknown",
                liveResponseId: payload["liveResponseId"]?.stringValue
            ))
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
                status: payload["status"]?.stringValue ?? "online",
                workspaceRoot: payload["workspaceRoot"]?.stringValue
            ))
        case "bridge.status":
            kind = .bridgeStatus(Event.BridgeStatus(
                deviceId: try requireString("deviceId"),
                status: payload["status"]?.stringValue ?? "offline",
                lastSeen: payload["lastSeen"]?.stringValue
            ))
        case "bridge.exec.output":
            kind = .bridgeExecOutput(Event.BridgeExecOutput(
                deviceId: try requireString("deviceId"),
                commandId: try requireString("commandId"),
                stream: payload["stream"]?.stringValue ?? "stdout",
                chunk: payload["chunk"]?.stringValue ?? "",
                isFinal: payload["isFinal"]?.boolValue ?? false
            ))
        case "bridge.exec.finished":
            kind = .bridgeExecFinished(Event.BridgeExecFinished(
                deviceId: try requireString("deviceId"),
                commandId: try requireString("commandId"),
                exitCode: payload["exitCode"]?.intValue ?? -1,
                stdoutTail: payload["stdoutTail"]?.stringValue ?? "",
                stderrTail: payload["stderrTail"]?.stringValue ?? ""
            ))
        case "preferences.sync":
            var prefs: [String: String] = [:]
            if case .object(let obj) = payload["preferences"] {
                for (k, v) in obj {
                    if let s = v.stringValue { prefs[k] = s }
                }
            }
            kind = .preferencesSync(Event.PreferencesSync(preferences: prefs))
        case "bridge.device.selection.required":
            kind = .error(Event.ErrorInfo(
                code: "bridge_device_selection_required",
                message: "Multiple paired computers are available. Please choose one."
            ))
        case "gmail.send.execute":
            kind = .gmailSendExecute(Event.GmailSendExecute(
                callId: try requireString("callId"),
                confirmed: payload["confirmed"]?.boolValue ?? false,
                to: payload["to"]?.stringValue,
                cc: payload["cc"]?.stringValue,
                subject: payload["subject"]?.stringValue,
                body: payload["body"]?.stringValue,
                messageId: payload["messageId"]?.stringValue
            ))
        case "gmail.send.result":
            kind = .gmailSendResult(Event.GmailSendResult(
                callId: try requireString("callId"),
                success: payload["success"]?.boolValue ?? false,
                error: payload["error"]?.stringValue
            ))
        case "session.title":
            kind = .sessionTitle(Event.SessionTitle(title: try requireString("title")))
        case "calendar.mutation.execute":
            kind = .calendarMutationExecute(Event.CalendarMutationExecute(
                callId: try requireString("callId"),
                confirmed: payload["confirmed"]?.boolValue ?? false
            ))
        case "calendar.mutation.result":
            kind = .calendarMutationResult(Event.CalendarMutationResult(
                callId: try requireString("callId"),
                status: payload["status"]?.stringValue ?? "unknown",
                mutationType: payload["mutationType"]?.stringValue,
                error: payload["error"]?.stringValue
            ))
        case "assistant.image":
            kind = .assistantImage(Event.AssistantImage(
                imageBase64: try requireString("imageBase64"),
                mimeType: payload["mimeType"]?.stringValue ?? "image/png"
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

    private static func assistantLivePayload(base: [String: JSONValue], liveResponseId: String?) -> [String: JSONValue] {
        guard let liveResponseId else { return base }
        var payload = base
        payload["liveResponseId"] = .string(liveResponseId)
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
