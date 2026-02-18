# Abyss Phase 2 Architecture

## Overview

Phase 2 replaces the local-only conductor path with a real WebSocket conductor service.

- iOS remains the only executor of client tools (`stt.*`, `tts.*`, `convo.*`).
- Backend drives behavior by emitting `tool.call` and `assistant.speech.*` events.
- iOS executes `tool.call` via `ToolRouter` and sends `tool.result` back to the backend.
- Local barge-in remains immediate and local-first (`tts.stop` before `stt.start`).

## Sequence

```mermaid
sequenceDiagram
    participant User
    participant iOS as "iOS App (EventBus + ToolRouter)"
    participant WS as "WS Conductor Server"
    participant LLM as "Claude (Anthropic API)"

    User->>iOS: Speak
    iOS->>iOS: STT (WhisperKit) final transcript
    iOS->>WS: user.audio.transcript.final

    WS->>WS: Update session history
    WS->>LLM: generate response
    LLM-->>WS: response text/chunks

    WS->>iOS: tool.call(convo.setState thinking)
    iOS->>iOS: Execute tool
    iOS->>WS: tool.result

    WS->>iOS: tool.call(convo.appendMessage user)
    iOS->>WS: tool.result

    loop Streaming
      WS->>iOS: assistant.speech.partial
    end
    WS->>iOS: assistant.speech.final

    WS->>iOS: tool.call(convo.appendMessage assistant)
    iOS->>WS: tool.result

    WS->>iOS: tool.call(convo.setState speaking)
    iOS->>WS: tool.result

    WS->>iOS: tool.call(tts.speak)
    iOS->>iOS: ElevenLabs playback
    iOS->>WS: tool.result

    WS->>iOS: tool.call(convo.setState idle)
    iOS->>WS: tool.result
```

## Tool Responsibility Boundary

Client tools (executed only on iOS):

- `stt.start`, `stt.stop`
- `tts.speak`, `tts.stop`
- `convo.appendMessage`, `convo.setState`

Server responsibilities:

- Decide event/tool sequence
- Emit `assistant.speech.partial/final`
- Emit `tool.call` in ordered steps
- Accept and log `tool.result`
- Maintain session memory + pending tool calls

## Provider Abstraction

Server provider interface:

- `ModelProvider.generateResponse(conversation) -> { fullText, chunks }`

Implementations:

- `AnthropicProvider` (active): uses `ANTHROPIC_API_KEY` and Claude model config
- `BedrockNovaProvider` (scaffold): placeholder for later cutover

Switching providers is config-only:

- `MODEL_PROVIDER=anthropic` (current)
- `MODEL_PROVIDER=bedrock` (future)

This keeps Bedrock re-entry low-risk once rate limits are resolved.
