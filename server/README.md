# Abyss Conductor Server (Stage 3)

Stage 3 turns the backend into a tool server for voice-first development loops.

- WebSocket conductor endpoint: `/ws`
- OAuth token exchange endpoint: `/github/exchange`
- Server-side tool routing for `github.*`, `ci.*`, `diagnose.*`, `context.*`, `embeddings.*`, `patch.*`, `preview.*`, `webqa.*`, `policy.*`, `runner.*`
- Client-side tools remain on iOS (`stt.*`, `tts.*`, `convo.*`, optional Cursor tools)

## Requirements

- Node.js 20+
- npm

## Setup

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
cp .env.example .env
```

At minimum set:

- `ANTHROPIC_API_KEY`
- `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` (for OAuth exchange)

## Run (dev)

```bash
npm run dev
```

Default endpoint:

- `ws://localhost:8080/ws`

## Build

```bash
npm run build
```

## Test

```bash
npm test
```

## Smoke test

```bash
npm run smoke
```

## Key environment variables

- `PORT` (default `8080`)
- `MODEL_PROVIDER` (`anthropic` or `bedrock`)
- `MAX_EVENT_BYTES` (default `65536`)
- `MAX_TURNS` (default `20`)
- `SESSION_RATE_LIMIT_PER_MIN` (default `300`)
- `ANTHROPIC_API_KEY` (required for Anthropic)
- `ANTHROPIC_MODEL` (default `claude-3-5-haiku-latest`)
- `ANTHROPIC_MAX_TOKENS` (default `512`)
- `ANTHROPIC_PARTIAL_DELAY_MS` (default `60`)
- `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`
- `STAGE3_MAX_ITERATIONS` (default `3`)
- `STAGE3_MAX_CI_WAIT_MS` (default `180000`)
- `STAGE3_WEBQA_PROVIDER` (default `stub`)
- `STAGE3_RUN_STORE` (default `inmemory`)
- `STAGE3_DEFAULT_MAX_DIFF_LINES` (default `250`)

## Notes

- Stage 3 currently ships a stub WebQA provider and stub hosted runner provider behind stable tool schemas.
- Patch application defaults to GitHub Contents API commits on a PR branch.
- Cursor tools stay available as optional fallback executor.
