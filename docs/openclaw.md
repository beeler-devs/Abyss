# OpenClaw — Integration Reference for Abyss

> Last updated: March 2026.

---

## Overview

[OpenClaw](https://docs.openclaw.ai) is a local AI gateway that manages
persistent agent sessions and routes messages through chat channels (Telegram,
Discord, Signal, WhatsApp, etc.).  It runs as a **systemd service on the
local machine** — the same host that runs the Abyss server — **not** on a
remote cloud box.

The gateway listens on loopback by default (`127.0.0.1:18789`), which means:

- The Abyss server can reach it without any network traversal.
- Aarush's other devices (phone, Babel) reach it by SSHing into this machine
  and talking to the gateway from there.
- The ECS deployment of Abyss does **not** have access to OpenClaw.  The
  `openclaw.*` tools are automatically hidden from the LLM when
  `OPENCLAW_GATEWAY_URL` is not set in the server environment.

---

## Topology

```
iPhone / other devices
        │  SSH or direct (if reachable)
        ▼
  THIS MACHINE (local)
  ┌─────────────────────────────────────────────────┐
  │  OpenClaw gateway  ws://127.0.0.1:18789         │
  │  systemd service: openclaw-gateway.service      │
  │                                                 │
  │  Abyss server  ws://0.0.0.0:8080               │
  │   └── OpenClawClient ──────────────────────────►│ HTTP /health
  │                        CLI subprocess           │ openclaw agent / message send / system event
  └─────────────────────────────────────────────────┘
```

The Abyss `OpenClawClient` talks to the gateway two ways:
1. **HTTP `GET /health`** — lightweight liveness probe.
2. **`openclaw` CLI subprocess** — agent turns, message delivery, and system
   events.  The CLI handles WebSocket RPC, auth, and retries automatically.

---

## Prerequisites

- `openclaw` CLI installed and on `$PATH` (or set `OPENCLAW_CLI_BIN`).
- Gateway running: `openclaw gateway status`
- Token stored in `~/.openclaw/openclaw.json` or passed via
  `OPENCLAW_GATEWAY_TOKEN`.

Check current status:

```bash
openclaw gateway status        # service status + gateway probe
openclaw health                # fast liveness check
openclaw gateway call health --json   # JSON health via WebSocket RPC
```

---

## Configuration

Add to `server/.env` (copy from `server/.env.example`):

```env
# Enable openclaw.* tools — only on local host, leave blank on ECS
OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789
OPENCLAW_GATEWAY_TOKEN=<token>            # see below
# OPENCLAW_CLI_BIN=/home/<user>/.npm-global/bin/openclaw   # if not on PATH
```

### Finding your gateway token

```bash
cat ~/.openclaw/openclaw.json | python3 -m json.tool | grep '"token"'
# or:
openclaw config get gateway.auth.token
```

The token is under `gateway.auth.token` in the JSON config.

### Disabling on ECS

Leave `OPENCLAW_GATEWAY_URL` unset (empty string).  `OpenClawClient.isConfigured()`
returns `false` and the `openclaw.*` tools are not added to the LLM's tool
list.

---

## Available Tools

| Tool | Description |
|---|---|
| `openclaw.status` | Health probe — is the gateway up? Returns `ok`, `status`, and latency. |
| `openclaw.agent` | Run a message through the OpenClaw AI agent (GPT-5.4 with persistent memory). Returns the agent's reply text. |
| `openclaw.message.send` | Send a message via Telegram or Discord. |
| `openclaw.system.event` | Enqueue a background task for the agent to process at the next heartbeat (or immediately). |

### `openclaw.agent`

Delegates a task to the OpenClaw agent, which has its own long-term memory
and a persistent GPT-5.4 session.  Use this to:
- Ask what the agent has been working on.
- Delegate background tasks (code review, scheduling, research).
- Check recent activity across chat channels.

The reply is the agent's raw response text.  It is **not** part of the Abyss
conversation history — treat it as output from an external AI system.

```
message   — natural-language message to the agent  (required)
agentId   — target agent id, default "main"        (optional)
sessionKey — explicit session key for continuity   (optional)
```

### `openclaw.message.send`

Sends a notification through an OpenClaw channel.  The configured channels
are Telegram (`emily_sdk_bot`) and Discord (`Emily`).

```
channel  — "telegram" | "discord"
target   — Telegram chat id / @username, or Discord channel/user id
message  — message body (plain text; Telegram supports basic Markdown)
```

### `openclaw.system.event`

Enqueues a system event.  The agent processes it at the next heartbeat
(default every 15 minutes) or immediately when `mode="now"`.

```
text   — natural-language instruction for the agent  (required)
mode   — "now" | "next-heartbeat"  (default "next-heartbeat")
```

---

## Babel (separate remote system)

Aarush has SSH access to **Babel** (`aarusha@babel.andrew.cmu.edu`), a CMU
research cluster.  Babel is a **separate remote system** — it is not the
machine running OpenClaw.

- Babel runs research/HPC jobs via Slurm.
- OpenClaw runs locally on Aarush's personal machine (this host).
- Do not confuse the two.  OpenClaw tools route to `127.0.0.1`; Babel is
  accessed over SSH.

If you need to run something on Babel from Abyss, use the macOS bridge
(`bridge.exec.run` via SSH) rather than OpenClaw.

---

## Key Files

| File | Purpose |
|---|---|
| `server/src/integrations/openclawClient.ts` | HTTP health probe + CLI subprocess wrapper |
| `server/src/core/conductorService.ts` | Tool definitions (`SERVER_OPENCLAW_TOOLS`) + dispatch cases |
| `server/src/server.ts` | `OpenClawClient` instantiation with env vars |
| `server/.env.example` | `OPENCLAW_GATEWAY_URL`, `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_CLI_BIN` |

---

## Running / Testing Locally

```bash
# 1. Confirm the gateway is running
openclaw gateway status

# 2. Add to server/.env:
#    OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789
#    OPENCLAW_GATEWAY_TOKEN=<your-token>

# 3. Start Abyss server
cd server && npm run dev

# 4. Ask Abyss: "Check OpenClaw status" or "Send me a Telegram message"
#    The LLM will call openclaw.status / openclaw.message.send automatically.

# Manual CLI smoke tests:
openclaw health
openclaw agent --message "ping" --json
openclaw message send --channel telegram --target <your-chat-id> --message "test from Abyss" --json
openclaw system event --text "check inbox" --mode now --json
```

---

## Gateway Management

```bash
# Start / stop / restart the systemd service
openclaw gateway start
openclaw gateway stop
openclaw gateway restart

# Check service logs
openclaw logs
# or: journalctl --user -u openclaw-gateway -f

# Probe (health + channels + status)
openclaw gateway probe
```

---

## Known Constraints

- **Loopback only by default** — the gateway does not accept connections from
  the network unless reconfigured (`gateway.bind=lan` or Tailscale).
- **Token auth** — every CLI call requires `--token` when the gateway is
  configured with `auth.mode=token` (which is the default).  Abyss reads the
  token from `OPENCLAW_GATEWAY_TOKEN`; the CLI falls back to
  `~/.openclaw/openclaw.json` if the env var is empty.
- **Agent turns can be slow** — `openclaw.agent` invokes a real LLM turn
  (GPT-5.4) with up to 272K context.  The default timeout is 120 s.
- **CLI in PATH** — the Abyss Node process must have the `openclaw` binary in
  its `$PATH`, or `OPENCLAW_CLI_BIN` must point to the full binary path
  (e.g. `/home/agarwalaarush/.npm-global/bin/openclaw`).
