# iOS Workspace Directory Setting

**Date:** 2026-03-15
**Status:** Approved

## Problem

The macOS bridge's workspace directory is set at startup via the `--workspace` CLI flag (or GUI app). There is no way to view or change it from the iOS app without restarting the bridge. Users need to be able to set the workspace directory per paired device from within iOS Settings.

## Approach

Post-pairing workspace sync via a new `bridge.workspace.set` event. iOS stores a workspace override per device and sends it to the bridge after pairing and on reconnect. The bridge validates and applies the path dynamically.

## Data Model

### iOS: `PairedBridgeDevice`

Add two optional `let` fields:

```swift
struct PairedBridgeDevice: Codable, Identifiable, Equatable {
    let deviceId: String
    let deviceName: String
    let status: String
    let lastSeen: String?
    let workspaceRoot: String?      // Bridge's actual workspace, received from server on pairing (read-only)
    let workspaceOverride: String?  // User-set override, stored in UserDefaults
}
```

Both fields are persisted in the existing `UserDefaults` JSON blob under `pairedBridgeDevices`.

**Update pattern:** Because all fields are `let`, every "update" to a device record is done by constructing a new `PairedBridgeDevice` and copying all unchanged fields from the existing record:

```swift
let updated = PairedBridgeDevice(
    deviceId: existing.deviceId,
    deviceName: existing.deviceName,
    status: newStatus,
    lastSeen: existing.lastSeen,
    workspaceRoot: existing.workspaceRoot,       // must carry through
    workspaceOverride: existing.workspaceOverride // must carry through
)
```

**Carry-through sites:** Two handlers in `ConversationEventCoordinator` construct new `PairedBridgeDevice` values from existing ones and must carry both new fields through:

1. **`.bridgeStatus` handler** — rebuilds the struct on every status event. Must copy `workspaceRoot` and `workspaceOverride` from the pre-existing record. See Trigger 3 pseudocode below.
2. **`.bridgePaired` handler** — carries `workspaceOverride` from the pre-existing record. See Trigger 2 pseudocode below.

### `upsertPairedBridgeDevice` helper

The existing private `upsertPairedBridgeDevice(deviceId:deviceName:status:lastSeen:)` helper must be extended to accept two new optional parameters:

```swift
private func upsertPairedBridgeDevice(
    deviceId: String,
    deviceName: String,
    status: String,
    lastSeen: String?,
    workspaceRoot: String? = nil,
    workspaceOverride: String? = nil
)
```

**nil semantics:** When `workspaceRoot` or `workspaceOverride` is `nil`, the helper keeps the existing record's value — it does **not** clear it. Implement by reading the existing device record before constructing the new one and using `??` fallback:

```swift
let existing = pairedBridgeDevices.first(where: { $0.deviceId == deviceId })
let updated = PairedBridgeDevice(
    deviceId: deviceId,
    deviceName: deviceName,
    status: status,
    lastSeen: lastSeen,
    workspaceRoot: workspaceRoot ?? existing?.workspaceRoot,
    workspaceOverride: workspaceOverride ?? existing?.workspaceOverride
)
```

This contract ensures existing call sites (which pass `nil`) silently preserve whatever values are already stored.

### Server: `bridge.paired` event payload

Add `workspaceRoot: string` to the `bridge.paired` event payload. The bridge already sends `workspaceRoot` in `bridge.register` (required field — server rejects without it), so `registration.device.workspaceRoot` is always a non-nil string:

```ts
emitToSession(makeEvent("bridge.paired", registration.device.sessionId, {
  deviceId: registration.device.deviceId,
  deviceName: registration.device.deviceName,
  status: "online",
  workspaceRoot: registration.device.workspaceRoot,   // add this
}));
```

This field is added **only** to `bridge.paired` — not to `bridge.status` or the heartbeat re-register path — consistent with the `!wasAlreadyPaired` guard.

iOS also needs to decode this field. Add `workspaceRoot: String?` to `Event.BridgePaired` (declared optional for forward compatibility; will always be populated in practice) and decode it as `payload["workspaceRoot"]?.stringValue` in the `"bridge.paired"` case of `EventEnvelope.toEvent()`.

## iOS Event Kind

Changes span `Event.swift` and `EventEnvelope.swift`:

**`Event.Kind`** — add:
```swift
case bridgeWorkspaceSet(BridgeWorkspaceSet)
```

**Payload struct** in `Event.swift`:
```swift
struct BridgeWorkspaceSet: Codable, Sendable {
    let deviceId: String
    let workspacePath: String
}
```

**`EventEnvelope.init(event:)` — outbound encoding** (wire type `"bridge.workspace.set"`):
```swift
case .bridgeWorkspaceSet(let value):
    type = "bridge.workspace.set"
    payload = [
        "deviceId": .string(value.deviceId),
        "workspacePath": .string(value.workspacePath),
    ]
```

