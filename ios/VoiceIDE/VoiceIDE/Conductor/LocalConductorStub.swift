import Foundation

/// Deterministic local conductor for Phase 1.
/// Proves the tool-calling pipeline without any backend.
/// Same input always produces the same output sequence.
struct LocalConductorStub: Conductor {
    private enum AgentSpawnCall {
        static let name = "agent.spawn"

        struct Arguments: Codable {
            let prompt: String
            let repository: String?
            let ref: String?
            let prUrl: String?
            let model: String?
            let autoCreatePr: Bool?
            let openAsCursorGithubApp: Bool?
            let skipReviewerRequest: Bool?
            let branchName: String?
            let autoBranch: Bool?
        }
    }

    private enum AgentStatusCall {
        static let name = "agent.status"

        struct Arguments: Codable {
            let id: String
        }
    }

    private enum AgentCancelCall {
        static let name = "agent.cancel"

        struct Arguments: Codable {
            let id: String
        }
    }

    private enum AgentListCall {
        static let name = "agent.list"

        struct Arguments: Codable {
            let limit: Int?
            let cursor: String?
            let prUrl: String?
        }
    }

    private enum AgentFollowUpCall {
        static let name = "agent.followup"

        struct Arguments: Codable {
            let id: String
            let prompt: String
        }
    }

    private struct AgentSpawnIntent {
        let repositoryURL: String?
        let prURL: String?
        let prompt: String
        let autoCreatePR: Bool
    }

    private enum AgentIntent {
        case spawn(AgentSpawnIntent)
        case status(agentID: String)
        case cancel(agentID: String)
        case listRecent
        case followUp(agentID: String, prompt: String)
    }

    func handleSessionStart() async -> [Event] {
        [Event.sessionStart()]
    }

    func handleTranscript(_ transcript: String) async -> [Event] {
        if let intent = parseAgentIntent(from: transcript) {
            switch intent {
            case .spawn(let spawnIntent):
                return makeSpawnAgentEventSequence(transcript: transcript, intent: spawnIntent)
            case .status(let agentID):
                return makeAgentActionEventSequence(
                    transcript: transcript,
                    actionSuffix: "agent-status",
                    toolName: AgentStatusCall.name,
                    arguments: encode(AgentStatusCall.Arguments(id: agentID)),
                    responseText: "Checking status for agent \(agentID). I will update the progress card if one is visible."
                )
            case .cancel(let agentID):
                return makeAgentActionEventSequence(
                    transcript: transcript,
                    actionSuffix: "agent-cancel",
                    toolName: AgentCancelCall.name,
                    arguments: encode(AgentCancelCall.Arguments(id: agentID)),
                    responseText: "Stopping agent \(agentID) now."
                )
            case .listRecent:
                return makeAgentActionEventSequence(
                    transcript: transcript,
                    actionSuffix: "agent-list",
                    toolName: AgentListCall.name,
                    arguments: encode(AgentListCall.Arguments(limit: 10, cursor: nil, prUrl: nil)),
                    responseText: "Listing your recent Cursor agents now."
                )
            case .followUp(let agentID, let prompt):
                return makeAgentActionEventSequence(
                    transcript: transcript,
                    actionSuffix: "agent-followup",
                    toolName: AgentFollowUpCall.name,
                    arguments: encode(AgentFollowUpCall.Arguments(id: agentID, prompt: prompt)),
                    responseText: "Sending your follow-up to agent \(agentID)."
                )
            }
        }

        let responseText = generateResponse(for: transcript)
        return makeStandardResponseEventSequence(transcript: transcript, responseText: responseText)
    }

    // MARK: - Deterministic Response

    /// Generates a deterministic response based on the input transcript.
    private func generateResponse(for transcript: String) -> String {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lowered.isEmpty {
            return "I didn't hear anything. Tap the mic, speak clearly, then tap again when you're done. Make sure you've allowed microphone access in Settings."
        }

        if lowered.contains("hello") || lowered.contains("hi") {
            return "Hello! I'm your voice assistant. How can I help you today?"
        }

        if lowered.contains("help") {
            return "I can help you with voice commands. In a future update, I'll be able to edit code, browse the web, and much more."
        }

        if lowered.contains("test") {
            return "The tool pipeline is working correctly. I received your message and I'm responding through the formal tool-calling system."
        }

        if lowered.contains("what can you do") || lowered.contains("capabilities") {
            return "Right now I'm a Phase 1 prototype. I can listen to your voice, transcribe it, and respond. In Phase 2, I'll gain code editing, web browsing, and agentic capabilities."
        }

        // Default echo response
        return "You said: \(transcript). I'm a local stub, and I will invoke tools when your request maps to an available capability."
    }

