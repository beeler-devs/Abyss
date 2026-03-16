# Abyss

**A voice-first AI assistant that lives on your iPhone, with secure local execution and coding as a flagship workflow.**

Abyss makes the phone the primary interface, not a companion app. You speak to a SwiftUI iPhone client, a TypeScript conductor server orchestrates tools over WebSockets, and a paired macOS bridge unlocks privileged local actions only when the user has explicitly allowed them.

## Tech Stack / Architecture Diagram

_Reserved for a system diagram: iPhone app -> WebSocket conductor -> integrations + paired Mac bridge._

## Built Today

- Working iPhone client with live conversation, voice input, push-to-talk, and transcript rendering.
- Live Node.js + TypeScript WebSocket conductor with tool calling, streaming responses, and inline result cards.
- Paired macOS bridge for permissioned local shell, file, git, and advanced coding workflows.
- Real integrations already wired in: Gmail, Google Calendar, Canvas, Cursor Cloud Agents, Brave web search, and optional advanced memory/context infrastructure.

## Features

- Voice-first, iPhone-native assistant experience.
- Coding workflows through a paired Mac bridge, terminal execution, and Cursor Cloud Agents.
- Secure permissioning for privileged local actions instead of default full-machine access.
- Inline transcript cards for email, calendar, Canvas, agent runs, bridge output, and confirmations.
- Multi-chat support with voice, push-to-talk, and typed interaction patterns.
- Gmail, Calendar, Canvas, web search, and GitHub-connected development workflows.
- Optional long-term memory, summarization, and context-graph retrieval.
- Optional browser automation on the paired Mac through Nova Act.

## Why Abyss

Most assistants are still chat-first and desktop-first. Abyss is built around a different assumption: the fastest, most natural assistant should start on the iPhone, default to voice, and still be able to reach deeper tools when the user wants real work done.

That is where coding becomes a flagship workflow. Abyss can stay lightweight for everyday assistant tasks like email, calendar, and search, but it can also escalate into serious development work through Cursor agents and a permissioned Mac bridge. The result is broader than an IDE copilot and safer than giving an agent unrestricted local access.

## How It Works

1. The iPhone app captures speech or text and sends structured events over WebSocket.
2. The Node.js/TypeScript conductor keeps session state, calls the model provider, and dispatches tools.
3. Server-side integrations handle tasks like Gmail, Calendar, Canvas, web search, and agent orchestration.
4. Privileged local actions route through a separately paired macOS bridge, which enforces workspace and permission boundaries before executing commands or file operations.
5. Results flow back into the transcript as inline cards and assistant messages, so the conversation remains readable on the phone.

At a high level, the system is:

`iPhone app -> WebSocket conductor -> server tools and integrations -> paired Mac for privileged local execution`

## Security and Permissioning

Security is part of the product design, not an afterthought.

- Privileged local actions are separated behind a paired macOS bridge instead of being granted directly to the phone client or server.
- The bridge is constrained to user-selected workspace roots and rejects paths outside those allowed roots.
- Local capabilities are permissioned individually, including shell execution, write/apply-patch flows, git push, Claude/code execution, and Nova Act browser automation.
- The macOS app exposes permission presets as well as granular toggles, so users can tighten or expand access deliberately.
- Sensitive credentials are stored with platform-native security primitives such as Keychain-backed storage on Apple clients.
- Authentication is integration-specific rather than hand-waved: Google services use OAuth flows, GitHub login is separate, Canvas uses its own token model, and AWS-backed server features depend on local or deployed credentials.
- Risky operations are explicitly mediated rather than assumed, which is the core trust boundary of the architecture.

Concrete examples:
- Email send and reply flows go through confirmation cards before they are finalized.
- Bridge file access is limited to selected workspace roots, `git push` can be separately gated, and Nova Act browser automation is opt-in behind its own permission and API-key setup.

## Repository Layout

```text
ios/       SwiftUI iPhone client and app-side tools, auth, and transcript UI
server/    Node.js + TypeScript WebSocket conductor, integrations, providers, and tests
mac/       macOS bridge app, CLI, and BridgeCore package for privileged local execution
shared/    Shared JSON schemas plus TypeScript and Swift protocol libraries
docs/      Design notes, architecture docs, runbooks, and implementation plans
scripts/   Local development helpers such as `scripts/dev/start-local.sh`
infra/     AWS deployment artifacts and infrastructure notes
```

## Tech Stack

### iPhone App

- SwiftUI for the main product experience.
- AVFoundation-based audio handling.
- WhisperKit for on-device speech transcription paths.
- ElevenLabs with fallback voice behavior for text-to-speech.
- URLSession WebSockets for the conductor connection.
- Apple auth and security frameworks for sign-in and credential storage.

### Conductor Server

- Node.js 20+
- TypeScript
- `ws` WebSocket server
- AWS Bedrock model providers, with Nova Lite / Nova Pro routing for heavier tool-use requests
- Nova Sonic voice support
- Server-side integrations for Gmail, Google Calendar, Canvas, web search, and Cursor Cloud Agents

### AWS and Deployment

- AWS Bedrock Runtime for model access
- ECS Fargate deployment artifacts and notes in `infra/` and `docs/`
- Amazon ECR image publishing
- Application Load Balancer-based deployment configuration

### Optional Advanced Memory / Context Infrastructure

These capabilities are configuration-dependent, not required for the base app to run.

- S3-backed memory and Bedrock Knowledge Bases support
- Amazon Titan embeddings for semantic retrieval
- Neptune Analytics-backed context graph retrieval
- Bedrock Agent and Agent Runtime clients included in the server dependencies for advanced workflows

### macOS Bridge

- Swift
- SwiftUI/AppKit bridge app UI
- Swift Package Manager
- Python runtime support for Nova Act browser automation

### Shared Contracts

- JSON Schema event and tool definitions
- Shared TypeScript protocol library
- Shared Swift protocol library

### External Integrations

- Gmail
- Google Calendar
- Canvas
- GitHub-authenticated developer flows
- Cursor Cloud Agents
- Brave Search

## Quick Start

1. Install server dependencies:

```bash
cd server
npm install
```

2. Copy the server environment template and fill in the credentials you need for your demo path:

```bash
cp server/.env.example server/.env
```

At minimum, local voice + model flows typically require AWS Bedrock credentials. Other integrations such as Google services, Cursor, Brave Search, or advanced memory/context features are optional and only need to be configured if you plan to demo them.

3. Start the local conductor:

```bash
./scripts/dev/start-local.sh
```

4. Launch the paired Mac bridge:

```bash
cd mac/AbyssBridge && swift run
```

Or use the CLI bridge:

```bash
swift run --package-path mac/BridgeCLI abyss-bridge --server ws://localhost:8080/ws --workspace "$(git rev-parse --show-toplevel)" --name "My Mac"
```

5. Build the iPhone app:

```bash
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build
```

If `xcodebuild` says full Xcode is required, point `xcode-select` at Xcode.app instead of CommandLineTools:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

6. Run the app, then pair the Mac from the app's Settings screen.
7. Start with a voice command, then escalate into a coding workflow, email task, calendar action, or web search.

## Current State

Abyss already includes the core surfaces needed for an end-to-end demo: the iPhone client, the WebSocket conductor server, the paired macOS bridge, shared cross-platform protocol definitions, and supporting tests/docs across the stack.

The strongest judge demo path is simple: start on the phone with voice, trigger a real tool-backed assistant task, then step up into a permissioned coding workflow on the paired Mac.