**`EventEnvelope.toEvent()` — inbound decoding:** This event is outbound-only. Do **not** add a `"bridge.workspace.set"` case to `toEvent()`. If it ever arrives inbound it falls to `default: throw ConversionError.unsupportedType` — acceptable.

**`handleInboundEvent` switch in `ConversationEventCoordinator`:** Add `.bridgeWorkspaceSet` to the exhaustive switch. Swift requires all `Event.Kind` cases to appear even though this event is outbound-only and `EventEnvelope.toEvent()` will throw before producing this value. The case is therefore unreachable dead code. Use `break` as the body to make the intent explicit — do not call `eventBus.emit(event)` since the event value can never be legitimately constructed from inbound data.

## UI

In the Bridge section of `SettingsView`, each paired device row includes an editable workspace path field below the device name/status:

```
● My Mac                          online
  /Users/benton/Dev/Project   ← editable TextField
```

- **Placeholder:** `workspaceRoot` (bridge's actual workspace); falls back to a generic path placeholder if `workspaceRoot` is `nil`
- **Style:** `.font(.system(.caption, design: .monospaced))`, `autocorrectionDisabled`, `textInputAutocapitalization(.never)` — matching the Server URL field
- **Pre-fill:** `workspaceOverride` if already stored
- **On commit / focus-lost:** calls `coordinator.setWorkspaceOverride(deviceId: device.deviceId, path: trimmedFieldValue)` where `trimmedFieldValue` is the trimmed string, or `nil` if empty
- **Clearing the field:** calls with `path: nil` — removes the override from storage but does **not** send any event to the bridge (the bridge retains its current workspace); known limitation in Out of Scope

`SettingsView` needs access to `ConversationEventCoordinator` via `@EnvironmentObject` or a passed callback, following the existing pattern for how `onPairComputer` is passed today.

## `setWorkspaceOverride(deviceId:path:)` method

**Signature:** `func setWorkspaceOverride(deviceId: String, path: String?)`

This method handles **trigger 1 only** (user edits the field). Triggers 2 and 3 are in their respective event handlers.

Steps:

1. Find the device in `pairedBridgeDevices` by `deviceId`; return early if not found
2. Trim the path; treat empty string as `nil`
3. Construct a new `PairedBridgeDevice` copying all existing fields, with `workspaceOverride` set to the trimmed non-empty path or `nil`
4. Replace the device in `pairedBridgeDevices` and call `persistPairedBridgeDevices()`
5. If the trimmed path is non-empty and the device's current `status == "online"`, send `bridge.workspace.set` via `sendConductorEvent`

## Event Flow

### Wire format: `bridge.workspace.set`

Outbound-only from iOS. Wire type string: `"bridge.workspace.set"`.

The `EventEnvelope` uses `self.sessionId` from `ConversationEventCoordinator` as the envelope `sessionId`. The server handler ignores the envelope `sessionId` field — authorization uses `context.sessionId` and `resolveDeviceForTool` (see below).

Payload:
```json
{
  "type": "bridge.workspace.set",
  "payload": {
    "deviceId": "string",
    "workspacePath": "string"
  }
}
```

### Three send triggers

**Trigger 1 — User edits the field** (in `setWorkspaceOverride`):
Sends if device is online and path is non-empty. See method semantics above.

---

**Trigger 2 — Bridge pairs** (in `.bridgePaired` handler):

```swift
// 1. Capture existing override BEFORE constructing the new record
let existingOverride = pairedBridgeDevices
    .first(where: { $0.deviceId == paired.deviceId })?.workspaceOverride

// 2. Upsert the new record (all fields explicit)
upsertPairedBridgeDevice(
    deviceId: paired.deviceId,
    deviceName: paired.deviceName,
    status: paired.status,
    lastSeen: nil,
    workspaceRoot: paired.workspaceRoot,   // from bridge.paired payload
    workspaceOverride: existingOverride    // preserved; nil on first-time pair
)

// 3. Send only if an override was previously stored
if let override = existingOverride, !override.isEmpty {
    // send bridge.workspace.set with deviceId and override path
}
```

---

**Trigger 3 — Bridge comes back online** (in `.bridgeStatus` handler):

```swift
// 1. Capture existing record BEFORE upserting
let existing = pairedBridgeDevices.first(where: { $0.deviceId == status.deviceId })

// 2. Upsert via the extended helper.
// The nil-keeps-existing semantics of the extended helper carry workspaceRoot and
// workspaceOverride through automatically. Existing call-site shape is preserved.
upsertPairedBridgeDevice(
    deviceId: status.deviceId,
    deviceName: existing?.deviceName ?? status.deviceId,
    status: status.status,
    lastSeen: status.lastSeen
    // workspaceRoot/workspaceOverride default nil → helper preserves existing values
)

// 3. Send only on offline→online transition with a stored override.
// If existing == nil (device not yet in list), there is no override — no send.
if existing?.status != "online",
   status.status == "online",
   let override = existing?.workspaceOverride, !override.isEmpty {
    // send bridge.workspace.set with deviceId and override path
}
```

### Server routing

`server.ts` handles `bridge.workspace.set` on the iOS WebSocket message handler — **not** routed through `ConductorService` or the LLM tool pipeline.

**Authorization:** Use `bridgeState.resolveDeviceForTool(context.sessionId, deviceId)`. This method already handles the iOS session-churn case (when iOS reconnects with a new sessionId, the bridge is still online and `resolveDeviceForTool` finds it via the global-online-device fallback). The authorization model is: if `resolveDeviceForTool` returns a device for this session + deviceId, the request is permitted.

```ts
const resolved = bridgeState.resolveDeviceForTool(context.sessionId, deviceId);
if (!resolved.device) {
  return; // drop silently — device not found or not accessible to this session
}
```

If authorized, look up `bridgeSocketsByDeviceId.get(deviceId)` and forward the event. Fire-and-forget. If bridge socket missing, drop silently.

### Bridge applies it

`BridgeCore.handleInboundText(_:)` has a `switch envelope.type` string dispatch. Add:

```swift
case "bridge.workspace.set":
    await handleWorkspaceSet(envelope)
```

`handleWorkspaceSet(_:)` implementation:

1. Extract `workspacePath` from `envelope.payload`
2. Validate with `FileManager.default.fileExists(atPath: path, isDirectory: &isDir)` synchronously on the actor's run loop (acceptable for local paths; may block on network mounts — accepted tradeoff in Out of Scope)
3. If valid directory: call `updateWorkspaceRoot(URL(fileURLWithPath: path))`

   `updateWorkspaceRoot` (already on `BridgeCore`):
   - Sets `config.workspaceRoot` to the new path (standardized)
   - Calls `withPrimaryWorkspaceRoot(newRoot, existing: config.workspaceRoots)` — prepends new root, appends all existing roots deduped, preserving additional startup-configured roots
   - Reconstructs `policy = WorkspacePolicy(workspaceRoots: updatedRoots)`
   - Calls `emitStatus()` then `sendRegisterIfPossible()` to keep the server in sync

4. If invalid: log warning via `emitLog`; workspace unchanged

## Error Handling

| Scenario | Behavior |
|---|---|
| Path doesn't exist or isn't a directory | Bridge logs warning via `emitLog`, workspace unchanged |
| Device is offline when user edits field | Override saved to UserDefaults; sent automatically on next offline→online transition |
| Empty / whitespace path | Treated as `nil`; no event sent; override cleared in storage |
| `resolveDeviceForTool` returns no device | Event silently dropped |
| Bridge socket not found or disconnected | Event silently dropped |

No client-side path validation — iOS cannot know what paths exist on the Mac.

## Components Changed

| Layer | File(s) | Change |
|---|---|---|
| iOS | `ConversationEventCoordinator.swift` | Add `workspaceRoot` + `workspaceOverride` to `PairedBridgeDevice`; extend `upsertPairedBridgeDevice` with 2 new optional params (nil defaults); update `.bridgePaired` handler per Trigger 2 pseudocode; update `.bridgeStatus` handler per Trigger 3 pseudocode; add `setWorkspaceOverride(deviceId:path:)` for Trigger 1; add `.bridgeWorkspaceSet` to exhaustive switch with `eventBus.emit` |
| iOS | `Event.swift` | Add `case bridgeWorkspaceSet(BridgeWorkspaceSet)` to `Event.Kind`; add `BridgeWorkspaceSet` struct; add `workspaceRoot: String?` to `BridgePaired` struct |
| iOS | `EventEnvelope.swift` | Add `"bridge.workspace.set"` outbound encoding in `init(event:)`; decode `workspaceRoot` in `"bridge.paired"` case of `toEvent()` |
| iOS | `SettingsView.swift` | Add workspace `TextField` per device in Bridge section; call `setWorkspaceOverride` on commit/focus-lost |
| Server | `server.ts` | Handle `bridge.workspace.set` from iOS socket; authorize via `resolveDeviceForTool(context.sessionId, deviceId)`; forward to bridge socket; add `workspaceRoot` to `bridge.paired` payload |
| macOS Bridge | `BridgeCore.swift` | Add `"bridge.workspace.set"` case in `handleInboundText`; add `handleWorkspaceSet(_:)` method |

## Out of Scope

- Error response event from bridge back to iOS (fire-and-forget)
- Clearing the workspace override from iOS does not reset the bridge's active workspace (would require a separate reset event)
- Multiple workspace roots per device from iOS (bridge already supports multiple roots at startup; iOS only sets one)
- LLM tool call to change workspace (Settings UI only)
- Network-mounted path blocking on synchronous `FileManager` validation (accepted tradeoff)
