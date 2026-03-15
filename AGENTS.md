# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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
- `anthropic` — Codex via Anthropic API (`anthropicProvider.ts`)

### Bridge Pairing
macOS bridge connects to `/ws` with a `bridge.pair` event. Server tracks `deviceId → WebSocket`. When a bridge tool call arrives, `toolRouter` finds the paired device and forwards it; the bridge executes and returns a `tool.result`.

### iOS UI Architecture

#### Key iOS Files
- `ios/.../App/AbyssApp.swift` — App entry point; injects `@EnvironmentObject`s
- `ios/.../Views/ContentView.swift` — Root view with `NavigationStack`, sidebar panel (`ChatSidebarPanel`), and `ChatContentView`
- `ios/.../Views/TranscriptView.swift` — Scrolling conversation transcript; `MessageBubble` renders each message
- `ios/.../Views/MarkdownTextView.swift` — Markdown renderer used for all assistant messages
- `ios/.../Views/AgentProgressCardView.swift` — Cursor agent progress card UI
- `ios/.../Views/EventTimelineView.swift` — Debug event timeline
- `ios/.../Views/InAppBrowserView.swift` — WKWebView in-app browser + `InAppBrowserCoordinator`
- `ios/.../App/AppTheme.swift` — Centralized theme colors (all UI colors live here)
- `ios/.../ViewModels/ConversationViewModel.swift` — Primary VM; owns messages, appState, audio pipeline

#### iOS Patterns
- Shared state uses `@StateObject` in `AbyssApp` + `@EnvironmentObject` in child views
- Theming via `AppTheme` static methods that take `colorScheme` parameter
- `@AppStorage` for persisted user preferences

#### Markdown Rendering
Assistant messages are rendered via `MarkdownTextView` (not plain `Text`). It parses the raw string into `Block` values:
- `.text` — rendered with `AttributedString(markdown:)` for inline formatting (bold, italic, inline code)
- `.codeBlock(language, code)` — rendered by `CodeBlockView` with a dark terminal-style background, language label, horizontal scroll, and a copy button

`AppTheme` provides `codeBlockBackground`, `codeBlockText`, and `codeBlockLabelText` for code block styling. All colors are theme-aware (`colorScheme` parameter).

User messages are plain `Text`; only assistant messages use `MarkdownTextView`.

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
