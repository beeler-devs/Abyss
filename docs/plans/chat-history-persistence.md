# Chat History Persistence

## Overview

Persist the visible message thread (`ConversationMessage` array) per chat session so users can review past conversations after the app restarts. Only store finalized user and assistant messages — not tool calls, partial transcripts, or ephemeral events.

---

## What Already Exists

- `ConversationMessage` is already `Codable` — `id`, `role`, `text`, `isPartial`, `liveResponseId`, `timestamp` all serialize cleanly. **No type changes needed.**
- `ConversationViewModel.messages: [ConversationMessage]` is the source of truth for the displayed message list.
- `ChatListViewModel` already restores sessions by calling `viewModelFactory(persisted.sessionId)` → `ConversationViewModel(sessionId: persisted.sessionId)`. The `sessionId` is the natural per-session key.
- The `Documents` directory is the right place for per-session files — it's persistent, backed up, and accessible without special entitlements.

---

## Storage Design

One JSON file per chat session, stored in the app's `Documents/chat-history/` directory:

```
Documents/
  chat-history/
    {sessionId}.json       ← array of ConversationMessage
```

File format: `[ConversationMessage]` encoded with `JSONEncoder`. Lightweight — a typical session of 20 messages is ~5–10 KB.

**What gets stored:**
- Messages where `isPartial == false` and `role == .user` or `role == .assistant`
- System messages (role `.system`) are excluded — these are injected context, not conversation

**What does NOT get stored:**
- Partial transcripts (`isPartial == true`)
- Tool calls, agent cards, bridge output, email/calendar cards
- `EventBus` events (only the rendered message thread)

---

## Files to Create / Modify

```
ios/Abyss/Abyss/Models/
  ChatHistoryStore.swift          ← NEW: reads and writes per-session message files

ios/Abyss/Abyss/ViewModels/
  ConversationViewModel.swift     ← MODIFY: load on init, save on message append
```

No changes to `ChatSession.swift`, `ChatListViewModel.swift`, `ConversationMessage.swift`, or any server files.

---

## Part 1 — `ChatHistoryStore.swift` (NEW)

A simple file-backed store. Keep it stateless — no in-memory cache, just read/write to disk.

```swift
import Foundation

/// Reads and writes per-session message history to the Documents directory.
final class ChatHistoryStore {

    private let baseURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseURL = docs.appendingPathComponent("chat-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Load persisted messages for a session. Returns [] if none exist.
    func load(sessionId: String) -> [ConversationMessage] {
        let url = fileURL(for: sessionId)
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([ConversationMessage].self, from: data) else {
            return []
        }
        return messages
    }

    /// Overwrite the stored messages for a session.
    func save(_ messages: [ConversationMessage], sessionId: String) {
        let url = fileURL(for: sessionId)
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Delete stored history for a session (called when user deletes a chat).
    func delete(sessionId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
    }

    private func fileURL(for sessionId: String) -> URL {
        baseURL.appendingPathComponent("\(sessionId).json")
    }
}
```

---

## Part 2 — `ConversationViewModel.swift` (MODIFY)

### 2a. Add `ChatHistoryStore` and load on init

Add the store as a private property and load persisted messages at the end of `init`:

```swift
private let historyStore = ChatHistoryStore()
```

At the end of `init(sessionId:)`, after all existing setup:

```swift
// Restore persisted message history for this session
let persisted = historyStore.load(sessionId: sessionId)
if !persisted.isEmpty {
    self.messages = persisted
}
```

This works because `ChatListViewModel` passes the original `sessionId` back to `viewModelFactory` when restoring a session, so the same file is loaded.

### 2b. Save after each finalized message is appended

Find where messages are appended to `self.messages` in `ConversationViewModel`. These are the places where `isPartial` transitions to `false` or a new complete message is added.

After any append that results in a finalized message, call:

```swift
persistMessages()
```

Add the private helper:

```swift
private func persistMessages() {
    let toSave = messages.filter { !$0.isPartial && $0.role != .system }
    historyStore.save(toSave, sessionId: sessionId)
}
```

**When to call `persistMessages()`:**
- After a user message is appended (always finalized immediately)
- After `isPartial` is set to `false` on an assistant message (i.e., when the streaming response completes)
- After a system message is appended that carries visible content (optional — skip system messages)

Do **not** call it on every partial update — only on finalization events to avoid excessive disk writes.

### 2c. Delete history when a chat is deleted

In `ChatListViewModel.deleteChat(id:)`, after `chats.removeAll`:

```swift
// Find the sessionId before removing
if let chat = chats.first(where: { $0.id == id }) {
    ChatHistoryStore().delete(sessionId: chat.sessionId)
}
```

Wait — `chats.removeAll` happens before we can get the sessionId. Reorder:

```swift
func deleteChat(id: UUID) {
    if let chat = chats.first(where: { $0.id == id }) {
        ChatHistoryStore().delete(sessionId: chat.sessionId)  // clean up file first
    }
    chats.removeAll { $0.id == id }
    if selectedChatId == id {
        selectedChatId = chats.first?.id
    }
    persistChats()
}
```

---

## Part 3 — Auto-name Chats (BEE-62, simplified version)

Since we're already touching message persistence, add the fallback auto-naming path here cheaply. After the first user message is finalized and persisted, if the chat title is still "New Chat":

In `ChatListViewModel`, expose an `updateTitle(for:title:)` method:

```swift
func updateTitle(for sessionId: String, title: String) {
    guard let index = chats.firstIndex(where: { $0.sessionId == sessionId }) else { return }
    chats[index].title = title
    persistChats()
}
```

In `ConversationViewModel`, after the first user message is appended, generate a title from the first 5 words:

```swift
private func autoNameIfNeeded(from text: String) {
    // Only run once — if the chat already has a real title, skip
    // ConversationViewModel doesn't own the title, so notify upward via a callback
    guard let onFirstMessage, messages.filter({ $0.role == .user && !$0.isPartial }).count == 1 else { return }
    let words = text.split(separator: " ").prefix(5).joined(separator: " ")
    let title = words.isEmpty ? "New Chat" : words
    onFirstMessage(title)
}
```

Wire `onFirstMessage: ((String) -> Void)?` as an optional init parameter on `ConversationViewModel`, set from `ChatListViewModel.viewModelFactory`.

This avoids the server round-trip entirely and is a reliable same-session implementation.

---

## What NOT to Change

- `ConversationMessage` — already Codable, no changes needed
- `ChatSession` / `PersistedChatSession` — no changes needed (messages stored separately)
- `EventBus` — not used for persistence
- Server — no changes
- Bridge, Cursor, Gmail, Canvas integrations — no changes

---

## Edge Cases

| Case | Behavior |
|---|---|
| New chat (no prior history) | `load()` returns `[]`, messages starts empty as before |
| App restart mid-conversation | Messages reload from file, partial messages excluded |
| User deletes chat | `delete(sessionId:)` cleans up the file |
| Very long conversation | No size limit enforced — typical sessions are <50KB. Add a max of 200 messages if needed. |
| Two sessions with same sessionId | Not possible — sessionId is a UUID generated once per session |
| Storage failure (disk full) | `try?` swallows errors silently, no crash |
