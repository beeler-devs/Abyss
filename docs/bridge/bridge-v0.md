# Bridge v0

Bridge v0 enables an outbound macOS bridge process to execute local tools for an iOS voice session.

## Components

- `server/`: WebSocket conductor + bridge pairing/routing
- `mac/BridgeCore`: headless Swift package runtime
- `mac/AbyssBridge`: SwiftUI macOS app wrapper
- `mac/BridgeCLI`: optional CLI wrapper
- `ios/Abyss`: iOS pairing sheet + bridge status list

## End-to-End Demo

1. Start server.
2. Launch `AbyssBridge` app or `BridgeCLI`.
3. Generate pairing code on Mac.
4. In iOS app: Settings -> Pair Computer -> enter code.
5. Speak: `run tests` or `run npm test`.
6. Server routes `bridge.exec.run` to paired device.
7. Bridge returns `tool.result` with exit code/stdout/stderr.
8. Assistant summarizes output; event timeline shows `tool.call`/`tool.result`.

## Included Tools

- `bridge.exec.run`
- `bridge.fs.readFile`

## Explicitly Out of Scope (v0)

- inbound ports to Mac
- command cancellation
- patch apply / git automation
- CI-hosted bridge workers
- signed enrollment tokens (planned for future hardening)
