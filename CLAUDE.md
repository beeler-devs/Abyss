# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Abyss is a voice-first AI personal assistant architecture. An iOS client streams speech to a Node.js WebSocket server, which orchestrates LLM tool calls, and optionally routes privileged operations (filesystem, shell commands) to a paired macOS bridge. It serves as both a coding assistant (via Cursor Cloud Agents and macOS bridge) and a personal assistant (email, scheduling, and more).

**Components:**
- `server/` — Node.js/TypeScript WebSocket conductor (primary development target)
- `ios/` — SwiftUI iOS client app
- `mac/` — macOS bridge (SwiftUI app + headless CLI + BridgeCore package)
- `shared/` — JSON schemas and shared TypeScript/Swift protocol libraries

## Development Commands

### Server
```bash
cd server
npm run dev        # Watch-mode dev server (tsx watch)
npm run build      # Compile TypeScript to dist/
npm start          # Run compiled server
npm test           # Run all tests (Node built-in test runner via tsx)
npm run smoke      # Integration smoke test
```

### Run a single test file
```bash
cd server && npx tsx --test tests/conductorService.test.ts
```

### Local dev (all services)
```bash
./scripts/dev/start-local.sh
```

### macOS Bridge
```bash
# GUI app
cd mac/AbyssBridge && swift run

# CLI (headless)
cd mac/BridgeCLI && swift run abyss-bridge --server ws://localhost:8080/ws --workspace . --name "My Mac"
```

### iOS App
```bash
# Build via Xcode CLI (requires xcode-select pointing to Xcode.app, not CommandLineTools)
# If xcodebuild fails, run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build
```

**Note:** On this machine, `xcode-select` often points at `/Library/Developer/CommandLineTools` instead of Xcode.app. If `xcodebuild` fails with "requires Xcode", ask the user to run the `sudo xcode-select -s` command above — it requires their password.

## Architecture

### Event System
All communication uses `EventEnvelope` — a strict JSON schema with `id`, `type`, `sessionId`, `protocolVersion`, `timestamp`, and `payload`. Protocol version is `1`. Events are append-only and deterministic IDs are derived via SHA256.

### Server Flow
1. iOS sends a `user.speech.final` event over WebSocket to `/ws`
2. `ConductorService` processes it: maintains session history, calls the LLM, streams responses
3. LLM responds with tool calls → conductor emits `tool.call` events
4. Tools execute locally (iOS handles `audio.*`, `ui.*`) or are routed to the bridge (`bridge.exec.run`, `bridge.fs.*`)
5. Tool results are sent back as `tool.result` events → conductor resumes LLM
6. For `gmail.send`/`gmail.reply`, server emits a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS → iOS shows a draft card with Send/Cancel → user confirms → server sends the email

### Context Summarization
When conversation history exceeds `SUMMARIZE_AFTER_TURNS` (default 30 entries), `contextSummarizer.ts` uses the LLM to compress older turns into a 3-6 sentence summary. The summary is stored in `SessionState.historySummary` and prepended to the conversation as a user/assistant turn pair before each `generateResponse()` call. Summarization runs fire-and-forget after `runConductorLoop()` completes — no latency impact on the current response. Config: `SUMMARIZE_AFTER_TURNS` (threshold), `SUMMARIZE_RECENT_KEEP` (turns kept in full, default 10).

### User Preferences
LLM-writable preference store that persists across sessions. iOS is source of truth.

**Flow:** LLM calls `preferences.set(key, value)` → `UserPreferencesStore` writes to UserDefaults → `PreferencesSetTool.onUpdate` sends `preferences.sync` event to server → `ConductorService` updates `session.userPreferences`. On connect/reconnect, preferences are sent via `session.start` payload.

**Dynamic system prompt:** Both providers (`bedrockNovaProvider.ts`, `anthropicProvider.ts`) accept `userPreferences` in `generateResponse()` and append them to the system prompt as `"User preferences (apply throughout): - key: value"`.

**Key convention:** `user.name`, `user.timezone`, `communication.style`, `communication.verbosity`, `email.style`, `email.signoff`, `custom.*` for free-form.

