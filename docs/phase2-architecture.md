# VoiceIDE Architecture — Phase 2: Cloud Conductor

## Overview

Phase 2 replaces the `LocalConductorStub` with a real cloud conductor powered by **Amazon Bedrock Nova 2 Lite**. The conductor runs as a serverless WebSocket backend on AWS (API Gateway + Lambda + DynamoDB), while the iOS app retains its existing tool-calling architecture unchanged.

## Architecture Diagram

```
┌───────────────────────────────────────────────────────────────────┐
│                         iOS App (SwiftUI)                         │
│                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │  ConversationVM   │  │   ToolRouter     │  │   EventBus     │ │
│  │                   │  │                  │  │                │ │
│  │ transcript.final──┼──┼─► WS send ──────┼──┼─► timeline     │ │
│  │ ◄── inbound ──────┼──┼── tool.call ◄───┼──┼── append       │ │
│  │ tool.result ──────┼──┼─► WS send ──────┼──┼─► append       │ │
│  └──────┬───────────┘  └──────┬───────────┘  └────────────────┘ │
│         │                      │                                  │
│  ┌──────┴───────────┐  ┌──────┴───────────┐                     │
│  │ WebSocket         │  │  Tool Registry   │                     │
│  │ ConductorClient   │  │  stt.* tts.*     │                     │
│  │                   │  │  convo.*          │                     │
│  └──────┬───────────┘  └──────────────────┘                     │
└─────────┼─────────────────────────────────────────────────────────┘
          │ wss://
          │
┌─────────┼─────────────────────────────────────────────────────────┐
│         ▼                    AWS Cloud                             │
│  ┌──────────────────────────────────────┐                        │
│  │    API Gateway WebSocket API         │                        │
│  │    Routes: $connect, $disconnect,    │                        │
│  │            sendMessage (default)     │                        │
│  └──────┬──────────┬──────────┬────────┘                        │
│         │          │          │                                    │
│  ┌──────┴──┐ ┌─────┴───┐ ┌───┴────────────────────┐            │
│  │ Connect │ │Disconnect│ │   Message Lambda        │            │
│  │ Lambda  │ │ Lambda   │ │                         │            │
│  │         │ │          │ │  ┌──────────────────┐   │            │
│  │ Store   │ │ Delete   │ │  │   Conductor      │   │            │
│  │ connId  │ │ connId   │ │  │   Orchestrator   │   │            │
│  └────┬────┘ └────┬─────┘ │  │                  │   │            │
│       │           │        │  │  transcript ──►  │   │            │
│       │           │        │  │  Bedrock Stream  │   │            │
│       │           │        │  │  ◄── tool_call   │   │            │
│       │           │        │  │  ──► forward     │   │            │
│       │           │        │  │  ◄── tool.result │   │            │
│       │           │        │  │  ──► resume      │   │            │
│       │           │        │  └──────┬───────────┘   │            │
│       │           │        └─────────┼───────────────┘            │
│       │           │                  │                             │
│  ┌────┴───────────┴──────────────────┴────────────────────┐      │
│  │                   DynamoDB                              │      │
│  │                                                         │      │
│  │  Connections: connectionId → sessionId                  │      │
│  │  Sessions:    sessionId → conversation[], timestamps    │      │
│  │  Pending:     sessionId → pendingCallId, bedrockToolId  │      │
│  └─────────────────────────────────────────────────────────┘      │
│                                                                    │
│  ┌─────────────────────────────────────┐                          │
│  │     Amazon Bedrock                   │                          │
│  │     Nova 2 Lite (ConverseStream)     │                          │
│  │     + tool_call tool configuration   │                          │
│  └─────────────────────────────────────┘                          │
└────────────────────────────────────────────────────────────────────┘
```

## Sequence Diagram: Full Turn

