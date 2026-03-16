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
        case userAudioStreamStart(UserAudioStreamStart)
        case userAudioStreamChunk(UserAudioStreamChunk)
        case userAudioStreamEnd(UserAudioStreamEnd)
        case assistantSpeechPartial(SpeechPartial)
        case assistantSpeechFinal(SpeechFinal)
        case assistantAudioChunk(AssistantAudioChunk)
        case assistantAudioEnd(AssistantAudioEnd)
        case assistantAudioInterrupted(AssistantAudioInterrupted)
        case assistantUIPatch(UIPatch)
        case agentStatus(AgentStatus)
        case audioOutputInterrupted(AudioOutputInterrupted)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case error(ErrorInfo)
        case agentCompleted(AgentCompleted)
        case agentConversation(AgentConversation)
        case bridgePairRequest(BridgePairRequest)
        case bridgePairPending(BridgePairPending)
        case bridgePaired(BridgePaired)
        case bridgeStatus(BridgeStatus)
        case bridgeExecOutput(BridgeExecOutput)
        case bridgeExecFinished(BridgeExecFinished)
        case preferencesSync(PreferencesSync)
        case bridgeWorkspaceSet(BridgeWorkspaceSet)
        case gmailSendExecute(GmailSendExecute)
        case gmailSendResult(GmailSendResult)
    }

    // MARK: - Payloads

    struct BridgeWorkspaceOverride: Codable, Sendable {
        let deviceId: String
        let workspacePath: String
    }

    struct SessionStart: Codable, Sendable {
        let sessionId: String
        let githubToken: String?
        let gmailAccessToken: String?
        let gmailRefreshToken: String?
        let gmailTokenExpiresAt: Double?
        let canvasAccessToken: String?
        let canvasBaseURL: String?
        let preferences: [String: String]?
        let memoryUserKey: String?
        let bridgeWorkspaceOverrides: [BridgeWorkspaceOverride]?
    }

    struct TranscriptPartial: Codable, Sendable {
        let text: String
    }

    struct TranscriptFinal: Codable, Sendable {
        let text: String
    }

    struct UserAudioStreamStart: Codable, Sendable {
        let encoding: String
        let sampleRateHertz: Int
        let channelCount: Int
    }

    struct UserAudioStreamChunk: Codable, Sendable {
        let audio: String
        let encoding: String
        let sampleRateHertz: Int
        let channelCount: Int
    }

    struct UserAudioStreamEnd: Codable, Sendable {
        let reason: String?
    }

    struct SpeechPartial: Codable, Sendable {
        let text: String
        let liveResponseId: String?

        init(text: String, liveResponseId: String? = nil) {
            self.text = text
            self.liveResponseId = liveResponseId
        }
    }

    struct SpeechFinal: Codable, Sendable {
        let text: String
        let liveResponseId: String?

        init(text: String, liveResponseId: String? = nil) {
            self.text = text
            self.liveResponseId = liveResponseId
        }
    }

    struct AssistantAudioChunk: Codable, Sendable {
        let audio: String
        let encoding: String
        let sampleRateHertz: Int
        let channelCount: Int
        let liveResponseId: String?

        init(
            audio: String,
            encoding: String,
            sampleRateHertz: Int,
            channelCount: Int,
            liveResponseId: String? = nil
        ) {
            self.audio = audio
            self.encoding = encoding
            self.sampleRateHertz = sampleRateHertz
            self.channelCount = channelCount
            self.liveResponseId = liveResponseId
        }
    }

    struct AssistantAudioEnd: Codable, Sendable {
        let liveResponseId: String?

        init(liveResponseId: String? = nil) {
            self.liveResponseId = liveResponseId
        }
    }

    struct AssistantAudioInterrupted: Codable, Sendable {
        let reason: String
        let liveResponseId: String?

        init(reason: String, liveResponseId: String? = nil) {
            self.reason = reason
            self.liveResponseId = liveResponseId
        }
    }

    struct UIPatch: Codable, Sendable {
        let patch: String
    }

    struct AgentStatus: Codable, Sendable {
        let agentId: String?
        let status: String
        let detail: String?
        let summary: String?
        let runUrl: String?
        let prUrl: String?
        let branchName: String?
        let webhookDriven: Bool?
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

    struct AgentCompleted: Codable, Sendable {
        let agentId: String
        let status: String      // "FINISHED" or "FAILED"
        let summary: String     // may be empty string
        let name: String?       // agent display name
        let prompt: String?     // original task prompt
    }

    struct AgentConversationMessage: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let type: String   // "user_message" or "assistant_message"
        let text: String
    }

    struct AgentConversation: Codable, Sendable {
        let agentId: String
        let messages: [AgentConversationMessage]
    }

    struct BridgePairPending: Codable, Sendable {
        let pairingCode: String
        let expiresInSec: Int?
    }

    struct BridgePairRequest: Codable, Sendable {
        let pairingCode: String
        let deviceName: String?
    }

    struct BridgePaired: Codable, Sendable {
        let deviceId: String
        let deviceName: String
        let status: String
        let workspaceRoot: String?
    }

    struct BridgeStatus: Codable, Sendable {
        let deviceId: String
        let status: String
        let lastSeen: String?
    }

    struct BridgeExecOutput: Codable, Sendable {
        let deviceId: String
        let commandId: String
        let stream: String
        let chunk: String
        let isFinal: Bool
    }

    struct BridgeExecFinished: Codable, Sendable {
        let deviceId: String
        let commandId: String
        let exitCode: Int
        let stdoutTail: String
        let stderrTail: String
    }

    struct PreferencesSync: Codable, Sendable {
        let preferences: [String: String]
    }

    struct BridgeWorkspaceSet: Codable, Sendable {
        let deviceId: String
        let workspacePath: String
    }

    struct GmailSendExecute: Codable, Sendable {
        let callId: String
        let confirmed: Bool
        let to: String?
        let subject: String?
        let body: String?
        let cc: String?
    }

    struct GmailSendResult: Codable, Sendable {
        let callId: String
        let status: String
        let error: String?
    }
}

