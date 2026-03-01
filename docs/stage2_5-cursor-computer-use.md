# Stage 2.5: Cursor Computer Use (Server-Orchestrated)

## Why webhooks

Stage 2 relied on iOS polling Cursor Agent status. Stage 2.5 upgrades this to server orchestration:

1. Server creates Cursor runs and attaches webhooks.
2. Cursor webhook events are verified and routed to the correct session.
3. Server emits `agent.status` immediately and triggers internal `agent.completed` follow-up narration.
4. iOS timeline/cards surface run links and PR links with minimal polling.

This improves reliability, correlation, and latency for status updates.

## New server tool interfaces

### `cursor.agent.spawn`

Input:

```json
{
  "prompt": "string",
  "repoUrl": "string (optional)",
  "ref": "string (optional)",
  "metadata": {},
  "mode": "code | computer_use | webqa"
}
```

Output:

```json
{
  "agentId": "string",
  "id": "string",
  "status": "string",
  "runUrl": "string?",
  "url": "string?",
  "prUrl": "string?",
  "branchName": "string?"
}
```

### `cursor.agent.status`

Input:

```json
{ "agentId": "string" }
```

Output:

```json
{
  "agentId": "string",
  "status": "string",
  "runUrl": "string?",
  "prUrl": "string?",
  "summary": "string?"
}
```

### `cursor.agent.followup`

Input:

```json
{ "agentId": "string", "message": "string" }
```

Output:

```json
{ "ok": true }
```

### `cursor.agent.cancel`

Input:

```json
{ "agentId": "string" }
```

Output:

```json
{ "ok": true }
```

## WebQA provider surface (Cursor computer use)

### `webqa.cursor.run`

Input:

```json
{
  "url": "https://example.com",
  "flowSpec": {},
  "assertions": {},
  "budget": {}
}
```

Output:

```json
{
  "agentId": "string",
  "runUrl": "string?",
  "status": "string?"
}
```

### `webqa.cursor.status`

Input:

```json
{ "agentId": "string" }
```

Output:

```json
{
  "agentId": "string",
  "status": "string",
  "runUrl": "string?",
  "prUrl": "string?",
  "summary": "string?"
}
```

### `webqa.cursor.followup`

Input:

```json
{ "agentId": "string", "instruction": "string" }
```

Output:

```json
{ "ok": true }
```

## Webhook endpoint

`POST /cursor/webhook`

Requirements:

1. Signature verification with `X-Webhook-Signature` and `CURSOR_WEBHOOK_SECRET` (HMAC-SHA256 over raw body).
2. Payload parsing for `agentId`, status, summary, run/pr links.
3. Unknown `agentId` events are queued briefly (TTL) and return `202`.
4. Known `agentId` events route into session:
   - emit `agent.status`
   - emit internal `agent.completed` for terminal states

## Environment configuration

Set in `server/.env`:

```bash
CURSOR_API_KEY=...
CURSOR_WEBHOOK_URL=https://<public-host>/cursor/webhook
CURSOR_WEBHOOK_SECRET=...
CURSOR_WEBHOOK_MAX_BYTES=512000
```

Legacy fallback still works when `CURSOR_API_KEY` is unset (iOS `agent.*` tools continue to run client-side).

## Local development (ngrok)

1. Start server:

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
npm install
npm run dev
```

2. Expose local server publicly:

```bash
ngrok http 8080
```

3. Copy the HTTPS URL and set:

```bash
CURSOR_WEBHOOK_URL=https://<ngrok-id>.ngrok-free.app/cursor/webhook
CURSOR_WEBHOOK_SECRET=<shared-secret>
```

4. Restart server after env changes.

## iOS behavior updates

1. Agent cards and timeline rows now show:
   - `Open Agent Run` when `runUrl` exists
   - `Open PR` when `prUrl` exists
2. Polling is reduced when webhook-driven `agent.status` updates are received.
3. Cursor API key in Settings remains available for backward compatibility and now includes an optional server-note.

## Manual smoke test

1. Start server with Cursor env vars and ngrok webhook URL configured.
2. Run iOS app and connect to server conductor (`BACKEND_WS_URL` set).
3. Ask assistant: “spawn a Cursor agent to <task>”.
4. Confirm timeline/card receives immediate `agent.status` with run link.
5. Wait for webhook `FINISHED`:
   - card status updates
   - `Open Agent Run` / `Open PR` links appear if provided
   - server triggers internal `agent.completed`
   - assistant narrates outcome in the conversation
