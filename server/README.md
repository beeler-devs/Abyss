# Abyss Conductor Server (Phase 2)

WebSocket conductor service for the Abyss iOS app.

- Accepts event envelopes over `ws://.../ws`
- Uses `MODEL_PROVIDER=anthropic` by default (Claude via Anthropic API)
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

- `ANTHROPIC_API_KEY`
- Optional: `ANTHROPIC_MODEL`, `ANTHROPIC_MAX_TOKENS`, `PORT`

## Run (dev)

```bash
npm run dev
```

Server listens on:

- `ws://localhost:8080/ws` (or your configured `PORT`)

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
- `MODEL_PROVIDER` (`anthropic` or `bedrock`, default `anthropic`)
- `MAX_EVENT_BYTES` (default `65536`)
- `MAX_TURNS` (default `20`)
- `SESSION_RATE_LIMIT_PER_MIN` (default `30`)
- `ANTHROPIC_API_KEY` (required for `anthropic`)
- `ANTHROPIC_MODEL` (default `claude-haiku-4-5`)
- `ANTHROPIC_MAX_TOKENS` (default `512`)
- `ANTHROPIC_PARTIAL_DELAY_MS` (default `60`)
- `BEDROCK_MODEL_ID` (for scaffold)
- `AWS_REGION` (for scaffold)

## Switching providers

- Anthropic (active): `MODEL_PROVIDER=anthropic`
- Bedrock scaffold: `MODEL_PROVIDER=bedrock`

Bedrock is intentionally scaffolded for easy cutover later with minimal code changes.