// MARK: - Convenience Factories

extension Event {
    static func sessionStart(
        sessionId: String = UUID().uuidString,
        githubToken: String? = nil,
        gmailAccessToken: String? = nil,
        gmailRefreshToken: String? = nil,
        gmailTokenExpiresAt: Double? = nil,
        canvasAccessToken: String? = nil,
        canvasBaseURL: String? = nil,
        preferences: [String: String]? = nil,
        memoryUserKey: String? = nil,
        bridgeWorkspaceOverrides: [BridgeWorkspaceOverride]? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .sessionStart(SessionStart(
            sessionId: sessionId,
            githubToken: githubToken,
            gmailAccessToken: gmailAccessToken,
            gmailRefreshToken: gmailRefreshToken,
            gmailTokenExpiresAt: gmailTokenExpiresAt,
            canvasAccessToken: canvasAccessToken,
            canvasBaseURL: canvasBaseURL,
            preferences: preferences,
            memoryUserKey: memoryUserKey,
            bridgeWorkspaceOverrides: bridgeWorkspaceOverrides
        )))
    }

    static func preferencesSync(preferences: [String: String], sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .preferencesSync(PreferencesSync(preferences: preferences)))
    }

    static func transcriptPartial(_ text: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .userAudioTranscriptPartial(TranscriptPartial(text: text)))
    }

    static func transcriptFinal(_ text: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .userAudioTranscriptFinal(TranscriptFinal(text: text)))
    }

    static func userAudioStreamStart(
        encoding: String = "pcm_s16le",
        sampleRateHertz: Int = 16_000,
        channelCount: Int = 1,
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .userAudioStreamStart(UserAudioStreamStart(
            encoding: encoding,
            sampleRateHertz: sampleRateHertz,
            channelCount: channelCount
        )))
    }

    static func userAudioStreamChunk(
        audio: String,
        encoding: String = "pcm_s16le",
        sampleRateHertz: Int = 16_000,
        channelCount: Int = 1,
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .userAudioStreamChunk(UserAudioStreamChunk(
            audio: audio,
            encoding: encoding,
            sampleRateHertz: sampleRateHertz,
            channelCount: channelCount
        )))
    }

    static func userAudioStreamEnd(reason: String? = nil, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .userAudioStreamEnd(UserAudioStreamEnd(reason: reason)))
    }

    static func speechPartial(_ text: String, liveResponseId: String? = nil, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantSpeechPartial(SpeechPartial(text: text, liveResponseId: liveResponseId)))
    }

    static func speechFinal(_ text: String, liveResponseId: String? = nil, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantSpeechFinal(SpeechFinal(text: text, liveResponseId: liveResponseId)))
    }

    static func assistantAudioChunk(
        audio: String,
        encoding: String = "pcm_s16le",
        sampleRateHertz: Int = 16_000,
        channelCount: Int = 1,
        liveResponseId: String? = nil,
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .assistantAudioChunk(AssistantAudioChunk(
            audio: audio,
            encoding: encoding,
            sampleRateHertz: sampleRateHertz,
            channelCount: channelCount,
            liveResponseId: liveResponseId
        )))
    }

    static func assistantAudioEnd(liveResponseId: String? = nil, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantAudioEnd(AssistantAudioEnd(liveResponseId: liveResponseId)))
    }

    static func assistantAudioInterrupted(
        _ reason: String = "unknown",
        liveResponseId: String? = nil,
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .assistantAudioInterrupted(AssistantAudioInterrupted(
            reason: reason,
            liveResponseId: liveResponseId
        )))
    }

    static func uiPatch(_ patch: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .assistantUIPatch(UIPatch(patch: patch)))
    }

    static func agentStatus(
        _ status: String,
        detail: String? = nil,
        sessionId: String? = nil,
        agentId: String? = nil,
        summary: String? = nil,
        runUrl: String? = nil,
        prUrl: String? = nil,
        branchName: String? = nil,
        webhookDriven: Bool? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .agentStatus(AgentStatus(
            agentId: agentId,
            status: status,
            detail: detail,
            summary: summary,
            runUrl: runUrl,
            prUrl: prUrl,
            branchName: branchName,
            webhookDriven: webhookDriven
        )))
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

    static func agentCompleted(
        agentId: String,
        status: String,
        summary: String,
        name: String?,
        prompt: String?,
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .agentCompleted(AgentCompleted(
            agentId: agentId, status: status, summary: summary, name: name, prompt: prompt
        )))
    }

    static func agentConversation(
        agentId: String,
        messages: [AgentConversationMessage],
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .agentConversation(AgentConversation(
            agentId: agentId, messages: messages
        )))
    }

    static func bridgePairRequest(code: String, deviceName: String?, sessionId: String? = nil) -> Event {
        let payload = BridgePairRequest(pairingCode: code, deviceName: deviceName)
        return Event(sessionId: sessionId, kind: .bridgePairRequest(payload))
    }

    static func bridgeWorkspaceSet(deviceId: String, workspacePath: String, sessionId: String? = nil) -> Event {
        Event(sessionId: sessionId, kind: .bridgeWorkspaceSet(BridgeWorkspaceSet(deviceId: deviceId, workspacePath: workspacePath)))
    }

    static func gmailSendExecute(
        callId: String,
        confirmed: Bool,
        to: String? = nil,
        subject: String? = nil,
        body: String? = nil,
        cc: String? = nil,
        sessionId: String? = nil
    ) -> Event {
        Event(sessionId: sessionId, kind: .gmailSendExecute(GmailSendExecute(
            callId: callId,
            confirmed: confirmed,
            to: to,
            subject: subject,
            body: body,
            cc: cc
        )))
    }
}

