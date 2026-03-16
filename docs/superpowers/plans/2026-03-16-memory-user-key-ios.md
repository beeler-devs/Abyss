# Memory User Key iOS Integration Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thread a stable `memoryUserKey` through the iOS `session.start` event so the server's Bedrock Knowledge Bases memory system can retrieve and store per-user conversation memory.

**Architecture:** The server already reads `memoryUserKey` from the `session.start` payload and handles everything else (retrieval on first turn, summarization on disconnect). The iOS side just needs to generate a stable user identifier, persist it, and include it in the `session.start` event. We use a UUID stored in UserDefaults — it survives app restarts but is device-scoped, which is appropriate since there's no cross-device user account system.

**Tech Stack:** Swift, UserDefaults, existing `Event`/`EventEnvelope`/`ConductorClient` architecture

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `ios/Abyss/Abyss/Models/Event.swift` | Modify | Add `memoryUserKey` to `SessionStart` struct and factory |
| `ios/Abyss/Abyss/Models/EventEnvelope.swift` | Modify | Serialize `memoryUserKey` in `session.start` payload |
| `ios/Abyss/Abyss/Conductor/ConductorProtocol.swift` | Modify | Add `memoryUserKey` param to `ConductorClient.connect()` |
| `ios/Abyss/Abyss/Conductor/WebSocketConductorClient.swift` | Modify | Store and thread `memoryUserKey` through connect/reconnect |
| `ios/Abyss/Abyss/Conductor/LocalConductorClient.swift` | Modify | Accept `memoryUserKey` param (unused, protocol conformance) |
| `ios/Abyss/Abyss/ViewModels/ConversationViewModel.swift` | Modify | Generate/load stable key and pass to `connect()` |

No new files needed. This follows the exact same pattern used for `canvasAccessToken`, `gmailAccessToken`, etc.

---

### Task 1: Add `memoryUserKey` to the Event model

**Files:**
- Modify: `ios/Abyss/Abyss/Models/Event.swift:52-61` (SessionStart struct)
- Modify: `ios/Abyss/Abyss/Models/Event.swift:271-291` (sessionStart factory)

- [ ] **Step 1: Add `memoryUserKey` field to `SessionStart` struct**

In `Event.swift`, add `memoryUserKey` as the last field in `SessionStart`:

```swift
struct SessionStart: Codable, Sendable {
    let sessionId: String
    let githubToken: String?
    let gmailAccessToken: String?
    let gmailRefreshToken: String?
    let gmailTokenExpiresAt: Double?
    let canvasAccessToken: String?
    let canvasBaseURL: String?
    let preferences: [String: String]?
    let memoryUserKey: String?
}
```

- [ ] **Step 2: Add `memoryUserKey` param to the `sessionStart` factory**

Update the `static func sessionStart(...)` convenience factory (around line 271) to accept and pass through `memoryUserKey`:

```swift
static func sessionStart(
    sessionId: String = UUID().uuidString,
    githubToken: String? = nil,
    gmailAccessToken: String? = nil,
    gmailRefreshToken: String? = nil,
    gmailTokenExpiresAt: Double? = nil,
    canvasAccessToken: String? = nil,
    canvasBaseURL: String? = nil,
    preferences: [String: String]? = nil,
    memoryUserKey: String? = nil
) -> Event {
    Event(sessionId: sessionId, kind: .sessionStart(SessionStart(
        sessionId: sessionId,
        githubToken: githubToken,
        gmailAccessToken: gmailAccessToken,
        gmailRefreshToken: gmailRefreshToken,
        gmailTokenExpiresAt: gmailTokenExpiresAt,
        canvasAccessToken: canvasAccessToken,
        canvasBaseURL: canvasBaseURL,
        preferences: preferences,
        memoryUserKey: memoryUserKey
    )))
}
```

