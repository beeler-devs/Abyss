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
6. Server-side tools (`gmail.inbox`, `gmail.search`, `gmail.read`, `canvas.*`, `calendar.*`) execute directly on the server and return results to the LLM
7. For `gmail.send`/`gmail.reply`, server emits a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS → iOS shows an **editable** draft card (To, Subject, Body are tappable text fields) → server returns immediately (non-blocking) so the user can send follow-up messages while reviewing → user edits fields and taps Send → iOS sends `gmail.send.execute` event with edited values → server sends the email and emits `gmail.send.result`

### Inline Card Rendering
When server-side tools (gmail.*, calendar.*, canvas.*) return results, `ConductorService.enrichResultWithCardIds()` injects a `cardId` (UUID) into each item in the JSON. The enriched result is sent to both iOS (for card managers) and the LLM (with a card summary instruction). The LLM references cards inline in its response via `` ```card:TYPE:CARD_ID``` `` fenced blocks. On iOS, `MarkdownTextView` parses these as `.cardReference` blocks and resolves them via `TranscriptView.resolveCard()` to render actual card views inline in the prose. Cards rendered inline are excluded from the anchored/unanchored card sections to avoid duplication. During streaming, unresolved card references show a `CardPlaceholderView` with shimmer animation.

**Card types:** `email`, `calendar`, `canvas` (with future support for `agent`, `bridge`)

**Files:**
- `server/src/core/conductorService.ts` — `enrichResultWithCardIds()`, `cardTypeForTool()`
- `ios/.../Views/MarkdownTextView.swift` — `Block.cardReference`/`.cardPlaceholder` cases, `cardResolver` closure
- `ios/.../Views/CardPlaceholderView.swift` — Placeholder with generic/typed/unresolved states
- `ios/.../Views/TranscriptView.swift` — `resolveCard()`, dedup logic in `transcriptItems`
- All card models (`EmailCard`, `CalendarEventCard`, `CanvasCard`, `BridgeExecCard`, `AgentProgressCard`) — `serverCardId: String?`
- Card managers (`ConversationEmailManager`, `ConversationCalendarManager`, `ConversationCanvasManager`) — parse `cardId` from enriched JSON

### Context Summarization
When conversation history exceeds `SUMMARIZE_AFTER_TURNS` (default 30 entries), `contextSummarizer.ts` uses the LLM to compress older turns into a 3-6 sentence summary. The summary is stored in `SessionState.historySummary` and prepended to the conversation as a user/assistant turn pair before each `generateResponse()` call. Summarization runs fire-and-forget after `runConductorLoop()` completes — no latency impact on the current response. Config: `SUMMARIZE_AFTER_TURNS` (threshold), `SUMMARIZE_RECENT_KEEP` (turns kept in full, default 10).

### User Preferences
LLM-writable preference store that persists across sessions. iOS is source of truth.

**Flow:** LLM calls `preferences.set(key, value)` → `UserPreferencesStore` writes to UserDefaults → `PreferencesSetTool.onUpdate` sends `preferences.sync` event to server → `ConductorService` updates `session.userPreferences`. On connect/reconnect, preferences are sent via `session.start` payload.

**Dynamic system prompt:** Both providers (`bedrockNovaProvider.ts`, `anthropicProvider.ts`) accept `userPreferences` in `generateResponse()` and append them to the system prompt as `"User preferences (apply throughout): - key: value"`.

**Key convention:** `user.name`, `user.timezone`, `communication.style`, `communication.verbosity`, `email.style`, `email.signoff`, `bridge.claude.allowedTools` (comma-separated Claude Code tools: Bash, Read, Edit, Write, LS, Glob, Grep, MultiEdit), `custom.*` for free-form.

**First-run gate for Claude Code:** When `bridge.claude.run` is called and no `bridge.claude.allowedTools` preference exists, the tool returns a prompt instructing the LLM to ask the user which tools to allow before proceeding. The user's choice is saved via `preferences.set` and persists across sessions.

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

