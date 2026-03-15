# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Abyss is a voice-first AI conductor architecture. An iOS client streams speech to a Node.js WebSocket server, which orchestrates LLM tool calls, and optionally routes privileged operations (filesystem, shell commands) to a paired macOS bridge.

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

## Architecture

### Event System
All communication uses `EventEnvelope` — a strict JSON schema with `id`, `type`, `sessionId`, `protocolVersion`, `timestamp`, and `payload`. Protocol version is `1`. Events are append-only and deterministic IDs are derived via SHA256.

### Server Flow
1. iOS sends a `user.speech.final` event over WebSocket to `/ws`
2. `ConductorService` processes it: maintains session history, calls the LLM, streams responses
3. LLM responds with tool calls → conductor emits `tool.call` events
4. Tools execute locally (iOS handles `audio.*`, `ui.*`) or are routed to the bridge (`bridge.exec.run`, `bridge.fs.*`)
5. Tool results are sent back as `tool.result` events → conductor resumes LLM

### Key Server Files
- `server/src/server.ts` — HTTP/WS server setup; maintains `iosSocketsBySession` and `bridgeSocketsByDeviceId` maps
- `server/src/core/conductorService.ts` — Orchestrates conversation turns, tool dispatch, rate limiting, Cursor integration
- `server/src/core/types.ts` — All shared TypeScript types (`EventEnvelope`, `SessionState`, `ModelProvider`, etc.)
- `server/src/core/events.ts` — Event parsing, validation, and creation utilities
- `server/src/bridge/state.ts` — Device pairing and online/offline tracking
- `server/src/bridge/toolRouter.ts` — Routes bridge tools to connected macOS devices
- `server/src/providers/` — Pluggable LLM backends; factory in `index.ts`

### Model Providers
Selected via `MODEL_PROVIDER` env var:
- `bedrock` (default) — Amazon Nova via AWS Bedrock (`bedrockNovaProvider.ts`)
- `anthropic` — Claude via Anthropic API (`anthropicProvider.ts`)

### Bridge Pairing
macOS bridge connects to `/ws` with a `bridge.pair` event. Server tracks `deviceId → WebSocket`. When a bridge tool call arrives, `toolRouter` finds the paired device and forwards it; the bridge executes and returns a `tool.result`.

### iOS UI Architecture

#### Key iOS Files
- `ios/.../App/AbyssApp.swift` — App entry point; injects `@EnvironmentObject`s (`GitHubAuthManager`, `InAppBrowserCoordinator`)
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
- `ios/.../Views/SettingsView.swift` — Appearance, voice backend, recording mode, Cursor API key, bridge pairing

#### iOS Feature Systems

**Multi-Chat Management:** `ChatListViewModel` manages multiple `ChatSession`s with sidebar navigation. Each session has its own `ConversationViewModel`. Persisted via UserDefaults.

**GitHub OAuth:** `GitHubAuthManager` implements full OAuth 2.0 via `ASWebAuthenticationSession`. Token stored in Keychain. Scopes: `repo`, `read:org`, `read:user`. Client ID from `GITHUB_CLIENT_ID` in Secrets.plist. Login UI in `GitHubLoginView`.

**Cursor Cloud Agents:** 6 tools in `Tools/Agent/` — `AgentSpawnTool`, `AgentStatusTool`, `AgentCancelTool`, `AgentFollowUpTool`, `RepositoriesListTool`, `AgentListTool`. API client: `CursorCloudAgentsClient`. UI: `AgentProgressCardView` with progress bars, conversation log, PR/agent-run links.

**Repository Selection:** `RepositorySelectionManager` presents an interactive modal for user to pick a repo during tool execution. Uses `CheckedContinuation` to suspend tool execution until selection. UI: `RepositorySelectionCardView`.

**Audio Pipeline:** `ConversationAudioPipeline` manages two recording modes: VAD auto-detection (`vadAuto`) and push-to-talk (`pushToTalk`). STT via `WhisperKitSpeechTranscriber` (on-device) or streamed to backend (`novaSonic`). TTS via `ElevenLabsTTS` with system voice fallback.

**Tool System:** `ToolProtocol` with `AnyTool` type erasure → `ToolRegistry` for registration → `ToolRouter` for event dispatch. Categories: Audio (`STTStart/Stop`, `TTSSpeak/Stop`), Conversation (`ConvoAppendMessage`, `ConvoSetState`), Agent (6 tools above).

**Conductor Clients:** `WebSocketConductorClient` (primary) — URLSession-based with auto-reconnect, exponential backoff, ping/pong keep-alive, AsyncStream inbound events. `LocalConductorClient` / `LocalConductorStub` for offline/testing.

#### iOS Patterns
- Shared state uses `@StateObject` in `AbyssApp` + `@EnvironmentObject` in child views
- Theming via `AppTheme` static methods that take `colorScheme` parameter
- `@AppStorage` for persisted preferences: `appAppearance`, `recordingMode`, `voiceMode`, `cursorAPIKey`, `cursorAgentModel`, `elevenLabsVoiceId`
- Manager/Coordinator pattern: `ConversationAgentManager`, `ConversationEventCoordinator`, `RepositorySelectionManager`, `InAppBrowserCoordinator`
- `@MainActor` isolation for all UI/state management; `@unchecked Sendable` for backward compat

#### Markdown Rendering
Assistant messages rendered via `MarkdownTextView` → parses into `.text` (inline formatting) and `.codeBlock(language, code)` (terminal-style with copy button). User messages use plain `Text`.

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

AWS credentials are resolved via standard SDK chain (profile, env vars, or instance role).

### iOS Configuration
iOS reads from `Secrets.plist` (gitignored) → `Info.plist` → environment variables. Key values:
- `GITHUB_CLIENT_ID` — Required for GitHub OAuth login
- `ELEVEN_LABS_API_KEY` — Required for ElevenLabs TTS (falls back to system voice)
- `CURSOR_API_KEY` — Required for Cursor Cloud Agents (also configurable in Settings UI)
- `BACKEND_WS_URL` — WebSocket server URL (defaults to `ws://localhost:8080/ws`)
