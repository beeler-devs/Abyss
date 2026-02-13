import Foundation

/// Deterministic local conductor for Phase 1.
/// Proves the tool-calling pipeline without any backend.
/// Same input always produces the same output sequence.
struct LocalConductorStub: Conductor {

    func handleSessionStart() async -> [Event] {
        [Event.sessionStart()]
    }

    func handleTranscript(_ transcript: String) async -> [Event] {
        let responseText = generateResponse(for: transcript)

        // Build the event sequence that a real conductor would emit:
        // 1. Set state to Thinking
        // 2. Append user message
        // 3. Emit assistant speech
        // 4. Append assistant message
        // 5. Set state to Speaking
        // 6. Speak via TTS
        // 7. Set state to Idle

        let setThinkingCallId = stableId(transcript, suffix: "setState-thinking")
        let appendUserCallId = stableId(transcript, suffix: "appendUser")
        let appendAssistantCallId = stableId(transcript, suffix: "appendAssistant")
        let setSpeakingCallId = stableId(transcript, suffix: "setState-speaking")
        let ttsSpeakCallId = stableId(transcript, suffix: "ttsSpeak")
        let setIdleCallId = stableId(transcript, suffix: "setState-idle")

        return [
            // 1. Transition to Thinking
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "thinking")),
                callId: setThinkingCallId
            ),

            // 2. Append user message to conversation
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: encode(ConvoAppendMessageTool.Arguments(
                    role: "user",
                    text: transcript,
                    isPartial: false
                )),
                callId: appendUserCallId
            ),

            // 3. Emit final speech event
            Event.speechFinal(responseText),

            // 4. Append assistant message
            Event.toolCall(
                name: "convo.appendMessage",
                arguments: encode(ConvoAppendMessageTool.Arguments(
                    role: "assistant",
                    text: responseText,
                    isPartial: false
                )),
                callId: appendAssistantCallId
            ),

            // 5. Set state to Speaking
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "speaking")),
                callId: setSpeakingCallId
            ),

            // 6. Speak via TTS
            Event.toolCall(
                name: "tts.speak",
                arguments: encode(TTSSpeakTool.Arguments(text: responseText)),
                callId: ttsSpeakCallId
            ),

            // 7. Return to Idle
            Event.toolCall(
                name: "convo.setState",
                arguments: encode(ConvoSetStateTool.Arguments(state: "idle")),
                callId: setIdleCallId
            ),
        ]
    }

    // MARK: - Deterministic Response

    /// Generates a deterministic response based on the input transcript.
    private func generateResponse(for transcript: String) -> String {
        let lowered = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lowered.isEmpty {
            return "I didn't catch that. Could you try again?"
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
        return "You said: \(transcript). I'm a local stub — in Phase 2, a real AI conductor will generate responses."
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