**Auto-reconnect:** `PairedBridgeDevice` stores the `pairingCode` used during initial pairing. On every iOS WebSocket connect, `reRegisterPairedBridgeCodes()` re-sends `bridge.pair.request` for each stored code, so the Mac bridge can re-register after a server restart without regenerating a pairing code. Controlled by `bridgeAutoReconnect` UserDefaults setting (default true), toggled in Settings > Bridge.

**Mac toolbar status:** `connectionStateLabel` and `connectionDotColor` gate on both `connectionState` and `paired` — shows orange "Not Paired" when WebSocket is connected but pairing failed. Pairing error logs are debounced to once per 30 seconds via `lastPairingErrorLogged`.

### Bridge Exec Cards (Streaming Output)
When the LLM calls `bridge.exec.run`, `bridge.exec.start`, or `bridge.claude.run`, iOS shows a `BridgeExecCard` in the transcript with streaming terminal output. `ConversationBridgeExecManager` listens for `toolCall` → `toolResult` → `bridgeExecOutput` → `bridgeExecFinished` events and maintains card state. Cards display command text, a status pill (Running/Done/Failed), monospace output area (capped at ~100KB), and exit code + duration footer. Follows the same anchored-card pattern as agent/email/calendar/canvas cards.

**Files:**
- `ios/.../Models/BridgeExecCard.swift` — Card model with status enum, output accumulation
- `ios/.../ViewModels/ConversationBridgeExecManager.swift` — Event→card state machine
- `ios/.../Views/BridgeExecCardView.swift` — SwiftUI card with collapsed/expanded states

### Nova Act Browser Automation
Three bridge tools (`bridge.nova.start`, `bridge.nova.act`, `bridge.nova.stop`) manage a persistent Amazon Nova Act Python process on the macOS bridge. The Python process communicates via stdin/stdout JSON-RPC (one JSON object per line), keeping a Chrome browser session alive across multiple `act()` calls.

**Flow:** LLM calls `bridge.nova.start` with a URL → bridge spawns Python process → NovaAct opens Chrome. LLM calls `bridge.nova.act` with a natural-language instruction → bridge writes JSON to Python stdin → NovaAct executes → JSON result on stdout. LLM calls `bridge.nova.stop` → Python exits, Chrome closes.

**Permission:** Gated by `BridgePermissions.allowNovaAct` (default false). Toggle in AbyssBridge GUI. `BridgeCapabilities.novaAct` field controls server-side tool availability. `effectiveCapabilities()` in BridgeCore.swift gates the `novaAct` capability by this permission.

**Setup Sheet:** When the user toggles Nova Act ON, a `NovaActSetupSheet` appears in AbyssBridgeApp.swift that checks four prerequisites (Python 3, nova-act package, API key, Chrome) and shows pass/fail with copy-able fix commands. Cancel reverts the toggle; "Enable Anyway" force-enables.

**Files:**
- `mac/BridgeCore/Sources/BridgeCore/Resources/nova_act_bridge.py` — Python wrapper script
- `mac/BridgeCore/Sources/BridgeCore/NovaActSessionManager.swift` — Swift actor managing Python process lifecycle
- `server/src/core/conductorService.ts` — Tool definitions + dispatch (timeouts: start 60s, act 120s, stop 15s)

**Prerequisites on Mac:** `python3 -m pip install nova-act`, `NOVA_ACT_API_KEY` env var set, Chrome installed.

### Workspace Overrides in session.start
When the iOS app connects or reconnects, `connectConductorClient` gathers any workspace overrides from `eventCoordinator.pairedBridgeDevices` and includes them as `bridgeWorkspaceOverrides` in the `session.start` payload. The server iterates these and forwards each as `bridge.workspace.set` to the paired bridge device, ensuring workspace state survives iOS app restarts.

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
- `ios/.../Models/Event.swift` — `Event` struct with 27 event kinds + `EventBus` (append-only log with Combine publisher)
- `ios/.../Views/ContentView.swift` — Root view with sidebar, chat content, sheet presentations
- `ios/.../Views/InAppBrowserView.swift` — WKWebView in-app browser + `InAppBrowserCoordinator`
- `ios/.../Views/SettingsView.swift` — Appearance, recording mode, Cursor API key, Connections (Gmail/Canvas/coming-soon integrations), bridge pairing

