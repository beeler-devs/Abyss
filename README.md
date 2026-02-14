# VoiceIDE — Phase 2: Cloud Conductor

A voice-first agentic development app built around **formal tool calling**. Every action that touches state, audio, or UI flows through structured `tool.call` / `tool.result` events.

Phase 2 adds a real cloud conductor powered by **Amazon Bedrock Nova 2 Lite**, replacing the local stub with a serverless WebSocket backend on AWS.

## Architecture

```
User Voice → WhisperKit STT → WebSocket → Bedrock Nova → tool.call events
                                                            ↓
                                                     iOS ToolRouter
                                                            ↓
                                                     ElevenLabs TTS → Speaker
```

All state changes are visible in the real-time Event Timeline.

See [docs/phase2-architecture.md](docs/phase2-architecture.md) for the full Phase 2 design.

## Requirements

- **Xcode 15.2+**
- **iOS 17.0+** device or simulator
- **Swift 5.9+**
- **Node.js 20+** (for backend)
- **AWS CLI** + credentials (for deployment)
- **AWS CDK CLI** (`npm install -g aws-cdk`)
- **ElevenLabs API key** (for TTS — free tier works)

## Quick Start

### Phase 1 (Local Stub — No Backend Needed)

```bash
cd ios/VoiceIDE
open Package.swift  # Opens in Xcode
# Configure Secrets.plist with ElevenLabs API key (see below)
# Build and Run (Cmd+R) on iOS 17+ device
```

### Phase 2 (Cloud Conductor)

```bash
# 1. Build and deploy backend
cd backend && npm install && npm run build
cd ../infra && npm install && cdk bootstrap && cdk deploy

# 2. Note the WebSocket URL from CDK output

# 3. Configure iOS Secrets.plist (see below):
#    Add BACKEND_WS_URL and USE_CLOUD_CONDUCTOR=true

# 4. Build and Run iOS app
```

See [docs/deploy.md](docs/deploy.md) for detailed deployment instructions.

## Secrets.plist Configuration

Create `ios/VoiceIDE/VoiceIDE/App/Secrets.plist` (git-ignored):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ELEVENLABS_API_KEY</key>
    <string>YOUR_API_KEY_HERE</string>
    <key>ELEVENLABS_VOICE_ID</key>
    <string>21m00Tcm4TlvDq8ikWAM</string>
    <key>ELEVENLABS_MODEL_ID</key>
    <string>eleven_turbo_v2_5</string>
    <key>BACKEND_WS_URL</key>
    <string>wss://YOUR-API-ID.execute-api.us-east-1.amazonaws.com/prod</string>
    <key>USE_CLOUD_CONDUCTOR</key>
    <string>true</string>
</dict>
</plist>
```

Set `USE_CLOUD_CONDUCTOR` to `false` (or omit it) to use the local stub.

**The app will work without the backend** — STT and the tool pipeline function normally with the LocalConductorStub fallback.

### Adding Secrets.plist to Xcode

1. Right-click the `App` group → "Add Files to VoiceIDE"
2. Select `Secrets.plist`
3. Ensure "Copy items if needed" is checked
4. Ensure it's added to the VoiceIDE target

## Project Structure

```
/
├── README.md
├── .gitignore
├── docs/
│   ├── architecture.md                # Phase 1 architecture
│   ├── phase2-architecture.md         # Phase 2 architecture + sequence diagrams
│   ├── protocol.md                    # WebSocket event protocol
│   ├── tools.md                       # Tool catalog with schemas
│   ├── deploy.md                      # Deployment guide
│   └── runbook.md                     # Operations + debugging guide
├── ios/VoiceIDE/                       # iOS App (SwiftUI, iOS 17+)
│   ├── Package.swift
│   ├── VoiceIDE/
│   │   ├── App/                       # Entry point + config
│   │   ├── Models/                    # Event, EventBus, AppState
│   │   ├── Tools/                     # Tool protocol, registry, router, implementations
│   │   ├── Services/                  # WhisperKit STT, ElevenLabs TTS
│   │   ├── Conductor/                 # LocalConductorStub + WebSocketConductorClient
│   │   ├── ViewModels/                # ConversationViewModel
│   │   └── Views/                     # SwiftUI views
│   └── VoiceIDETests/                 # Unit tests (Phase 1 + Phase 2)
├── backend/                            # Cloud Conductor (TypeScript, Node 20+)
│   ├── src/
│   │   ├── handlers/                  # Lambda handlers (connect, disconnect, message)
│   │   ├── services/                  # Bedrock, DynamoDB, WebSocket, Conductor
│   │   ├── models/                    # Event types, session models
│   │   └── utils/                     # Logger
│   └── tests/                         # Jest unit tests
└── infra/                              # AWS CDK (TypeScript)
    ├── bin/app.ts                     # CDK app entry
    └── lib/voiceide-stack.ts          # API GW + Lambda + DynamoDB stack
