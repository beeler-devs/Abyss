# Abyss — Stage 3

Voice-first agentic development platform with formal tool-calling across iOS + backend.

- iOS app: `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss`
- Tool server backend: `/Users/bentontameling/Dev/VoiceBot2/server`
- Architecture/docs: `/Users/bentontameling/Dev/VoiceBot2/docs`

## Stage 3 outcome

With GitHub + CI configured (no Cursor required), the system can:

1. Select a repo (or prompt selection).
2. Run and summarize CI checks.
3. Diagnose failures.
4. Build context (hybrid retrieval + embeddings).
5. Generate/validate/apply patch on a PR branch.
6. Iterate until green within budget.
7. Discover preview URL and run web validation.
8. Gate merge with policy checks.

## Core model

- Conductor decides actions by tool calls.
- iOS executes only client tools (`stt.*`, `tts.*`, `convo.*`, optional Cursor tools).
- Backend executes only server tools (`github.*`, `ci.*`, `embeddings.*`, `context.*`, `patch.*`, `webqa.*`, `policy.*`, `runner.*`).
- All activity is visible via event timeline (`tool.call`, `tool.result`, `assistant.speech.*`, `assistant.ui.patch`, `agent.status`).

## Setup

### Server

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
cp .env.example .env
npm run dev
```

### iOS

1. Open `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/Abyss.xcodeproj` in Xcode.
2. Create local `Secrets.plist` at `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/Abyss/App/Secrets.plist`.
3. Add at least:

```xml
<key>BACKEND_WS_URL</key>
<string>ws://<LAN-IP>:8080/ws</string>
<key>ELEVENLABS_API_KEY</key>
<string>...</string>
```

Optional:

```xml
<key>CURSOR_API_KEY</key>
<string>...</string>
```

4. In app Settings, enable **Use Server Conductor** and set **Preferred Repo (owner/repo)** if desired.

## Tests

### Server

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm test
npm run build
```

### iOS

Use Xcode test runner for `/Users/bentontameling/Dev/VoiceBot2/ios/Abyss/AbyssTests`.

## Key docs

- `/Users/bentontameling/Dev/VoiceBot2/docs/stage3-architecture.md`
- `/Users/bentontameling/Dev/VoiceBot2/docs/tools-server.md`
- `/Users/bentontameling/Dev/VoiceBot2/docs/context-engine.md`
- `/Users/bentontameling/Dev/VoiceBot2/docs/runbook-stage3.md`
- `/Users/bentontameling/Dev/VoiceBot2/docs/protocol.md`
