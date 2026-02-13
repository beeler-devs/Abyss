# VoiceIDE — Phase 1

A voice-first agentic development app built around **formal tool calling**. Every action that touches state, audio, or UI flows through structured `tool.call` / `tool.result` events.

## Architecture

```
User Voice → WhisperKit STT → Conductor (tool calls) → ToolRouter → Services
                                                                   ↓
                                                            ElevenLabs TTS → Speaker
```

All state changes are visible in the real-time Event Timeline.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Requirements

- **Xcode 15.2+**
- **iOS 17.0+** device or simulator
- **Swift 5.9+**
- **ElevenLabs API key** (for TTS — free tier works)

## Setup

### 1. Clone and open

```bash
git clone <repo-url>
cd VoiceBot2/ios/VoiceIDE
open Package.swift  # Opens in Xcode
```

Or open the `ios/VoiceIDE` directory in Xcode directly.

### 2. Configure API Key

Create a `Secrets.plist` file (git-ignored) for your ElevenLabs API key:

```bash
cat > ios/VoiceIDE/VoiceIDE/App/Secrets.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ELEVENLABS_API_KEY</key>
    <string>YOUR_API_KEY_HERE</string>
    <key>ELEVENLABS_VOICE_ID</key>
    <string>21m00Tcm4TlvDq8ikWAM</string>
    <key>ELEVENLABS_MODEL_ID</key>
    <string>eleven_turbo_v2_5</string>
</dict>
</plist>
EOF
```

Replace `YOUR_API_KEY_HERE` with your actual key from [elevenlabs.io](https://elevenlabs.io).

**The app will work without the key** — STT and the tool pipeline function normally, but TTS will emit an error event.

### 3. Add Secrets.plist to the Xcode target

In Xcode:
1. Right-click the `App` group → "Add Files to VoiceIDE"
2. Select `Secrets.plist`
3. Ensure "Copy items if needed" is checked
4. Ensure it's added to the VoiceIDE target

### 4. Build and Run

Select an iOS 17+ device or simulator and hit Run (⌘R).

**Note**: WhisperKit requires a real device for microphone input. The simulator will have limited STT functionality.

## Project Structure

```
/
├── README.md                          # This file
├── .gitignore
├── docs/
│   ├── architecture.md                # Architecture + Phase 2 plan
│   ├── protocol.md                    # Event protocol for WebSocket
│   └── tools.md                       # Tool catalog with schemas
├── ios/VoiceIDE/
│   ├── Package.swift                  # SPM manifest (WhisperKit dependency)
│   ├── VoiceIDE/
│   │   ├── App/
│   │   │   ├── VoiceIDEApp.swift      # @main entry point
│   │   │   ├── Config.swift           # Secret/config loader
│   │   │   └── Secrets.plist          # (git-ignored) API keys
│   │   ├── Models/
│   │   │   ├── Event.swift            # Strongly-typed Event model
│   │   │   ├── EventBus.swift         # Append-only event stream
│   │   │   ├── AppState.swift         # State enum + RecordingMode
│   │   │   └── ConversationMessage.swift
│   │   ├── Tools/
│   │   │   ├── ToolProtocol.swift     # Tool protocol + AnyTool
│   │   │   ├── ToolRegistry.swift     # Name → handler mapping
│   │   │   ├── ToolRouter.swift       # Dispatch + result emission
│   │   │   ├── Audio/
│   │   │   │   ├── STTStartTool.swift
│   │   │   │   ├── STTStopTool.swift
│   │   │   │   ├── TTSSpeakTool.swift
│   │   │   │   └── TTSStopTool.swift
│   │   │   └── Conversation/
│   │   │       ├── ConvoAppendMessageTool.swift
│   │   │       └── ConvoSetStateTool.swift
│   │   ├── Services/
│   │   │   ├── SpeechTranscriber.swift         # Protocol
│   │   │   ├── WhisperKitSpeechTranscriber.swift
│   │   │   ├── TextToSpeech.swift              # Protocol
│   │   │   └── ElevenLabsTTS.swift
│   │   ├── Conductor/
│   │   │   ├── ConductorProtocol.swift
│   │   │   └── LocalConductorStub.swift
│   │   ├── ViewModels/
│   │   │   └── ConversationViewModel.swift
│   │   └── Views/
│   │       ├── ContentView.swift
│   │       ├── MicButton.swift
│   │       ├── TranscriptView.swift
│   │       ├── EventTimelineView.swift
│   │       ├── StateIndicator.swift
│   │       └── SettingsView.swift
│   └── VoiceIDETests/
│       ├── Helpers.swift              # Mock implementations
│       ├── EventBusTests.swift
│       ├── ToolRouterTests.swift
│       ├── LocalConductorStubTests.swift
│       └── BargeInTests.swift
└── scripts/                           # (reserved for build scripts)
```

## Features (Phase 1)

- **On-device STT** via WhisperKit with streaming partials
- **Streaming TTS** via ElevenLabs (low-latency, starts playing before full download)
- **Formal tool calling** — all actions flow through `tool.call` → `tool.result`
- **Barge-in** — tap mic while speaking to interrupt and start listening
- **Recording modes** — tap-to-toggle (default) or press-and-hold
- **Event timeline** — collapsible debug view showing every event in real-time
- **Deterministic conductor** — `LocalConductorStub` proves the pipeline without a backend

## Testing

```bash
cd ios/VoiceIDE
swift test
```

Or in Xcode: ⌘U

Tests cover:
- EventBus ordering and replay
- ToolRouter dispatch and error handling
- LocalConductorStub deterministic output
- Barge-in: tts.stop called before stt.start

## Troubleshooting

### "ElevenLabs API key is not configured"
Create `Secrets.plist` as described above and add it to the Xcode target.

### WhisperKit model download fails
WhisperKit downloads the model on first run. Ensure you have internet connectivity. The `base.en` model is ~140MB.

### Microphone not working in simulator
Use a real device. The iOS simulator has limited microphone support.

### Build errors with WhisperKit
Ensure you're using Xcode 15.2+ and targeting iOS 17+. Run `swift package resolve` if needed.

## Phase 2 Roadmap

- WebSocket conductor replacing LocalConductorStub
- Bedrock Nova 2 Lite for reasoning
- Nova embeddings for semantic code search
- File editing, git operations, browser automation tools
- Nova Act sub-agent integration
- Artifact cards (diff views, log views) in the UI

See [docs/architecture.md](docs/architecture.md) for the full Phase 2 plan.