**Files:**
- `ios/.../Models/UserPreferencesStore.swift` — `@MainActor ObservableObject`, UserDefaults-backed `[String: String]`
- `ios/.../Tools/PreferencesSetTool.swift` — `preferences.set` tool (key, value args)
- `ios/.../Tools/PreferencesGetTool.swift` — `preferences.get` tool (returns all prefs)
- `Event.swift` — `SessionStart.preferences` field, `preferencesSync` event kind
- `EventEnvelope.swift` — Serialization for preferences in `session.start` and `preferences.sync`
- `server/src/core/types.ts` — `SessionState.userPreferences`, `ModelProvider.generateResponse()` accepts preferences

### Key Server Files
- `server/src/server.ts` — HTTP/WS server setup; maintains `iosSocketsBySession` and `bridgeSocketsByDeviceId` maps
- `server/src/core/conductorService.ts` — Orchestrates conversation turns, tool dispatch, rate limiting, Cursor integration
- `server/src/core/types.ts` — All shared TypeScript types (`EventEnvelope`, `SessionState`, `ModelProvider`, etc.)
- `server/src/core/events.ts` — Event parsing, validation, and creation utilities
- `server/src/bridge/state.ts` — Device pairing and online/offline tracking
- `server/src/bridge/toolRouter.ts` — Routes bridge tools to connected macOS devices
- `server/src/providers/` — Pluggable LLM backends; factory in `index.ts`
- `server/src/integrations/` — External API clients: `canvasClient.ts` (Canvas LMS), `gmailClient.ts`/`gmailAuth.ts` (Gmail), `calendarClient.ts` (Google Calendar), `cursorClient.ts`/`cursorPayload.ts`/`cursorWebhook.ts` (Cursor Cloud Agents)
- `server/src/voice/` — Voice providers; `bedrockNovaSonicVoiceProvider.ts` for Nova Sonic streaming

### Model Providers
Selected via `MODEL_PROVIDER` env var:
- `bedrock` (default) — Amazon Nova via AWS Bedrock (`bedrockNovaProvider.ts`)
- `anthropic` — Claude via Anthropic API (`anthropicProvider.ts`)

### Bridge Pairing
macOS bridge connects to `/ws` with a `bridge.pair` event. Server tracks `deviceId → WebSocket`. When a bridge tool call arrives, `toolRouter` finds the paired device and forwards it; the bridge executes and returns a `tool.result`.

### iOS UI Architecture

#### Key iOS Files
- `ios/.../App/AbyssApp.swift` — App entry point; injects `@EnvironmentObject`s (`GitHubAuthManager`, `GmailAuthManager`, `CanvasManager`, `InAppBrowserCoordinator`)
- `ios/.../App/AppTheme.swift` — Centralized theme colors; all colors are `colorScheme`-aware
- `ios/.../App/Config.swift` — Centralized config; reads from Secrets.plist → Info.plist → env vars
- `ios/.../App/AppLogger.swift` — OSLog categories: `audio`, `conductor`, `conversation`, `tooling`
- `ios/.../ViewModels/ConversationViewModel.swift` — Primary VM; orchestrates audio pipeline, event coordinator, agent manager, tool registry, conductor client
- `ios/.../ViewModels/ConversationAgentManager.swift` — Agent lifecycle: progress cards, polling/webhook updates, conversation messages
- `ios/.../ViewModels/ConversationAudioPipeline.swift` — Audio state machine: VAD, mic lifecycle, PTT, transcription
- `ios/.../Models/ChatSession.swift` — `ChatSession` + `ChatListViewModel`; multi-chat with UserDefaults persistence
- `ios/.../Models/Event.swift` — `Event` struct with 26 event kinds + `EventBus` (append-only log with Combine publisher)
- `ios/.../Views/ContentView.swift` — Root view with sidebar, chat content, sheet presentations
- `ios/.../Views/InAppBrowserView.swift` — WKWebView in-app browser + `InAppBrowserCoordinator`
- `ios/.../Views/SettingsView.swift` — Appearance, recording mode, Cursor API key, Connections (Gmail/Canvas/coming-soon integrations), bridge pairing

#### iOS Feature Systems

