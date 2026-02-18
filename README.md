# Abyss — Phase 2

A voice-first agentic development app with formal tool calling and a real WebSocket conductor backend.

- iOS app: `ios/Abyss`
- Conductor server: `server`
- Protocol/docs: `docs`

## Core Model

All behavior flows through events:

- Backend emits `tool.call` and `assistant.speech.*`
- iOS executes client tools through `ToolRouter`
- iOS returns `tool.result` to backend
- Event timeline preserves full ordering + `callId` correlation

## Repository Structure

```text
/Users/bentontameling/Dev/VoiceBot2
├── ios/Abyss/                  # iOS app (WhisperKit + ElevenLabs + EventBus)
├── server/                     # Phase 2 WebSocket conductor (Anthropic provider active)
├── docs/
│   ├── phase2-architecture.md
│   ├── protocol.md
│   └── runbook.md
└── README.md
```

## iOS Setup

1. Open `ios/Abyss` in Xcode (`Package.swift` based project).
2. Create local `Secrets.plist` (git-ignored) at:
   - `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/Abyss/App/Secrets.plist`
3. Include keys as needed:

```xml
<key>ELEVENLABS_API_KEY</key>
<string>...</string>
<key>CURSOR_API_KEY</key>
<string>...</string>
<key>BACKEND_WS_URL</key>
<string>ws://<LAN-IP>:8080/ws</string>
```

4. In app Settings, toggle **Use Server Conductor**.

If `BACKEND_WS_URL` is present and this is first run, server conductor is enabled automatically.

## Server Setup

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
cp .env.example .env
# Set ANTHROPIC_API_KEY in .env
npm run dev
```

Default endpoint:

- `ws://localhost:8080/ws`

## Tests

### iOS

```bash
cd /Users/bentontameling/Dev/VoiceBot2/ios/Abyss
swift test
```

### Server

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm test
```

## Smoke Test

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm run smoke
```

## Docs

- Architecture: `docs/phase2-architecture.md`
- Protocol: `docs/protocol.md`
- Runbook: `docs/runbook.md`

## Secrets

Never commit real secrets.

- `.env` (server) is local
- `Secrets.plist` (iOS) is local
- `.gitignore` already excludes these paths