#### iOS Feature Systems

**Multi-Chat Management:** `ChatListViewModel` manages multiple `ChatSession`s with sidebar navigation. Each session has its own `ConversationViewModel`. Persisted via UserDefaults.

**GitHub OAuth:** `GitHubAuthManager` implements full OAuth 2.0 via `ASWebAuthenticationSession`. Token stored in Keychain. Scopes: `repo`, `read:org`, `read:user`. Client ID from `GITHUB_CLIENT_ID` in Secrets.plist. Login UI in `GitHubLoginView`.

**Cursor Cloud Agents:** 6 tools in `Tools/Agent/` — `AgentSpawnTool`, `AgentStatusTool`, `AgentCancelTool`, `AgentFollowUpTool`, `RepositoriesListTool`, `AgentListTool`. API client: `CursorCloudAgentsClient`. UI: `AgentProgressCardView` with progress bars, conversation log, PR/agent-run links.

**Repository Selection:** `RepositorySelectionManager` presents an interactive modal for user to pick a repo during tool execution. Uses `CheckedContinuation` to suspend tool execution until selection. UI: `RepositorySelectionCardView`.

**Google Calendar Integration:** Reuses the same Google OAuth tokens as Gmail (calendar scope added to `GmailAuthManager`). Server-side `CalendarClient` (`server/src/integrations/calendarClient.ts`) provides 5 tools: `calendar.list`, `calendar.get`, `calendar.create`, `calendar.update`, `calendar.delete`. Mutations use the same confirmation card pattern as email — `CalendarDraftManager` with `CheckedContinuation` suspension, `CalendarDraftCardView` with Confirm/Cancel buttons. Read results render as `CalendarEventCardView` cards in the transcript via `ConversationCalendarManager`.

**Canvas LMS Integration:** `CanvasManager` stores a personal access token + base URL in Keychain (no OAuth needed). Settings UI has a "Connections" section with a modal to enter token. `CanvasAuthenticateTool` directs users to Settings when the LLM needs Canvas access. Server-side `CanvasClient` provides 6 tools: `canvas.courses`, `canvas.assignments`, `canvas.todo`, `canvas.upcoming`, `canvas.grades`, `canvas.announcements`. Token is threaded through `SessionStart` → `WebSocketConductorClient` → `ConductorService`. Canvas tool results render as `CanvasCardView` cards in the transcript via `ConversationCanvasManager` (same pattern as Calendar). Cards use a unified `CanvasCard` model with variant enum (`.course`, `.assignment`, `.todo`, `.grade`, `.announcement`). At session start, the server pre-fetches courses via `canvasClient.courses()` and stores a summary in `session.canvasCourseContext`, which is injected into the system prompt for ambient awareness.

**Gmail Integration:** Server-side `GmailClient` provides 5 tools: `gmail.inbox`, `gmail.search`, `gmail.read` (read-only, execute on server), `gmail.send`, `gmail.reply` (mutations use non-blocking confirmation via `EmailDraftManager`). The `gmail.send`/`gmail.reply` handlers store pending send details in `session.pendingGmailSends`, emit a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS, and return immediately (non-blocking). iOS shows an editable draft card (To/Subject/Body are `TextField`/`TextEditor` when pending). The user can edit fields and send follow-up messages to the AI while reviewing. On confirm, iOS sends `gmail.send.execute` with the (potentially edited) values; on cancel, `confirmed: false`. The server handles `gmail.send.execute` in `handleEvent`, sends the email via `GmailClient`, and emits `gmail.send.result` back to iOS. `ConversationEventCoordinator` listens for `gmail.send.result` and updates draft card state (`.sent`/`.failed`). OAuth tokens from `GmailAuthManager` are threaded through `SessionStart`. If tokens aren't available, LLM calls `gmail.authenticate` to prompt iOS sign-in. **Settings auth reconnect:** `ConversationViewModel.setGmailAuthManager()` subscribes to `gmailAuthManager.$isAuthenticated` — when the user authenticates Gmail in Settings (outside the tool flow), the WebSocket automatically reconnects with fresh tokens.

