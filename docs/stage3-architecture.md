# Stage 3 Architecture

## Overview

Stage 3 keeps formal tool calling as the control plane:

- Conductor (LLM) decides actions by calling tools.
- iOS executes only client tools (`stt.*`, `tts.*`, `convo.*`, optional `agent.*`).
- Backend executes only server tools (`github.*`, `ci.*`, `embeddings.*`, `context.*`, `patch.*`, `webqa.*`, `policy.*`, `runner.*`).

## End-to-end sequence

```mermaid
sequenceDiagram
    participant User
    participant iOS as "iOS App"
    participant WS as "Conductor WS"
    participant LLM as "Claude Conductor"
    participant Tools as "Server Tool Router"
    participant GH as "GitHub API"
    participant CI as "GitHub Actions"
    participant WebQA as "WebQA Provider"

    User->>iOS: "Run tests"
    iOS->>WS: user.audio.transcript.final
    WS->>LLM: history + tool catalog
    LLM->>Tools: stage3.runTests
    Tools->>GH: branch + PR ensure
    Tools->>CI: checks.list
    Tools-->>WS: CI summary artifact
    WS-->>iOS: assistant.ui.patch + speech

    User->>iOS: "Fix it"
    iOS->>WS: user.audio.transcript.final
    WS->>LLM: updated context
    LLM->>Tools: stage3.fixFailingTest
    loop iteration budget
      Tools->>CI: failing check logs
      Tools->>Tools: diagnose.ciFailure
      Tools->>Tools: context.buildBundle + embeddings
      Tools->>LLM: patch.generateDiff
      Tools->>Tools: patch.validate
      Tools->>GH: github.applyPatchToBranch
      Tools->>CI: wait checks terminal
    end
    Tools->>Tools: preview.findUrl + webqa.run
    Tools-->>WS: artifacts (PR/CI/diff/webqa)
    WS-->>iOS: assistant.ui.patch + speech

    User->>iOS: "Merge it"
    iOS->>WS: user.audio.transcript.final
    WS->>LLM: history + artifacts
    LLM->>Tools: policy.checkMerge
    alt policy passes + user confirmed
      LLM->>Tools: github.pr.merge
      Tools->>GH: merge PR
      Tools-->>WS: merge result artifact
    end
```

## Module boundaries

- `server/src/core/*`: transport, sessions, conductor loop, protocol events.
- `server/src/stage3/tools/*`: typed server/client tool registry + execution routing.
- `server/src/stage3/github/*`: GitHub PR-first integration.
- `server/src/stage3/ci/*`: CI checks/logs + failure diagnosis.
- `server/src/stage3/embeddings/*`: repo indexing + semantic query.
- `server/src/stage3/context/*`: hybrid context bundle builder.
- `server/src/stage3/patch/*`: unified diff generation/validation/apply.
- `server/src/stage3/preview/*`: preview URL discovery.
- `server/src/stage3/webqa/*`: provider-swappable web validation.
- `server/src/stage3/policy/*`: merge gating.
- `server/src/stage3/runner/*`: hosted runner interface (stub now).

## Provider swap points

- Conductor model provider: `server/src/providers/*` (Anthropic now, Bedrock scaffold retained).
- Patch generation provider: `PatchGenerationProvider`.
- Embeddings provider: `EmbeddingsProvider`.
- WebQA provider: `WebQAProvider`.
- Runner provider: `RunnerProvider`.