```
    iOS Client                   Backend (Lambda)              Bedrock Nova
        │                              │                           │
   User speaks                         │                           │
        │                              │                           │
   WhisperKit STT                      │                           │
        │                              │                           │
   transcript.final ──────────────────►│                           │
        │                              │                           │
        │                      Get/create session                  │
        │                      Build conversation                  │
        │                              │                           │
        │                              │── ConverseStream ────────►│
        │                              │                           │
        │                              │◄── text delta ────────────│
        │◄── assistant.speech.partial ─│                           │
        │                              │◄── text delta ────────────│
        │◄── assistant.speech.partial ─│                           │
        │                              │                           │
        │                              │◄── tool_use: tool_call ──│
        │                              │    {name:"convo.setState",│
        │                              │     args:{state:"thinking"}}
        │                              │                           │
        │                      Save pending state                  │
        │                      Save conversation                   │
        │                              │                           │
        │◄── tool.call ───────────────│    (stream paused)        │
        │    convo.setState            │                           │
        │    {state:"thinking"}        │                           │
        │                              │                           │
   ToolRouter executes                 │                           │
   convo.setState                      │                           │
        │                              │                           │
   tool.result ───────────────────────►│                           │
        │                              │                           │
        │                      Clear pending state                 │
        │                      Build toolResult message            │
        │                              │                           │
        │                              │── ConverseStream ────────►│
        │                              │   (with toolResult)       │
        │                              │                           │
        │                              │◄── tool_use: tool_call ──│
        │                              │    {name:"tts.speak",     │
        │                              │     args:{text:"Hello!"}} │
        │                              │                           │
        │◄── tool.call ───────────────│                           │
        │    tts.speak {text:"Hello!"} │                           │
        │                              │                           │
   ElevenLabs TTS plays               │                           │
        │                              │                           │
   tool.result ───────────────────────►│                           │
        │                              │── ConverseStream ────────►│
        │                              │◄── end_turn ─────────────│
        │                              │                           │
        │                      Save final conversation             │
        │                              │                           │
   Done                                │                           │
```

## How tool_call Maps to app tool.call Events

Bedrock uses a single tool named `"tool_call"` with an input schema of:
```json
{
  "name": "convo.setState",
  "arguments": { "state": "thinking" },
  "call_id": "unique-id"
}
```

The backend:
1. Receives this as a Bedrock `toolUse` block
2. Extracts `name`, `arguments`, and `call_id` from the input
3. Creates a VoiceIDE `tool.call` wire event
4. Forwards it to the iOS client over WebSocket

The iOS client:
1. Receives the `tool.call` event
2. Dispatches it through the existing `ToolRouter`
3. Gets a `tool.result` back
4. Sends the `tool.result` to the backend over WebSocket

The backend:
1. Creates a Bedrock `toolResult` content block
2. Resumes `ConverseStream` with the result
3. Model continues generating

## Key Design Decisions

### Why a Single "tool_call" Wrapper?

Bedrock's tool system is designed for server-side execution. Our tools execute on the client. Using a single wrapper tool lets the model express any client tool call through a standard interface, while the backend acts purely as a router — never executing tools itself.

### Why DynamoDB for Pending State?

Lambda invocations are stateless. When the model emits a tool_call, the Lambda invocation ends (stream paused). A new Lambda invocation handles the incoming tool.result. DynamoDB bridges these invocations with the `Pending` table.

### Why Not Keep the Bedrock Stream Open?

API Gateway WebSocket + Lambda has execution time limits. More importantly, the client needs real time to execute tools (e.g., TTS playback takes seconds). Storing state in DynamoDB and resuming is more robust than holding a connection open.

### Conversation Bounding

Conversations are bounded to the last 50 messages (configurable via `MAX_CONVERSATION_TURNS`). This prevents unbounded DynamoDB item growth and keeps Bedrock context manageable.

## What Changed from Phase 1

| Component | Phase 1 | Phase 2 |
|-----------|---------|---------|
| Conductor | LocalConductorStub | WebSocketConductorClient |
| Backend | None | Lambda + API Gateway + DynamoDB |
| AI Model | None | Bedrock Nova 2 Lite |
| Event Flow | Batch (conductor returns [Event]) | Streaming (events arrive via WebSocket) |
| Config | Secrets.plist (ElevenLabs only) | + BACKEND_WS_URL, USE_CLOUD_CONDUCTOR |

## What Stayed the Same

- `ToolRegistry`, `ToolRouter`, `EventBus` — unchanged
- All existing tools (stt.*, tts.*, convo.*) — unchanged
- UI views — unchanged (observe EventBus)
- Barge-in logic — unchanged (local tts.stop before stt.start)
- Event model (`Event.swift`) — unchanged
- Test infrastructure — extended, not replaced
