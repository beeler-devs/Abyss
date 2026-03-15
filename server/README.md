# Abyss Conductor Server (Phase 2)

WebSocket conductor service for the Abyss iOS app.

- Accepts event envelopes over `ws://.../ws`
- Uses `MODEL_PROVIDER=bedrock` by default (Amazon Nova 2 Lite on Bedrock)
- Uses `VOICE_PROVIDER=nova-sonic` by default for hands-free live conversation
- Emits ordered tool-driven events (`tool.call`, `assistant.speech.partial/final`)
- Accepts `tool.result` from iOS and logs call outcomes
- Keeps per-session history + pending tool calls in memory

## Requirements

- Node.js 20+
- npm

## Setup

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
cp .env.example .env
```

Edit `.env` and set at minimum:

- AWS credentials via the standard SDK chain:
  - `AWS_PROFILE`, or
  - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / optional `AWS_SESSION_TOKEN`
- Optional: `BEDROCK_TEXT_MODEL_ID`, `BEDROCK_MAX_TOKENS`, `PORT`
- Optional Stage 2.5 Cursor integration:
  - `CURSOR_API_KEY`
  - `CURSOR_WEBHOOK_URL`
  - `CURSOR_WEBHOOK_SECRET`

## Run (dev)

```bash
npm run dev
```

Server listens on:

- `ws://localhost:8080/ws` (or your configured `PORT`)
- `POST /github/exchange`
- `POST /cursor/webhook`
- `GET /healthz`

## Run tests

```bash
npm test
```

## Smoke test

In one terminal:

```bash
npm run dev
```

In a second terminal:

```bash
npm run smoke
```

Optional smoke overrides:

```bash
SMOKE_WS_URL=ws://localhost:8080/ws SMOKE_TEXT="hello" npm run smoke
```

## Environment variables

- `PORT` (default `8080`)
- `MODEL_PROVIDER` (`bedrock` or `anthropic`, default `bedrock`)
- `VOICE_PROVIDER` (`local` or `nova-sonic`, default `nova-sonic`)
- `MAX_EVENT_BYTES` (default `65536`)
- `MAX_TURNS` (default `20`)
- `SESSION_RATE_LIMIT_PER_MIN` (default `30`)
- `TRANSCRIPT_TRACE_MAX_ENTRIES` (default `120`)
- `VERBOSE_TOOL_ROUTING_LOGS` (default `false`)
- `BEDROCK_TEXT_MODEL_ID` (default `us.amazon.nova-2-lite-v1:0`, used for push-to-talk + typed text turns)
- `BEDROCK_MAX_TOKENS` (default `512`)
- `BEDROCK_PARTIAL_DELAY_MS` (default `60`)
- `BEDROCK_SONIC_MODEL_ID` (default `us.amazon.nova-2-sonic-v1:0`)
- `BEDROCK_SONIC_VOICE_ID` (default `tiffany`)
- `AWS_REGION` (default `us-east-1`)
- `AWS_PROFILE` (optional)
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` (optional)
- `ANTHROPIC_API_KEY` (required only for `MODEL_PROVIDER=anthropic`)
- `ANTHROPIC_MODEL` (default `claude-haiku-4-5`)
- `ANTHROPIC_MAX_TOKENS` (default `512`)
- `ANTHROPIC_PARTIAL_DELAY_MS` (default `60`)
- `GITHUB_CLIENT_ID` (required for `/github/exchange`)
- `GITHUB_CLIENT_SECRET` (required for `/github/exchange`)
- `CURSOR_API_KEY` (enables server-side `cursor.agent.*` + `webqa.cursor.*`)
- `CURSOR_WEBHOOK_URL` (public Cursor webhook endpoint URL)
- `CURSOR_WEBHOOK_SECRET` (HMAC verification secret for `/cursor/webhook`)
- `CURSOR_WEBHOOK_MAX_BYTES` (default `512000`)

## Routing observability checks

When debugging server tool routing/fallback behavior, grep server logs for:

- `tool.server.dispatch`
- `tool.server.result`
- `bridge.claude.run.start`
- `bridge.claude.run.command_bound`
- `bridge.claude.run.finish`

## Switching providers

- Bedrock / Nova (default): `MODEL_PROVIDER=bedrock`
- Anthropic compatibility fallback: `MODEL_PROVIDER=anthropic`

Recommended split for the iOS app:

- Push-to-talk and typed text: `MODEL_PROVIDER=bedrock` with `BEDROCK_TEXT_MODEL_ID=us.amazon.nova-2-lite-v1:0`
- Hands-free live conversation: `VOICE_PROVIDER=nova-sonic`

`VOICE_PROVIDER=local` is still supported as a server fallback, but the current iOS hands-free mode expects Nova Sonic streaming.
