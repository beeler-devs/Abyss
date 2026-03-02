# Pairing Protocol (v0)

Pairing uses one-time codes with outbound bridge connections.

## Flow

1. Mac app generates a one-time code (6-8 chars).
2. User enters code in iOS Pair Computer sheet.
3. iOS sends `bridge.pair.request` with `{ pairingCode, deviceName }`.
4. Bridge sends `bridge.register` with `{ pairingCode, deviceId, deviceName, workspaceRoot, capabilities, protocolVersion }`.
5. Server validates code against pending request (TTL = 5 minutes).
6. Server binds `sessionId -> deviceId -> bridge connection`.
7. Server emits `bridge.paired` and `bridge.status` to iOS.

## TTL

- Server stores `pendingPairingCodes[pairingCode] = { sessionId, expiresAt }`.
- Expired codes are rejected as `pairing_code_invalid_or_expired`.

## Reconnect Behavior

- Bridge reconnects with backoff.
- Bridge re-sends `bridge.register` while unpaired.
- Server emits `bridge.status=offline` on disconnect.