// MARK: - Display Helpers

extension Event.Kind {
    var displayName: String {
        switch self {
        case .sessionStart: return "session.start"
        case .userAudioTranscriptPartial: return "user.audio.transcript.partial"
        case .userAudioTranscriptFinal: return "user.audio.transcript.final"
        case .userAudioStreamStart: return "user.audio.stream.start"
        case .userAudioStreamChunk: return "user.audio.stream.chunk"
        case .userAudioStreamEnd: return "user.audio.stream.end"
        case .assistantSpeechPartial: return "assistant.speech.partial"
        case .assistantSpeechFinal: return "assistant.speech.final"
        case .assistantAudioChunk: return "assistant.audio.chunk"
        case .assistantAudioEnd: return "assistant.audio.end"
        case .assistantAudioInterrupted: return "assistant.audio.interrupted"
        case .assistantUIPatch: return "assistant.ui.patch"
        case .agentStatus: return "agent.status"
        case .audioOutputInterrupted: return "audio.output.interrupted"
        case .toolCall(let tc): return "tool.call: \(tc.name)"
        case .toolResult(let tr): return tr.isError ? "tool.result: ERROR" : "tool.result: OK"
        case .error(let e): return "error: \(e.code)"
        case .agentCompleted(let ac): return "agent.completed: \(ac.agentId)"
        case .agentConversation(let c): return "agent.conversation: \(c.agentId) (+\(c.messages.count))"
        case .bridgePairRequest:
            return "bridge.pair.request"
        case .bridgePairPending(let payload): return "bridge.pair.pending: \(payload.pairingCode)"
        case .bridgePaired(let payload): return "bridge.paired: \(payload.deviceName)"
        case .bridgeStatus(let payload): return "bridge.status: \(payload.status)"
        case .bridgeExecOutput(let payload): return "bridge.exec.output: \(payload.commandId.prefix(8))"
        case .bridgeExecFinished(let payload): return "bridge.exec.finished: \(payload.commandId.prefix(8))"
        case .preferencesSync: return "preferences.sync"
        case .bridgeWorkspaceSet(let payload): return "bridge.workspace.set: \(payload.deviceId)"
        case .gmailSendExecute(let payload): return "gmail.send.execute: \(payload.callId.prefix(8))"
        case .gmailSendResult(let payload): return "gmail.send.result: \(payload.status)"
        }
    }
}