**Audio Pipeline:** `ConversationAudioPipeline` manages two recording modes: VAD auto-detection (`vadAuto`) and push-to-talk (`pushToTalk`). STT via `WhisperKitSpeechTranscriber` (on-device) or streamed to backend (`novaSonic`). TTS via `ElevenLabsTTS` with system voice fallback.

**Tool System:** `ToolProtocol` with `AnyTool` type erasure → `ToolRegistry` for registration → `ToolRouter` for event dispatch. Categories: Audio (`STTStart/Stop`, `TTSSpeak/Stop`), Conversation (`ConvoAppendMessage`, `ConvoSetState`), Agent (6 tools above), Gmail (`GmailAuthenticateTool`, `GmailSendConfirmTool`, `GmailReplyConfirmTool`), Calendar (`CalendarCreateConfirmTool`, `CalendarUpdateConfirmTool`, `CalendarDeleteConfirmTool`), Canvas (`CanvasAuthenticateTool`), Preferences (`PreferencesSetTool`, `PreferencesGetTool`).

**Conductor Clients:** `WebSocketConductorClient` (primary) — URLSession-based with auto-reconnect, exponential backoff, ping/pong keep-alive, AsyncStream inbound events. `LocalConductorClient` / `LocalConductorStub` for offline/testing.

#### iOS Patterns
- Shared state uses `@StateObject` in `AbyssApp` + `@EnvironmentObject` in child views
- Theming via `AppTheme` static methods that take `colorScheme` parameter
- `@AppStorage` for persisted preferences: `appAppearance`, `recordingMode`, `voiceMode`, `cursorAPIKey`, `cursorAgentModel`, `elevenLabsVoiceId`. **Gotcha:** `@AppStorage` on `ObservableObject` does NOT fire `objectWillChange` — SwiftUI views won't re-render. Use `@Published` with manual `UserDefaults` sync in `didSet` instead (see `isTTSMuted` in `ConversationViewModel`).
- Manager/Coordinator pattern: `ConversationAgentManager`, `ConversationEventCoordinator`, `ConversationEmailManager`, `ConversationCalendarManager`, `ConversationCanvasManager`, `ConversationBridgeExecManager`, `RepositorySelectionManager`, `EmailDraftManager`, `CalendarDraftManager`, `InAppBrowserCoordinator`
- `@MainActor` isolation for all UI/state management; `@unchecked Sendable` for backward compat

#### Xcode Project Gotcha
When adding new `.swift` files to the iOS project, they MUST be manually added to `ios/Abyss/Abyss.xcodeproj/project.pbxproj` in 4 places:
1. **PBXBuildFile section** — `A1...` ID with `in Sources` reference
2. **PBXFileReference section** — `A2...` ID with file path
3. **PBXGroup section** — add the `A2...` ref to the appropriate group (Services, Tools, Views, etc.)
4. **PBXSourcesBuildPhase section** — add the `A1...` build file ref

IDs follow the pattern `A1000000000000010000XXXX` (build) / `A2000000000000010000XXXX` (file ref), incrementing the last hex digits. Without this, Xcode won't compile the file and you'll get "Cannot find type in scope" errors.

#### Transcript Item Ordering
`TranscriptView` renders items via a `TranscriptItem` enum in a `LazyVStack`. For each assistant message: `.message` (bubble text) → anchored cards (agent, email, calendar, canvas) → `.messageActions` (copy/thumbs buttons). The `MessageActionsView` is a separate struct from `MessageBubble`, ensuring cards appear between message text and action buttons.

