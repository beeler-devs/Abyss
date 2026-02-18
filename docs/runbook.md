# Abyss Phase 2 Runbook

## Local Start

### 1) Start server

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
cp .env.example .env
# set ANTHROPIC_API_KEY in .env
npm run dev
```

### 2) Configure iOS app

Set `BACKEND_WS_URL` in local `Secrets.plist` (git-ignored), e.g.

- `ws://<your-lan-ip>:8080/ws`

Then run the iOS app and enable **Settings -> Use Server Conductor**.

### 3) Manual acceptance check

Speak: `hello`

Expected:

- transcript appears
- server emits tool sequence
- iOS executes `tts.speak`
- response audio plays
- event timeline shows ordered `tool.call` and `tool.result`

## Barge-In Validation

While assistant is speaking:

1. Start listening again (tap or press, based on mode)
2. Confirm timeline order:
   - `tool.call: tts.stop`
   - `tool.result` for `tts.stop`
   - `tool.call: stt.start`
3. Confirm TTS stops immediately and STT starts

## Debugging Checklist

### iOS side

- Open Event Timeline and verify event ordering
- Confirm `tool.call`/`tool.result` call ids correlate
- Confirm `assistant.speech.partial` updates in place (no duplicate message spam)
- Confirm settings show valid `BACKEND_WS_URL`

### Server side

- Check logs for `session=... event=... call=...`
- For each transcript.final, verify trace includes:
  - `tool.call:convo.setState`
  - `assistant.speech.partial`
  - `assistant.speech.final`
  - `tool.call:tts.speak`
- Run smoke test:

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm run smoke
```

## Common Issues

### Missing Anthropic key

Symptom:

- server exits on startup with key error

Fix:

- set `ANTHROPIC_API_KEY` in `server/.env`

### Wrong `BACKEND_WS_URL`

Symptom:

- iOS falls back to local conductor or logs conductor connection errors

Fix:

- ensure URL includes `/ws`
- use reachable LAN IP for real device (not `localhost`)

### Mic permission denied

Symptom:

- no transcript / STT fails

Fix:

- enable microphone permission for app in iOS Settings

### No audio output

Symptom:

- text appears but no speech

Fix:

- verify ElevenLabs key is configured in `Secrets.plist`
- check `tool.result` for `tts.speak` error

### Event duplicates on reconnect

Symptom:

- repeated timeline entries after network blip

Fix:

- verify inbound dedupe by `event.id` is active in `WebSocketConductorClient`

## Security Notes

- Never commit secrets (`ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `CURSOR_API_KEY`)
- Use `.env` and local `Secrets.plist`
- Server logs avoid printing API keys