    private func makeStandardResponseEventSequence(transcript: String, responseText: String) -> [Event] {
        let setThinkingCallId = stableId(transcript, suffix: "setState-thinking")
        let appendUserCallId = stableId(transcript, suffix: "appendUser")
        let appendAssistantCallId = stableId(transcript, suffix: "appendAssistant")
        let setSpeakingCallId = stableId(transcript, suffix: "setState-speaking")
        let ttsSpeakCallId = stableId(transcript, suffix: "ttsSpeak")
        let setIdleCallId = stableId(transcript, suffix: "setState-idle")

        return [
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "thinking")),
                callId: setThinkingCallId
            ),
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: encode(ConvoAppendMessageTool.Arguments(
                    role: "user",
                    text: transcript,
                    isPartial: false
                )),
                callId: appendUserCallId
            ),
            Event.speechFinal(responseText),
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: encode(ConvoAppendMessageTool.Arguments(
                    role: "assistant",
                    text: responseText,
                    isPartial: false
                )),
                callId: appendAssistantCallId
            ),
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "speaking")),
                callId: setSpeakingCallId
            ),
            Event.toolCall(
                name: "tts.speak",
                arguments: encode(TTSSpeakTool.Arguments(text: responseText)),
                callId: ttsSpeakCallId
            ),
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "idle")),
                callId: setIdleCallId
            ),
        ]
    }

    private func makeSpawnAgentEventSequence(transcript: String, intent: AgentSpawnIntent) -> [Event] {
        let responseSource = sourceLabel(repository: intent.repositoryURL, prURL: intent.prURL)
        let responseText = "Starting a Cursor cloud agent for \(responseSource). I'll show a live progress card as it works."

        let arguments = AgentSpawnCall.Arguments(
            prompt: intent.prompt,
            repository: intent.repositoryURL,
            ref: intent.repositoryURL != nil ? "main" : nil,
            prUrl: intent.prURL,
            model: nil,
            autoCreatePr: intent.autoCreatePR,
            openAsCursorGithubApp: nil,
            skipReviewerRequest: nil,
            branchName: nil,
            autoBranch: nil
        )

        return makeAgentActionEventSequence(
            transcript: transcript,
            actionSuffix: "agent-spawn",
            toolName: AgentSpawnCall.name,
            arguments: encode(arguments),
            responseText: responseText
        )
    }

    private func makeAgentActionEventSequence(
        transcript: String,
        actionSuffix: String,
        toolName: String,
        arguments: String,
        responseText: String
    ) -> [Event] {
        let setThinkingCallId = stableId(transcript, suffix: "setState-thinking")
        let appendUserCallId = stableId(transcript, suffix: "appendUser")
        let actionCallId = stableId(transcript, suffix: actionSuffix)
        let appendAssistantCallId = stableId(transcript, suffix: "appendAssistant")
        let setSpeakingCallId = stableId(transcript, suffix: "setState-speaking")
        let ttsSpeakCallId = stableId(transcript, suffix: "ttsSpeak")
        let setIdleCallId = stableId(transcript, suffix: "setState-idle")

        return [
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "thinking")),
                callId: setThinkingCallId
            ),
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: encode(ConvoAppendMessageTool.Arguments(
                    role: "user",
                    text: transcript,
                    isPartial: false
                )),
                callId: appendUserCallId
            ),
            Event.toolCall(
                name: toolName,
                arguments: arguments,
                callId: actionCallId
            ),
            Event.speechFinal(responseText),
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: encode(ConvoAppendMessageTool.Arguments(
                    role: "assistant",
                    text: responseText,
                    isPartial: false
                )),
                callId: appendAssistantCallId
            ),
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "speaking")),
                callId: setSpeakingCallId
            ),
            Event.toolCall(
                name: "tts.speak",
                arguments: encode(TTSSpeakTool.Arguments(text: responseText)),
                callId: ttsSpeakCallId
            ),
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "idle")),
                callId: setIdleCallId
            ),
        ]
    }

    private func parseAgentIntent(from transcript: String) -> AgentIntent? {
        if let followUpIntent = parseAgentFollowUpIntent(from: transcript) {
            return followUpIntent
        }

        if let cancelIntent = parseAgentCancelIntent(from: transcript) {
            return cancelIntent
        }

        if let statusIntent = parseAgentStatusIntent(from: transcript) {
            return statusIntent
        }

        if parseAgentListIntent(from: transcript) {
            return .listRecent
        }

        if let spawnIntent = parseAgentSpawnIntent(from: transcript) {
            return .spawn(spawnIntent)
        }

        return nil
    }

    private func parseAgentSpawnIntent(from transcript: String) -> AgentSpawnIntent? {
        let lowered = transcript.lowercased()
        let hasSpawnVerb = containsAny(in: lowered, terms: ["spawn", "start", "launch", "create", "run"])
        let mentionsAgent = lowered.contains("agent") || lowered.contains("cursor")
        let hasCodingIntent = containsAny(
            in: lowered,
            terms: ["fix", "implement", "debug", "review", "refactor", "update", "write", "add", "remove", "investigate", "test", "improve"]
        )

        guard hasSpawnVerb || mentionsAgent || hasCodingIntent else { return nil }

        let source: (raw: String, normalized: String, isPR: Bool)?
        if let prMatch = firstGitHubPullRequestURL(in: transcript) {
            source = (raw: prMatch.raw, normalized: prMatch.normalized, isPR: true)
        } else if let repositoryMatch = firstGitHubRepositoryURL(in: transcript) {
            source = (raw: repositoryMatch.raw, normalized: repositoryMatch.normalized, isPR: false)
        } else {
            source = nil
        }

        guard let source else { return nil }

        let autoCreatePR = lowered.contains("pull request")
            || lowered.contains("create pr")
            || lowered.contains("open pr")

        let prompt = extractPrompt(from: transcript, sourceURL: source.raw)

        return AgentSpawnIntent(
            repositoryURL: source.isPR ? nil : source.normalized,
            prURL: source.isPR ? source.normalized : nil,
            prompt: prompt,
            autoCreatePR: autoCreatePR
        )
    }

    private func parseAgentStatusIntent(from transcript: String) -> AgentIntent? {
        let lowered = transcript.lowercased()
        let requestsStatus = containsAny(in: lowered, terms: ["status", "progress", "state", "check on"])
        guard requestsStatus else { return nil }

        guard let agentID = firstAgentID(in: transcript) else { return nil }
        return .status(agentID: agentID)
    }

    private func parseAgentCancelIntent(from transcript: String) -> AgentIntent? {
        let lowered = transcript.lowercased()
        let requestsCancellation = containsAny(in: lowered, terms: ["cancel", "stop", "terminate", "kill"])
        guard requestsCancellation else { return nil }

        guard let agentID = firstAgentID(in: transcript) else { return nil }
        return .cancel(agentID: agentID)
    }

    private func parseAgentListIntent(from transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        return lowered.contains("list agents")
            || lowered.contains("show agents")
            || lowered.contains("my agents")
            || lowered.contains("recent agents")
    }

    private func parseAgentFollowUpIntent(from transcript: String) -> AgentIntent? {
        let lowered = transcript.lowercased()
        let requestsFollowUp = lowered.contains("follow up")
            || lowered.contains("followup")
            || lowered.contains("continue agent")
        guard requestsFollowUp else { return nil }

        guard let agentID = firstAgentID(in: transcript) else { return nil }

        let prompt: String
        if let toRange = lowered.range(of: " to ") {
            let candidate = transcript[toRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = candidate.isEmpty ? "Continue with the task and report progress." : candidate
        } else {
            prompt = "Continue with the task and report progress."
        }

        return .followUp(agentID: agentID, prompt: prompt)
    }

    private func extractPrompt(from transcript: String, sourceURL: String) -> String {
        let lowered = transcript.lowercased()
        if let toRange = lowered.range(of: " to ") {
            let candidate = transcript[toRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        let trimmed = transcript
            .replacingOccurrences(of: sourceURL, with: "")
            .replacingOccurrences(of: "spawn", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "start", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "launch", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "create", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "run", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "cursor", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "cloud", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "agent", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedPrompt = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if !normalizedPrompt.isEmpty {
            return normalizedPrompt
        }

        return "Review the repository and complete the requested work."
    }

    private func firstGitHubRepositoryURL(in transcript: String) -> (raw: String, normalized: String)? {
        let pattern = #"(?<![A-Za-z0-9.-])(?:https?://)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"#
        return firstMatchURL(in: transcript, pattern: pattern)
    }

    private func firstGitHubPullRequestURL(in transcript: String) -> (raw: String, normalized: String)? {
        let pattern = #"(?<![A-Za-z0-9.-])(?:https?://)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+"#
        return firstMatchURL(in: transcript, pattern: pattern)
    }

    private func firstMatchURL(in transcript: String, pattern: String) -> (raw: String, normalized: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let match = regex.firstMatch(in: transcript, options: [], range: range),
              let matchRange = Range(match.range, in: transcript) else {
            return nil
        }

        let rawURL = String(transcript[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        var normalizedURL = rawURL
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://\(normalizedURL)"
        }
        return (raw: rawURL, normalized: normalizedURL)
    }

    private func sourceLabel(repository: String?, prURL: String?) -> String {
        if let repositoryName = shortRepositoryName(from: repository) {
            return repositoryName
        }

        if let prName = shortRepositoryName(from: prURL) {
            return "\(prName) pull request"
        }

        return repository ?? prURL ?? "the repository"
    }

    private func shortRepositoryName(from repository: String?) -> String? {
        guard let repository, let url = URL(string: repository) else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count >= 2 else { return nil }
        return "\(comps[0])/\(comps[1])"
    }

    private func firstAgentID(in transcript: String) -> String? {
        let pattern = #"\b[a-z]{2}_[A-Za-z0-9_-]{3,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let match = regex.firstMatch(in: transcript, options: [], range: range),
              let matchRange = Range(match.range, in: transcript) else {
            return nil
        }
        return String(transcript[matchRange])
    }

    private func containsAny(in text: String, terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    // MARK: - Helpers

    /// Produce a stable deterministic ID from transcript + suffix.
    private func stableId(_ transcript: String, suffix: String) -> String {
        let input = "\(transcript):\(suffix)"
        // Simple deterministic hash-based ID
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