#### Markdown Rendering
Assistant messages rendered via `MarkdownTextView` → parses into `.text` (inline formatting) and `.codeBlock(language, code)` (terminal-style with copy button). User messages use plain `Text`.

## Agent Workflow Guidelines

### Committing Changes
- **Always commit when done** — at the end of any task, commit all changes with a descriptive message.
- **Commit incrementally — never make massive commits.** Break work into logical, focused commits as you go (e.g., one commit per component, per subsystem, or per meaningful milestone). Do not accumulate all changes and commit everything at once at the end of a large task. Each commit should be understandable in isolation.
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
| `VOICE_PROVIDER` | `nova-sonic` | `local` or `nova-sonic` |
| `BEDROCK_TEXT_MODEL_ID` | `us.amazon.nova-2-lite-v1:0` | Primary LLM |
| `ANTHROPIC_API_KEY` | — | Required if using `anthropic` provider |
| `AWS_REGION` | `us-east-1` | Required for Bedrock |
| `CURSOR_API_KEY` | — | Optional; enables server-side Cursor agent tools |
| `GOOGLE_CLIENT_ID` | — | Required for Gmail + Calendar OAuth |
| `GOOGLE_CLIENT_SECRET` | — | Required for Gmail + Calendar OAuth |

AWS credentials are resolved via Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK`) or standard SDK chain (profile, env vars, or instance role).

## AWS Infrastructure

| Resource | Value |
|---|---|
| Account ID | `192440504332` |
| Region | `us-east-1` |
| ECS Cluster | `abyss` |
| ECS Service | `abyss-server` |
| ECR Repo | `192440504332.dkr.ecr.us-east-1.amazonaws.com/abyss-server` |
| ALB DNS | `abyss-alb-1705721363.us-east-1.elb.amazonaws.com` |
| Target Group ARN | `arn:aws:elasticloadbalancing:us-east-1:192440504332:targetgroup/abyss-tg/f75b69fc8c1c8f84` |
| Security Group | `sg-04ce02d7ffde1a343` |
| VPC | `vpc-0e852251aec649cd6` (default VPC) |
| Execution Role | `abyss-ecs-execution-role` |
| Task Role | `abyss-ecs-task-role` (Bedrock permissions) |
| Log Group | `/ecs/abyss-server` |

### Deploy commands
```bash
# Build and push
cd server
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 192440504332.dkr.ecr.us-east-1.amazonaws.com
docker buildx build --platform linux/amd64 -t 192440504332.dkr.ecr.us-east-1.amazonaws.com/abyss-server:latest --push .

# Update service
aws ecs update-service --cluster abyss --service abyss-server --force-new-deployment --region us-east-1
```

### iOS Configuration
iOS reads from `Secrets.plist` (gitignored) → `Info.plist` → environment variables. Key values:
- `GITHUB_CLIENT_ID` — Required for GitHub OAuth login
- `ELEVEN_LABS_API_KEY` — Required for ElevenLabs TTS (falls back to system voice)
- `CURSOR_API_KEY` — Required for Cursor Cloud Agents (also configurable in Settings UI)
- `BACKEND_WS_URL` — WebSocket server URL (defaults to `ws://localhost:8080/ws`)
- `CANVAS_BASE_URL` — Optional default Canvas LMS URL (defaults to `https://canvas.cmu.edu`; also configurable in Settings UI)

### Production (AWS ECS)
Server runs on ECS Fargate in **us-east-1** (cluster `abyss`, service `abyss-server`). ALB: `abyss-alb-1705721363.us-east-1.elb.amazonaws.com`. Full deployment details (ECR, security groups, target group) are in **docs/runbook.md** under "AWS ECS Deployment".

**WebSocket stickiness:** The ALB keeps existing WebSocket connections pinned to the old task even after a new deployment. The iOS app must be killed and reopened after a deploy to reconnect to the new container.

## Claude Code Instructions

- Never add Claude as a co-author on git commits. Do not include `Co-Authored-By: Claude` or any similar trailer in commit messages.