- [ ] **Step 3: Build to verify no compile errors**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/Abyss/Abyss/Models/Event.swift
git commit -m "Add memoryUserKey field to SessionStart event model"
```

---

### Task 2: Serialize `memoryUserKey` in the EventEnvelope

**Files:**
- Modify: `ios/Abyss/Abyss/Models/EventEnvelope.swift:41-59` (session.start case in `init(event:)`)

- [ ] **Step 1: Add `memoryUserKey` serialization**

In `EventEnvelope.init(event:)`, inside the `.sessionStart` case (around line 41-59), add after the existing Canvas fields and before the preferences block:

```swift
if let memoryUserKey = value.memoryUserKey {
    sessionPayload["memoryUserKey"] = .string(memoryUserKey)
}
```

Place it right before the existing `if let prefs = value.preferences` block.

- [ ] **Step 2: Update `toEvent()` deserialization to include the new field**

In the same file, `toEvent()` has two callsites that construct `SessionStart` (for `"session.start"` at line 247 and `"session.started"` at line 250). Both need `memoryUserKey: nil` added — this is a client-to-server-only field so the server never sends it back:

```swift
// Line 247 — "session.start" case:
kind = .sessionStart(Event.SessionStart(sessionId: session, githubToken: nil, gmailAccessToken: nil, gmailRefreshToken: nil, gmailTokenExpiresAt: nil, canvasAccessToken: nil, canvasBaseURL: nil, preferences: nil, memoryUserKey: nil))

// Line 250 — "session.started" case:
kind = .sessionStart(Event.SessionStart(sessionId: session, githubToken: nil, gmailAccessToken: nil, gmailRefreshToken: nil, gmailTokenExpiresAt: nil, canvasAccessToken: nil, canvasBaseURL: nil, preferences: nil, memoryUserKey: nil))
```

- [ ] **Step 3: Build to verify**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/Abyss/Abyss/Models/EventEnvelope.swift
git commit -m "Serialize memoryUserKey in session.start envelope payload"
```

---

### Task 3: Thread `memoryUserKey` through ConductorClient protocol and implementations

**Files:**
- Modify: `ios/Abyss/Abyss/Conductor/ConductorProtocol.swift:16`
- Modify: `ios/Abyss/Abyss/Conductor/WebSocketConductorClient.swift:296-327` (connect method)
- Modify: `ios/Abyss/Abyss/Conductor/WebSocketConductorClient.swift:436-446` (reconnect)
- Modify: `ios/Abyss/Abyss/Conductor/LocalConductorClient.swift:19`

- [ ] **Step 1: Add `memoryUserKey` to the `ConductorClient` protocol**

In `ConductorProtocol.swift`, update the `connect` signature on line 16:

```swift
func connect(sessionId: String, githubToken: String?, gmailAccessToken: String?, gmailRefreshToken: String?, gmailTokenExpiresAt: Double?, canvasAccessToken: String?, canvasBaseURL: String?, preferences: [String: String]?, memoryUserKey: String?) async throws
```

- [ ] **Step 2: Update `WebSocketConductorClient.connect()`**

Add a stored property alongside the other `current*` properties (around line 230):

```swift
private var currentMemoryUserKey: String?
```

Update the `connect` method signature (around line 296) to include the new param:

```swift
func connect(
    sessionId: String,
    githubToken: String? = nil,
    gmailAccessToken: String? = nil,
    gmailRefreshToken: String? = nil,
    gmailTokenExpiresAt: Double? = nil,
    canvasAccessToken: String? = nil,
    canvasBaseURL: String? = nil,
    preferences: [String: String]? = nil,
    memoryUserKey: String? = nil
) async throws {
```

Store it:

```swift
currentMemoryUserKey = memoryUserKey
```

Pass it to `Event.sessionStart(...)`:

```swift
try await send(event: Event.sessionStart(
    sessionId: sessionId,
    githubToken: githubToken,
    gmailAccessToken: gmailAccessToken,
    gmailRefreshToken: gmailRefreshToken,
    gmailTokenExpiresAt: gmailTokenExpiresAt,
    canvasAccessToken: canvasAccessToken,
    canvasBaseURL: canvasBaseURL,
    preferences: preferences,
    memoryUserKey: memoryUserKey
))
```

- [ ] **Step 3: Update the reconnect path**

In `scheduleReconnect()` (around line 437), update the `Event.sessionStart(...)` call to also pass `memoryUserKey`:

```swift
try await self.send(event: Event.sessionStart(
    sessionId: sessionId,
    githubToken: self.currentGithubToken,
    gmailAccessToken: self.currentGmailAccessToken,
    gmailRefreshToken: self.currentGmailRefreshToken,
    gmailTokenExpiresAt: self.currentGmailTokenExpiresAt,
    canvasAccessToken: self.currentCanvasAccessToken,
    canvasBaseURL: self.currentCanvasBaseURL,
    preferences: self.currentPreferences,
    memoryUserKey: self.currentMemoryUserKey
))
```

- [ ] **Step 4: Update `LocalConductorClient.connect()`**

In `LocalConductorClient.swift`, update the `connect` signature on line 19:

```swift
func connect(sessionId: String, githubToken: String? = nil, gmailAccessToken: String? = nil, gmailRefreshToken: String? = nil, gmailTokenExpiresAt: Double? = nil, canvasAccessToken: String? = nil, canvasBaseURL: String? = nil, preferences: [String: String]? = nil, memoryUserKey: String? = nil) async throws {
```

No other changes needed in this file — it's a local stub, memory is server-side only.

- [ ] **Step 5: Build to verify all protocol conformances compile**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add ios/Abyss/Abyss/Conductor/ConductorProtocol.swift ios/Abyss/Abyss/Conductor/WebSocketConductorClient.swift ios/Abyss/Abyss/Conductor/LocalConductorClient.swift
git commit -m "Thread memoryUserKey through ConductorClient protocol and implementations"
```

---

### Task 4: Generate stable user key and pass it at connect time

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationViewModel.swift:574-591` (connectConductorClient method)

- [ ] **Step 1: Add a static helper to generate/load the stable key**

Add a `private static` property or method at the top of `ConversationViewModel` (or as a file-level `private` function — whichever matches the file's existing style). This generates a UUID on first launch and persists it:

```swift
private static let memoryUserKey: String = {
    let key = "memoryUserKey"
    if let existing = UserDefaults.standard.string(forKey: key) {
        return existing
    }
    let newKey = UUID().uuidString
    UserDefaults.standard.set(newKey, forKey: key)
    return newKey
}()
```

- [ ] **Step 2: Pass `memoryUserKey` in the `connectConductorClient` call**

In `connectConductorClient(_:)` (around line 582), add `memoryUserKey` to the `client.connect(...)` call:

```swift
try await client.connect(
    sessionId: sessionId,
    githubToken: githubToken,
    gmailAccessToken: gmailAccessToken,
    gmailRefreshToken: gmailRefreshToken,
    gmailTokenExpiresAt: gmailTokenExpiresAt,
    canvasAccessToken: canvasAccessToken,
    canvasBaseURL: canvasBaseURL,
    preferences: prefs.isEmpty ? nil : prefs,
    memoryUserKey: Self.memoryUserKey
)
```

- [ ] **Step 3: Build to verify**

Run: `cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ios/Abyss/Abyss/ViewModels/ConversationViewModel.swift
git commit -m "Generate stable memoryUserKey and send in session.start"
```

---

### Task 5: Verify end-to-end with server

This is a manual verification task — no code changes.

- [ ] **Step 1: Ensure `MEMORY_ENABLED=true` and `MEMORY_S3_BUCKET` are set in `server/.env`**

Check `server/.env` for:
```
MEMORY_ENABLED=true
MEMORY_S3_BUCKET=<your-bucket-name>
```

If not set, the memory feature is a no-op on the server — all iOS changes are still safe (the key is simply ignored), but memory won't actually work.

- [ ] **Step 2: Run the server locally and connect the iOS app**

Run: `cd server && npm run dev`

Open the iOS app in the simulator, start a conversation. Check server logs for:
- `memoryUserKey` appearing in the session.start processing
- `session.memory.loaded` event if prior memories exist

- [ ] **Step 3: Verify the key persists across app restarts**

Kill and reopen the app. The same `memoryUserKey` UUID should be sent in the new `session.start`. Verify by checking server logs or adding a temporary `print(Self.memoryUserKey)` in the connect method.