```

## Features

### Phase 1 (Retained)
- **On-device STT** via WhisperKit with streaming partials
- **Streaming TTS** via ElevenLabs
- **Formal tool calling** — all actions flow through `tool.call` → `tool.result`
- **Barge-in** — tap mic while speaking to interrupt and start listening
- **Recording modes** — tap-to-toggle (default) or press-and-hold
- **Event timeline** — collapsible debug view showing every event in real-time
- **LocalConductorStub** as fallback when backend is unavailable

### Phase 2 (New)
- **Cloud conductor** via Amazon Bedrock Nova 2 Lite (ConverseStream)
- **WebSocket** bidirectional communication (API Gateway WebSocket API)
- **Streaming speech partials** from Bedrock displayed in real-time
- **Formal tool call loop**: Bedrock → backend → iOS client → backend → Bedrock
- **DynamoDB-persisted** session state and conversation history
- **Automatic reconnection** with exponential backoff (5 attempts)
- **Graceful fallback** to local stub on connection failure
- **Structured logging** with sessionId, callId, connectionId tracing
- **Infrastructure as Code** via AWS CDK

## Testing

### iOS Tests

```bash
cd ios/VoiceIDE
swift test
```

Tests cover:
- EventBus ordering and replay
- ToolRouter dispatch and error handling
- LocalConductorStub deterministic output
- Barge-in: tts.stop called before stt.start
- WebSocket conductor: inbound tool.call triggers ToolRouter, produces tool.result

### Backend Tests

```bash
cd backend
npm install
npm test
```

Tests cover:
- Event validation (well-formed, malformed, edge cases)
- Conductor orchestration (tool_call forwarding, tool.result feeding, Bedrock mock)
- Lambda handler routing ($connect validation, $disconnect cleanup)

## Manual Smoke Test

1. Deploy backend: `cd infra && cdk deploy`
2. Configure iOS Secrets.plist with backend URL and `USE_CLOUD_CONDUCTOR=true`
3. Build and run on iOS device
4. Verify green "Cloud Conductor" banner in app
5. Tap mic → speak "Hello" → tap mic
6. Verify in Event Timeline:
   - `user.audio.transcript.final` sent
   - `tool.call convo.setState(thinking)` received from server
   - `tool.call convo.appendMessage` received
   - `assistant.speech.partial/final` displayed
   - `tool.call tts.speak` triggers ElevenLabs
   - `tool.call convo.setState(idle)` completes the turn
7. Verify callId correlation is consistent throughout

## Troubleshooting

See [docs/runbook.md](docs/runbook.md) for debugging guide and common failure modes.

Common issues:
- **"ElevenLabs API key is not configured"** — Create `Secrets.plist` with your API key
- **"Backend URL not configured"** — Add `BACKEND_WS_URL` to Secrets.plist
- **WhisperKit model download fails** — Ensure internet connectivity (base.en is ~140MB)
- **Microphone not working in simulator** — Use a real device
- **Bedrock access denied** — Enable Nova Lite model access in AWS Console

## Phase 3 Roadmap

- Nova embeddings for semantic code search
- File editing tools (file.read, file.write, file.list)
- Git operations (git.status, git.commit, git.push)
- Browser automation (browser.navigate, browser.screenshot)
- Nova Act sub-agent integration (agent.spawn, agent.status)
- Artifact cards (diff views, log views) in the UI
- User authentication

## Documentation

- [Phase 2 Architecture](docs/phase2-architecture.md) — sequence diagrams, design decisions
- [Phase 1 Architecture](docs/architecture.md) — original design
- [Event Protocol](docs/protocol.md) — wire format, event types, error codes
- [Tool Catalog](docs/tools.md) — all registered tools with schemas
- [Deployment Guide](docs/deploy.md) — step-by-step deploy instructions
- [Operations Runbook](docs/runbook.md) — debugging, logs, failure modes
