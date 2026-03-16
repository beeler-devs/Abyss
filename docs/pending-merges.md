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
