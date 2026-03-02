# Abyss (Stage 2 + Bridge v0)

Abyss is a voice-first conductor architecture with formal tool calling over WebSocket.
Bridge v0 adds a paired macOS bridge for local command + filesystem tools.

## Repository Layout

```text
/Users/bentontameling/Dev/VoiceBot2
├── docs/
│   ├── protocol/
│   │   ├── events.md
│   │   ├── tools.md
│   │   └── versioning.md
│   ├── bridge/
│   │   ├── bridge-v0.md
│   │   ├── pairing.md
│   │   └── security.md
│   └── runbooks/
├── shared/
│   ├── protocol/schemas/
│   └── libs/
│       ├── ts-protocol/
│       └── swift-protocol/
├── ios/
│   ├── Abyss/                # existing iOS project
│   └── VoiceIDE/README.md    # alias doc for expected naming
├── mac/
│   ├── BridgeCore/
│   ├── AbyssBridge/
│   └── BridgeCLI/
├── server/
└── scripts/dev/start-local.sh
```

## Quick Start

```bash
./scripts/dev/start-local.sh
```

Then:

1. Launch bridge app (`cd mac/AbyssBridge && swift run`) or CLI (`cd mac/BridgeCLI && swift run abyss-bridge ...`).
2. Generate pairing code on Mac.
3. In iOS app: Settings -> Pair Computer.
4. Speak: `run npm test` or `run echo hello`.
5. Speak: `read file README.md`.

## Security Notes

- Event envelopes now require `protocolVersion`.
- Bridge tools are constrained to selected workspace root.
- Command execution has timeout + output truncation.
- Never commit secrets (`.env`, `Secrets.plist` remain local).