**Multi-Chat Management:** `ChatListViewModel` manages multiple `ChatSession`s with sidebar navigation. Each session has its own `ConversationViewModel`. Persisted via UserDefaults.

**GitHub OAuth:** `GitHubAuthManager` implements full OAuth 2.0 via `ASWebAuthenticationSession`. Token stored in Keychain. Scopes: `repo`, `read:org`, `read:user`. Client ID from `GITHUB_CLIENT_ID` in Secrets.plist. Login UI in `GitHubLoginView`.

**Cursor Cloud Agents:** 6 tools in `Tools/Agent/` — `AgentSpawnTool`, `AgentStatusTool`, `AgentCancelTool`, `AgentFollowUpTool`, `RepositoriesListTool`, `AgentListTool`. API client: `CursorCloudAgentsClient`. UI: `AgentProgressCardView` with progress bars, conversation log, PR/agent-run links.

**Repository Selection:** `RepositorySelectionManager` presents an interactive modal for user to pick a repo during tool execution. Uses `CheckedContinuation` to suspend tool execution until selection. UI: `RepositorySelectionCardView`.

**Email Draft Confirmation:** When the LLM calls `gmail.send` or `gmail.reply`, the server emits a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS. `EmailDraftManager` (using `CheckedContinuation` suspension like `RepositorySelectionManager`) presents an `EmailDraftCardView` with Send/Cancel buttons. The tool execution suspends until the user acts, then returns the confirmation to the server which completes the actual send.

**Google Calendar Integration:** Reuses the same Google OAuth tokens as Gmail (calendar scope added to `GmailAuthManager`). Server-side `CalendarClient` (`server/src/integrations/calendarClient.ts`) provides 5 tools: `calendar.list`, `calendar.get`, `calendar.create`, `calendar.update`, `calendar.delete`. Mutations use the same confirmation card pattern as email — `CalendarDraftManager` with `CheckedContinuation` suspension, `CalendarDraftCardView` with Confirm/Cancel buttons. Read results render as `CalendarEventCardView` cards in the transcript via `ConversationCalendarManager`.

**Canvas LMS Integration:** `CanvasManager` stores a personal access token + base URL in Keychain (no OAuth needed). Settings UI has a "Connections" section with a modal to enter token. `CanvasAuthenticateTool` directs users to Settings when the LLM needs Canvas access. Server-side `CanvasClient` provides 6 tools: `canvas.courses`, `canvas.assignments`, `canvas.todo`, `canvas.upcoming`, `canvas.grades`, `canvas.announcements`. Token is threaded through `SessionStart` → `WebSocketConductorClient` → `ConductorService`.

**Audio Pipeline:** `ConversationAudioPipeline` manages two recording modes: VAD auto-detection (`vadAuto`) and push-to-talk (`pushToTalk`). STT via `WhisperKitSpeechTranscriber` (on-device) or streamed to backend (`novaSonic`). TTS via `ElevenLabsTTS` with system voice fallback.

**Tool System:** `ToolProtocol` with `AnyTool` type erasure → `ToolRegistry` for registration → `ToolRouter` for event dispatch. Categories: Audio (`STTStart/Stop`, `TTSSpeak/Stop`), Conversation (`ConvoAppendMessage`, `ConvoSetState`), Agent (6 tools above), Gmail (`GmailAuthenticateTool`, `GmailSendConfirmTool`, `GmailReplyConfirmTool`), Calendar (`CalendarCreateConfirmTool`, `CalendarUpdateConfirmTool`, `CalendarDeleteConfirmTool`), Canvas (`CanvasAuthenticateTool`), Preferences (`PreferencesSetTool`, `PreferencesGetTool`).

**Conductor Clients:** `WebSocketConductorClient` (primary) — URLSession-based with auto-reconnect, exponential backoff, ping/pong keep-alive, AsyncStream inbound events. `LocalConductorClient` / `LocalConductorStub` for offline/testing.

