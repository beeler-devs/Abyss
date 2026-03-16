# Pending Merges

Branches with completed work waiting to be merged into `main`.

## BEE-51: Siri App Intents Integration

- **Branch:** `bentontameling/bee-51-siri-app-intents-integration`
- **Worktree:** `.worktrees/bee-51-siri-intents`
- **Status:** Build passing, ready to merge
- **Date:** 2026-03-16

Registers 3 App Intents surfaced via `AppShortcutsProvider` so users can trigger Abyss from Siri/Shortcuts:
- **StartConversationIntent** — foreground, opens app in listening mode
- **QuickCommandIntent** — background, sends text to conductor via lightweight one-shot WebSocket, returns LLM response as Siri dialog
- **AgentStatusIntent** — background, checks most recent Cursor agent status

**Files added:** 6 new files in `ios/Abyss/Abyss/Intents/`
**Files modified:** `AbyssApp.swift`, `project.pbxproj`, `CLAUDE.md`

## Memory User Key iOS Integration

- **Branch:** `feature/memory-user-key-ios`
- **Worktree:** `.worktrees/memory-user-key-ios`
- **Status:** Build passing, ready to merge
- **Date:** 2026-03-16

Threads a stable `memoryUserKey` (UUID persisted in UserDefaults) through the iOS `session.start` event so the server-side Bedrock Knowledge Bases memory system can identify the user across sessions. Server already handles retrieval/summarization — this is the iOS plumbing only.

**Files modified:** `Event.swift`, `EventEnvelope.swift`, `ConductorProtocol.swift`, `WebSocketConductorClient.swift`, `LocalConductorClient.swift`, `ConversationViewModel.swift`