#### iOS Patterns
- Shared state uses `@StateObject` in `AbyssApp` + `@EnvironmentObject` in child views
- Theming via `AppTheme` static methods that take `colorScheme` parameter
- `@AppStorage` for persisted preferences: `appAppearance`, `recordingMode`, `voiceMode`, `cursorAPIKey`, `cursorAgentModel`, `elevenLabsVoiceId`. **Gotcha:** `@AppStorage` on `ObservableObject` does NOT fire `objectWillChange` — SwiftUI views won't re-render. Use `@Published` with manual `UserDefaults` sync in `didSet` instead (see `isTTSMuted` in `ConversationViewModel`).
- Manager/Coordinator pattern: `ConversationAgentManager`, `ConversationEventCoordinator`, `ConversationEmailManager`, `ConversationCalendarManager`, `RepositorySelectionManager`, `EmailDraftManager`, `CalendarDraftManager`, `InAppBrowserCoordinator`
- `@MainActor` isolation for all UI/state management; `@unchecked Sendable` for backward compat

#### Xcode Project Gotcha
When adding new `.swift` files to the iOS project, they MUST be manually added to `ios/Abyss/Abyss.xcodeproj/project.pbxproj` in 4 places:
1. **PBXBuildFile section** — `A1...` ID with `in Sources` reference
2. **PBXFileReference section** — `A2...` ID with file path
3. **PBXGroup section** — add the `A2...` ref to the appropriate group (Services, Tools, Views, etc.)
4. **PBXSourcesBuildPhase section** — add the `A1...` build file ref

IDs follow the pattern `A1000000000000010000XXXX` (build) / `A2000000000000010000XXXX` (file ref), incrementing the last hex digits. Without this, Xcode won't compile the file and you'll get "Cannot find type in scope" errors.

#### Markdown Rendering
Assistant messages rendered via `MarkdownTextView` → parses into `.text` (inline formatting) and `.codeBlock(language, code)` (terminal-style with copy button). User messages use plain `Text`.

## Agent Workflow Guidelines

### Committing Changes
- **Always commit when done** — at the end of any task, commit all changes with a descriptive message.
- **Commit incrementally on large tasks** — if working on a multi-step or large feature, commit logical checkpoints along the way (e.g., after each major component is complete), not just at the end.
- Use clear commit messages that describe what changed and why.

### Keeping CLAUDE.md Up to Date
- **Always update this file at the end of every task** — not just for new features. This includes: gotchas encountered, commands discovered, patterns followed, environment quirks, and configuration learnings.
- This covers: new components, new tools, new iOS feature systems, new server routes, new environment variables, changed file responsibilities, or updated patterns.
- Keep entries concise — follow the style of existing sections.

## Environment Configuration

Copy `server/.env.example` to `server/.env`. Key variables:

| Variable | Default | Notes |
|---|---|---|
| `PORT` | 8080 | WebSocket server port |
| `MODEL_PROVIDER` | `bedrock` | `bedrock` or `anthropic` |
| `VOICE_PROVIDER` | `local` | `local` or `nova-sonic` |
| `BEDROCK_TEXT_MODEL_ID` | `us.amazon.nova-2-lite-v1:0` | Primary LLM |
| `ANTHROPIC_API_KEY` | — | Required if using `anthropic` provider |
| `AWS_REGION` | `us-east-1` | Required for Bedrock |
| `CURSOR_API_KEY` | — | Optional; enables server-side Cursor agent tools |
| `GOOGLE_CLIENT_ID` | — | Required for Gmail + Calendar OAuth |
| `GOOGLE_CLIENT_SECRET` | — | Required for Gmail + Calendar OAuth |

AWS credentials are resolved via standard SDK chain (profile, env vars, or instance role).

### iOS Configuration
iOS reads from `Secrets.plist` (gitignored) → `Info.plist` → environment variables. Key values:
- `GITHUB_CLIENT_ID` — Required for GitHub OAuth login
- `ELEVEN_LABS_API_KEY` — Required for ElevenLabs TTS (falls back to system voice)
- `CURSOR_API_KEY` — Required for Cursor Cloud Agents (also configurable in Settings UI)
- `BACKEND_WS_URL` — WebSocket server URL (defaults to `ws://localhost:8080/ws`)
- `CANVAS_BASE_URL` — Optional default Canvas LMS URL (defaults to `https://canvas.cmu.edu`; also configurable in Settings UI)
