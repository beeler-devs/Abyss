# Email Draft Confirmation Card Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user asks to write/send an email, the LLM should draft it immediately and present it in a native iOS card with a Send button, instead of asking text-based confirmation questions.

**Architecture:** The server's `gmail.send`/`gmail.reply` execution is changed to emit a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS before actually sending. iOS renders a draft card with Send/Cancel buttons using the `CheckedContinuation` suspension pattern (same as `RepositorySelectionManager`). The system prompts are updated to instruct the LLM to just call `gmail.send` directly without asking questions. CLAUDE.md is updated to reflect expanded personal assistant scope.

**Tech Stack:** TypeScript (Node.js server), SwiftUI (iOS client)

---

## Chunk 1: Server-Side Changes

### Task 1: Update System Prompts (Both Providers)

**Files:**
- Modify: `server/src/providers/bedrockNovaProvider.ts:115-135`
- Modify: `server/src/providers/anthropicProvider.ts:225-241`

- [ ] **Step 1: Update Bedrock Nova system prompt**

In `bedrockNovaProvider.ts`, replace the `buildSystemPrompt()` method content. Changes:
1. "voice-first coding assistant" → "voice-first AI assistant"
2. Remove "CRITICAL: Before calling gmail.send..." line
3. Replace with instruction to call gmail.send directly
4. Remove mention of gmail.authenticate in context of Cursor
5. Add personal assistant framing

New system prompt lines (replace lines 117-133):
```typescript
private buildSystemPrompt(): SystemContentBlock[] {
    return [{
      text: [
        "You are the Abyss voice-first AI assistant — a personal assistant that can help with coding, email, scheduling, and more.",
        "Keep spoken responses concise, practical, and voice-friendly.",
        "Do not ask for speech-to-text tools. The user triggers listening manually.",
        "Avoid markdown tables and avoid long formatting.",
        "If webqa.cursor.run is available and the user asks to validate behavior in a browser, call webqa.cursor.run.",
        "If cursor.agent.spawn is available and the user asks to spawn an agent, run coding tasks, PR work, or repo analysis, prefer cursor.agent.spawn.",
        "When using cursor.agent.spawn or webqa.cursor.run, avoid aggressive polling; rely on webhook-driven updates unless explicitly asked to refresh.",
        "If cursor.agent.spawn is unavailable or a cursor_server_not_configured error is returned, fall back to legacy agent.spawn.",
        "When using legacy agent.spawn for repo work, if you do not know the exact owner/repo string, call repositories.list first.",
        "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
        "Never guess or hallucinate a repository name. Only use repos returned by repositories.list.",
        "If gmail.inbox, gmail.search, gmail.read, gmail.send, or gmail.reply tools are available, use them when the user asks about email. These tools are available because the user has already connected their Gmail account.",
        "For gmail.search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
        "When the user asks to write, compose, draft, or send an email, draft the content yourself and call gmail.send immediately with the to, subject, and body fields. Do NOT ask the user for text confirmation — the app will show a draft card where they can review and tap Send. Just write the email and call the tool.",
        "Similarly for gmail.reply — draft the reply body and call gmail.reply immediately. The app handles confirmation via a card.",
        "If gmail tools are NOT available but gmail.authenticate IS available, call gmail.authenticate when the user asks about email — this opens the sign-in screen on their device.",
      ].join(" "),
    }];
  }
```

- [ ] **Step 2: Update Anthropic provider system prompt**

In `anthropicProvider.ts`, apply the same changes (with underscore-separated tool names: `gmail_send`, `gmail_reply`, `gmail_authenticate`, etc.).

New system prompt (replace the system array at lines 225-241):
```typescript
system: [
  "You are the Abyss voice-first AI assistant — a personal assistant that can help with coding, email, scheduling, and more.",
  "Keep spoken responses concise, practical, and voice-friendly.",
  "Do not ask for speech-to-text tools. The user triggers listening manually.",
  "Avoid markdown tables and avoid long formatting.",
  "If webqa_cursor_run is available and the user asks to validate behavior in a browser, call webqa_cursor_run.",
  "If cursor_agent_spawn is available and the user asks to spawn an agent, run coding tasks, PR work, or repo analysis, prefer cursor_agent_spawn.",
  "When using cursor_agent_spawn or webqa_cursor_run, avoid aggressive polling; rely on webhook-driven updates unless explicitly asked to refresh.",
  "If cursor_agent_spawn is unavailable or a cursor_server_not_configured error is returned, fall back to legacy agent_spawn.",
  "When using legacy agent_spawn for repo work, if you do not know the exact owner/repo string, call repositories_list first.",
  "By default set autoCreatePr: false and autoBranch: false unless the user explicitly asks to create a PR or branch.",
  "Never guess or hallucinate a repository name — only use repos returned by repositories_list.",
  "If gmail_inbox, gmail_search, gmail_read, gmail_send, or gmail_reply tools are available, use them when the user asks about email. These tools are available because the user has already connected their Gmail account.",
  "For gmail_search, translate natural language into Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01').",
  "When the user asks to write, compose, draft, or send an email, draft the content yourself and call gmail_send immediately with the to, subject, and body fields. Do NOT ask the user for text confirmation — the app will show a draft card where they can review and tap Send. Just write the email and call the tool.",
  "Similarly for gmail_reply — draft the reply body and call gmail_reply immediately. The app handles confirmation via a card.",
  "If gmail tools are NOT available but gmail_authenticate IS available, call gmail_authenticate when the user asks about email — this opens the sign-in screen on their device.",
].join(" "),
```

- [ ] **Step 3: Commit prompt changes**
```bash
git add server/src/providers/bedrockNovaProvider.ts server/src/providers/anthropicProvider.ts
git commit -m "feat: update system prompts — personal assistant identity, direct email drafting"
```

### Task 2: Update Gmail Tool Descriptions

**Files:**
- Modify: `server/src/core/conductorService.ts:482-510` (SERVER_GMAIL_TOOLS)

- [ ] **Step 1: Update gmail.send tool description**

Replace the `gmail.send` tool entry (lines 482-495):
```typescript
{
    name: "gmail.send",
    description:
      "Send a new email on behalf of the user. The app will show the draft in a confirmation card before actually sending. Just call this tool with the composed email content.",
    input_schema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Recipient email address." },
        cc: { type: "string", description: "CC email address (optional)." },
        subject: { type: "string", description: "Email subject line." },
        body: { type: "string", description: "Email body text." },
      },
      required: ["to", "subject", "body"],
    },
  },
```

- [ ] **Step 2: Update gmail.reply tool description**

Replace the `gmail.reply` tool entry (lines 497-510):
```typescript
{
    name: "gmail.reply",
    description:
      "Reply to an existing email by message ID. The app will show the draft reply in a confirmation card before actually sending. Just call this tool with the composed reply.",
    input_schema: {
      type: "object",
      properties: {
        messageId: { type: "string", description: "The Gmail message ID to reply to." },
        body: { type: "string", description: "Reply body text." },
        to: { type: "string", description: "Override recipient (optional, defaults to original sender)." },
        cc: { type: "string", description: "CC email address (optional)." },
      },
      required: ["messageId", "body"],
    },
  },
```

- [ ] **Step 3: Commit tool description changes**
```bash
git add server/src/core/conductorService.ts
git commit -m "feat: update gmail.send/reply tool descriptions — remove confirmation requirement"
```

### Task 3: Server-Side Confirmation Flow for gmail.send/reply

**Files:**
- Modify: `server/src/core/conductorService.ts:1485-1513` (executeServerTool cases)

- [ ] **Step 1: Change gmail.send to emit confirmation to iOS and wait**

Replace the `case "gmail.send"` block (lines 1485-1498) with:
```typescript
case "gmail.send": {
  if (!this.gmailClient) {
    return { result: null, error: "gmail_not_configured" };
  }
  const to = stringFromRecord(args, "to");
  const subject = stringFromRecord(args, "subject");
  const body = stringFromRecord(args, "body");
  if (!to || !subject || !body) {
    return { result: null, error: "gmail_send_requires_to_subject_body" };
  }
  const cc = stringFromRecord(args, "cc");

  // Emit draft to iOS for user confirmation
  const confirmCallId = crypto.randomUUID();
  const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
    callId: confirmCallId,
    name: "gmail.send.confirm",
    arguments: JSON.stringify({ to, cc: cc ?? undefined, subject, body }),
  });
  session.pendingToolCalls.set(confirmCallId, {
    callId: confirmCallId,
    toolName: "gmail.send.confirm",
    emittedAt: confirmEnvelope.timestamp,
    toolArguments: { to, cc, subject, body },
  });
  emit(confirmEnvelope);

  // Wait for user confirmation (120s timeout — user needs time to read)
  const { result: confirmResult, error: confirmError } = await waitForToolResult(session, confirmCallId, 120_000);
  if (confirmError || !confirmResult) {
    return { result: null, error: confirmError ?? "gmail_send_not_confirmed" };
  }

  let confirmed = false;
  try {
    const parsed = JSON.parse(confirmResult);
    confirmed = parsed.confirmed === true;
  } catch {
    return { result: null, error: "gmail_send_invalid_confirmation" };
  }

  if (!confirmed) {
    return { result: stableJSONStringify({ status: "cancelled", message: "User declined to send the email." }), error: null };
  }

  const sendResult = await this.gmailClient.send(session, { to, cc, subject, body });
  return { result: stableJSONStringify(sendResult), error: null };
}
```

- [ ] **Step 2: Change gmail.reply to emit confirmation to iOS and wait**

Replace the `case "gmail.reply"` block (lines 1500-1513) with:
```typescript
case "gmail.reply": {
  if (!this.gmailClient) {
    return { result: null, error: "gmail_not_configured" };
  }
  const messageId = stringFromRecord(args, "messageId");
  const body = stringFromRecord(args, "body");
  if (!messageId || !body) {
    return { result: null, error: "gmail_reply_requires_messageId_and_body" };
  }
  const to = stringFromRecord(args, "to");
  const cc = stringFromRecord(args, "cc");

  // Emit draft to iOS for user confirmation
  const confirmCallId = crypto.randomUUID();
  const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
    callId: confirmCallId,
    name: "gmail.reply.confirm",
    arguments: JSON.stringify({ messageId, body, to: to ?? undefined, cc: cc ?? undefined }),
  });
  session.pendingToolCalls.set(confirmCallId, {
    callId: confirmCallId,
    toolName: "gmail.reply.confirm",
    emittedAt: confirmEnvelope.timestamp,
    toolArguments: { messageId, body, to, cc },
  });
  emit(confirmEnvelope);

  const { result: confirmResult, error: confirmError } = await waitForToolResult(session, confirmCallId, 120_000);
  if (confirmError || !confirmResult) {
    return { result: null, error: confirmError ?? "gmail_reply_not_confirmed" };
  }

  let confirmed = false;
  try {
    const parsed = JSON.parse(confirmResult);
    confirmed = parsed.confirmed === true;
  } catch {
    return { result: null, error: "gmail_reply_invalid_confirmation" };
  }

  if (!confirmed) {
    return { result: stableJSONStringify({ status: "cancelled", message: "User declined to send the reply." }), error: null };
  }

  const replyResult = await this.gmailClient.reply(session, messageId, { body, to, cc });
  return { result: stableJSONStringify(replyResult), error: null };
}
```

- [ ] **Step 3: Commit server confirmation flow**
```bash
git add server/src/core/conductorService.ts
git commit -m "feat: gmail.send/reply emit confirmation to iOS before sending"
```

## Chunk 2: iOS-Side Changes

### Task 4: Create EmailDraftCard Model

**Files:**
- Create: `ios/Abyss/Abyss/Models/EmailDraftCard.swift`

- [ ] **Step 1: Create the EmailDraftCard model**

```swift
import Foundation

enum EmailDraftSendState: Equatable, Sendable {
    case pending    // Awaiting user action
    case sending    // User tapped Send, waiting for server
    case sent       // Server confirmed sent
    case cancelled  // User tapped Cancel
    case failed(String) // Send failed with error message
}

struct EmailDraftCard: Identifiable, Equatable, Sendable {
    let id: UUID
    let callId: String
    let to: String
    let cc: String?
    let subject: String
    let body: String
    let messageId: String? // For replies — the original message ID
    var sendState: EmailDraftSendState
    var anchorMessageID: UUID?

    var isReply: Bool { messageId != nil }

    init(
        id: UUID = UUID(),
        callId: String,
        to: String,
        cc: String? = nil,
        subject: String,
        body: String,
        messageId: String? = nil,
        sendState: EmailDraftSendState = .pending,
        anchorMessageID: UUID? = nil
    ) {
        self.id = id
        self.callId = callId
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.messageId = messageId
        self.sendState = sendState
        self.anchorMessageID = anchorMessageID
    }
}
```

- [ ] **Step 2: Commit model**
```bash
git add ios/Abyss/Abyss/Models/EmailDraftCard.swift
git commit -m "feat: add EmailDraftCard model"
```

### Task 5: Create EmailDraftManager (Suspension Manager)

**Files:**
- Create: `ios/Abyss/Abyss/Services/EmailDraftManager.swift`

This mirrors the `RepositorySelectionManager` pattern — holds a `CheckedContinuation` that suspends tool execution until the user taps Send or Cancel.

- [ ] **Step 1: Create EmailDraftManager**

```swift
import Foundation

@MainActor
final class EmailDraftManager: ObservableObject {

    enum DraftError: LocalizedError {
        case cancelled
        case timeout

        var errorDescription: String? {
            switch self {
            case .cancelled: return "User cancelled the email."
            case .timeout: return "Email confirmation timed out."
            }
        }
    }

    @Published private(set) var activeDrafts: [EmailDraftCard] = []

    private var pendingContinuations: [String: CheckedContinuation<Bool, Error>] = [:]

    /// Present a draft card and suspend until user confirms or cancels.
    /// Returns `true` if user confirmed (send), throws `DraftError.cancelled` if declined.
    func requestConfirmation(
        callId: String,
        to: String,
        cc: String?,
        subject: String,
        body: String,
        messageId: String?,
        anchorMessageID: UUID?
    ) async throws -> Bool {
        let card = EmailDraftCard(
            callId: callId,
            to: to,
            cc: cc,
            subject: subject,
            body: body,
            messageId: messageId,
            anchorMessageID: anchorMessageID
        )

        activeDrafts.append(card)

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuations[callId] = continuation
        }
    }

    /// User tapped Send on a draft card.
    func confirmSend(callId: String) {
        guard let index = activeDrafts.firstIndex(where: { $0.callId == callId }) else { return }
        activeDrafts[index].sendState = .sending

        if let continuation = pendingContinuations.removeValue(forKey: callId) {
            continuation.resume(returning: true)
        }
    }

    /// User tapped Cancel on a draft card.
    func cancelDraft(callId: String) {
        if let continuation = pendingContinuations.removeValue(forKey: callId) {
            continuation.resume(throwing: DraftError.cancelled)
        }
        activeDrafts.removeAll { $0.callId == callId }
    }

    /// Mark a draft as sent (called after server confirms the email was sent).
    func markSent(callId: String) {
        if let index = activeDrafts.firstIndex(where: { $0.callId == callId }) {
            activeDrafts[index].sendState = .sent
        }
    }

    /// Mark a draft as failed.
    func markFailed(callId: String, error: String) {
        if let index = activeDrafts.firstIndex(where: { $0.callId == callId }) {
            activeDrafts[index].sendState = .failed(error)
        }
    }

    /// Remove a draft card from the list (e.g., after animation completes).
    func dismissDraft(callId: String) {
        activeDrafts.removeAll { $0.callId == callId }
    }
}
```

- [ ] **Step 2: Commit manager**
```bash
git add ios/Abyss/Abyss/Services/EmailDraftManager.swift
git commit -m "feat: add EmailDraftManager with CheckedContinuation suspension"
```

### Task 6: Create GmailSendConfirmTool and GmailReplyConfirmTool

**Files:**
- Create: `ios/Abyss/Abyss/Tools/GmailSendConfirmTool.swift`
- Create: `ios/Abyss/Abyss/Tools/GmailReplyConfirmTool.swift`

These are iOS-side tools that handle the `gmail.send.confirm` / `gmail.reply.confirm` tool calls from the server, present the draft card, and return confirmation.

- [ ] **Step 1: Create GmailSendConfirmTool**

```swift
import Foundation

/// Tool: gmail.send.confirm
/// Presents an email draft card and waits for user confirmation before sending.
struct GmailSendConfirmTool: Tool, @unchecked Sendable {
    static let name = "gmail.send.confirm"

    struct Arguments: Codable, Sendable {
        let to: String
        let cc: String?
        let subject: String
        let body: String
    }

    struct Result: Codable, Sendable {
        let confirmed: Bool
        let message: String
    }

    private let draftManager: EmailDraftManager

    init(draftManager: EmailDraftManager) {
        self.draftManager = draftManager
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        do {
            let confirmed = try await draftManager.requestConfirmation(
                callId: UUID().uuidString,
                to: arguments.to,
                cc: arguments.cc,
                subject: arguments.subject,
                body: arguments.body,
                messageId: nil,
                anchorMessageID: nil
            )
            return Result(confirmed: confirmed, message: "User confirmed. Email sent.")
        } catch is EmailDraftManager.DraftError {
            return Result(confirmed: false, message: "User cancelled the email.")
        }
    }
}
```

- [ ] **Step 2: Create GmailReplyConfirmTool**

```swift
import Foundation

/// Tool: gmail.reply.confirm
/// Presents an email reply draft card and waits for user confirmation before sending.
struct GmailReplyConfirmTool: Tool, @unchecked Sendable {
    static let name = "gmail.reply.confirm"

    struct Arguments: Codable, Sendable {
        let messageId: String
        let body: String
        let to: String?
        let cc: String?
    }

    struct Result: Codable, Sendable {
        let confirmed: Bool
        let message: String
    }

    private let draftManager: EmailDraftManager

    init(draftManager: EmailDraftManager) {
        self.draftManager = draftManager
    }

    @MainActor
    func execute(_ arguments: Arguments) async throws -> Result {
        do {
            let confirmed = try await draftManager.requestConfirmation(
                callId: UUID().uuidString,
                to: arguments.to ?? "",
                cc: arguments.cc,
                subject: "Re:", // Reply subject is handled server-side
                body: arguments.body,
                messageId: arguments.messageId,
                anchorMessageID: nil
            )
            return Result(confirmed: confirmed, message: "User confirmed. Reply sent.")
        } catch is EmailDraftManager.DraftError {
            return Result(confirmed: false, message: "User cancelled the reply.")
        }
    }
}
```

- [ ] **Step 3: Commit tools**
```bash
git add ios/Abyss/Abyss/Tools/GmailSendConfirmTool.swift ios/Abyss/Abyss/Tools/GmailReplyConfirmTool.swift
git commit -m "feat: add GmailSendConfirmTool and GmailReplyConfirmTool"
```

### Task 7: Create EmailDraftCardView

**Files:**
- Create: `ios/Abyss/Abyss/Views/EmailDraftCardView.swift`

- [ ] **Step 1: Create the draft card view with Send/Cancel buttons**

```swift
import SwiftUI

struct EmailDraftCardView: View {
    let card: EmailDraftCard
    let onSend: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: card.isReply ? "arrowshape.turn.up.left.fill" : "envelope.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))

                Text(card.isReply ? "Draft Reply" : "Draft Email")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

                Spacer()

                statusBadge
            }

            // To field
            HStack(spacing: 4) {
                Text("To:")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                Text(card.to)
                    .font(.caption)
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .lineLimit(1)
            }

            // CC field (if present)
            if let cc = card.cc, !cc.isEmpty {
                HStack(spacing: 4) {
                    Text("Cc:")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    Text(cc)
                        .font(.caption)
                        .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                        .lineLimit(1)
                }
            }

            // Subject
            Text(card.subject)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

            Divider()

            // Body
            ScrollView {
                Text(card.body)
                    .font(.callout)
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            // Action buttons
            if card.sendState == .pending {
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(AppTheme.agentCardStroke(for: colorScheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onSend) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12))
                            Text("Send")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.agentCardBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.agentCardStroke(for: colorScheme), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch card.sendState {
        case .pending:
            EmptyView()
        case .sending:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Sending...")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
        case .sent:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text("Sent")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.green)
        case .cancelled:
            Text("Cancelled")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
        case .failed(let error):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text(error.isEmpty ? "Failed" : error)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.red)
        }
    }
}
```

- [ ] **Step 2: Commit draft card view**
```bash
git add ios/Abyss/Abyss/Views/EmailDraftCardView.swift
git commit -m "feat: add EmailDraftCardView with Send/Cancel buttons"
```

### Task 8: Wire EmailDraftManager into ConversationViewModel

**Files:**
- Modify: `ios/Abyss/Abyss/ViewModels/ConversationViewModel.swift`

- [ ] **Step 1: Add emailDraftManager property and published drafts**

Add to the published properties (after line 16 `emailCards`):
```swift
@Published var emailDraftCards: [EmailDraftCard] = []
```

Add to the private properties (after line 49 `emailManager`):
```swift
private var emailDraftManager: EmailDraftManager!
```

- [ ] **Step 2: Initialize EmailDraftManager and register tools**

In `setupConversationComponents()` (after line 297 `emailManager = ...`), add:
```swift
emailDraftManager = EmailDraftManager()
```

In `setupToolSystem()` (after line 256 `registry.register(RepositoriesSelectTool(...))`), add:
```swift
// emailDraftManager is initialized later in setupConversationComponents,
// so we register draft tools there instead
```

Actually, since `setupToolSystem` runs before `setupConversationComponents`, we need to create the `emailDraftManager` first. Move its initialization into `setupToolSystem`, or create it before both calls.

Better approach — create `emailDraftManager` in each `init` before `setupToolSystem`:

In the primary `init(sessionId:)` (around line 59-84), add before `setupToolSystem()`:
```swift
self.emailDraftManager = EmailDraftManager()
```

In init at line 86-102, add before `setupToolSystem(...)`:
```swift
self.emailDraftManager = EmailDraftManager()
```

In init at line 104-127, add before `setupToolSystem(...)`:
```swift
self.emailDraftManager = EmailDraftManager()
```

Then change the property declaration from optional:
```swift
private var emailDraftManager: EmailDraftManager!
```
to:
```swift
private let emailDraftManager: EmailDraftManager
```

Wait — the `emailDraftManager` is a class with `@Published`, so we need it as an `ObservableObject`. Since `ConversationViewModel` already has manual `@Published` bindings for other managers, just keep it as a stored property (non-optional, initialized before other setup).

Then in `setupToolSystem()`, after registering RepositoriesSelectTool, add:
```swift
registry.register(GmailSendConfirmTool(draftManager: emailDraftManager))
registry.register(GmailReplyConfirmTool(draftManager: emailDraftManager))
```

- [ ] **Step 3: Observe draft manager state**

In `observeStores()`, add after the `emailManager.$emailCards` binding (after line 356):
```swift
emailDraftManager.$activeDrafts
    .receive(on: RunLoop.main)
    .assign(to: &$emailDraftCards)
```

- [ ] **Step 4: Add public methods for draft actions**

Add after `toggleEmailCardExpanded` (after line 230):
```swift
func confirmEmailDraft(callId: String) {
    emailDraftManager.confirmSend(callId: callId)
}

func cancelEmailDraft(callId: String) {
    emailDraftManager.cancelDraft(callId: callId)
}

func dismissEmailDraft(callId: String) {
    emailDraftManager.dismissDraft(callId: callId)
}
```

- [ ] **Step 5: Commit ViewModel wiring**
```bash
git add ios/Abyss/Abyss/ViewModels/ConversationViewModel.swift
git commit -m "feat: wire EmailDraftManager into ConversationViewModel"
```

### Task 9: Update TranscriptView to Render Email Cards and Draft Cards

**Files:**
- Modify: `ios/Abyss/Abyss/Views/TranscriptView.swift`

- [ ] **Step 1: Add email card and draft card properties and item types**

Add properties to `TranscriptView` (after line 18 `onToggleAgentExpanded`):
```swift
var emailCards: [EmailCard] = []
var onToggleEmailExpanded: (UUID) -> Void = { _ in }
var emailDraftCards: [EmailDraftCard] = []
var onSendDraft: (String) -> Void = { _ in }
var onCancelDraft: (String) -> Void = { _ in }
```

Add new cases to `TranscriptItem` enum (after `.agentCard`):
```swift
case emailCard(EmailCard)
case emailDraftCard(EmailDraftCard)
```

Update the `id` computed property in `TranscriptItem`:
```swift
var id: String {
    switch self {
    case .message(let message):
        return "message-\(message.id.uuidString)"
    case .agentCard(let card):
        return Self.agentCardID(card.id)
    case .emailCard(let card):
        return "email-\(card.id.uuidString)"
    case .emailDraftCard(let card):
        return "draft-\(card.id.uuidString)"
    }
}
```

- [ ] **Step 2: Add rendering for new card types in body**

In the `ForEach(transcriptItems)` switch (after the `.agentCard` case at line 38), add:
```swift
case .emailCard(let card):
    EmailCardView(
        card: card,
        onToggleExpanded: { onToggleEmailExpanded(card.id) }
    )
    .padding(.horizontal, 12)
    .id(item.id)

case .emailDraftCard(let card):
    EmailDraftCardView(
        card: card,
        onSend: { onSendDraft(card.callId) },
        onCancel: { onCancelDraft(card.callId) }
    )
    .padding(.horizontal, 12)
    .id(item.id)
```

- [ ] **Step 3: Update transcriptItems computation to include email cards and drafts**

Replace the `transcriptItems` computed property (lines 109-131):
```swift
private var transcriptItems: [TranscriptItem] {
    let messageIDs = Set(messages.map(\.id))

    let anchoredAgentCards = Dictionary(grouping: agentProgressCards.compactMap { card -> (UUID, AgentProgressCard)? in
        guard let anchor = card.anchorMessageID else { return nil }
        return (anchor, card)
    }, by: \.0)

    let anchoredEmailCards = Dictionary(grouping: emailCards.compactMap { card -> (UUID, EmailCard)? in
        guard let anchor = card.anchorMessageID else { return nil }
        return (anchor, card)
    }, by: \.0)

    let anchoredDraftCards = Dictionary(grouping: emailDraftCards.compactMap { card -> (UUID, EmailDraftCard)? in
        guard let anchor = card.anchorMessageID else { return nil }
        return (anchor, card)
    }, by: \.0)

    var items: [TranscriptItem] = []
    for message in messages {
        items.append(.message(message))
        if let agentCards = anchoredAgentCards[message.id] {
            for entry in agentCards {
                items.append(.agentCard(entry.1))
            }
        }
        if let emailCardsForMsg = anchoredEmailCards[message.id] {
            for entry in emailCardsForMsg {
                items.append(.emailCard(entry.1))
            }
        }
        if let draftCardsForMsg = anchoredDraftCards[message.id] {
            for entry in draftCardsForMsg {
                items.append(.emailDraftCard(entry.1))
            }
        }
    }

    // Unanchored cards
    for card in agentProgressCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
        items.append(.agentCard(card))
    }
    for card in emailCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
        items.append(.emailCard(card))
    }
    for card in emailDraftCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
        items.append(.emailDraftCard(card))
    }

    return items
}
```

- [ ] **Step 4: Commit TranscriptView updates**
```bash
git add ios/Abyss/Abyss/Views/TranscriptView.swift
git commit -m "feat: render email cards and draft cards in TranscriptView"
```

### Task 10: Update ContentView to Pass Email Cards to TranscriptView

**Files:**
- Modify: `ios/Abyss/Abyss/Views/ContentView.swift:346-361`

- [ ] **Step 1: Add email card and draft card props to TranscriptView call**

Update the `TranscriptView(...)` call (around lines 346-361) to include the new properties:
```swift
TranscriptView(
    messages: viewModel.messages,
    agentProgressCards: viewModel.agentProgressCards,
    partialTranscript: viewModel.partialTranscript,
    assistantPartialSpeech: viewModel.assistantPartialSpeech,
    appState: viewModel.appState,
    onRefreshAgent: { viewModel.refreshAgentStatus(cardID: $0) },
    onCancelAgent: { viewModel.cancelAgent(cardID: $0) },
    onDismissAgent: { cardID in
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.dismissAgentCard(cardID: cardID)
        }
    },
    onToggleAgentConversation: { viewModel.toggleConversationExpanded(cardID: $0) },
    onToggleAgentExpanded: { viewModel.toggleAgentCardExpanded(cardID: $0) },
    emailCards: viewModel.emailCards,
    onToggleEmailExpanded: { viewModel.toggleEmailCardExpanded(cardID: $0) },
    emailDraftCards: viewModel.emailDraftCards,
    onSendDraft: { viewModel.confirmEmailDraft(callId: $0) },
    onCancelDraft: { viewModel.cancelEmailDraft(callId: $0) }
)
```

- [ ] **Step 2: Commit ContentView wiring**
```bash
git add ios/Abyss/Abyss/Views/ContentView.swift
git commit -m "feat: pass email and draft card data to TranscriptView"
```

## Chunk 3: CLAUDE.md and Xcode Project Updates

### Task 11: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update project description to reflect personal assistant scope**

Change the first line under `## Project Overview` from:
```
Abyss is a voice-first AI conductor architecture.
```
to:
```
Abyss is a voice-first AI personal assistant architecture.
```

Add to the description after "paired macOS bridge":
```
It serves as both a coding assistant (via Cursor Cloud Agents and macOS bridge) and a personal assistant (email, scheduling, and more).
```

- [ ] **Step 2: Add Gmail draft confirmation flow documentation**

In the `### Server Flow` section, add a new item after item 5:
```
6. For `gmail.send`/`gmail.reply`, server emits a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS → iOS shows a draft card with Send/Cancel → user confirms → server sends the email
```

Add to `#### iOS Feature Systems` a new section:
```
**Email Draft Confirmation:** When the LLM calls `gmail.send` or `gmail.reply`, the server emits a `gmail.send.confirm`/`gmail.reply.confirm` tool call to iOS. `EmailDraftManager` (using `CheckedContinuation` suspension like `RepositorySelectionManager`) presents an `EmailDraftCardView` with Send/Cancel buttons. The tool execution suspends until the user acts, then returns the confirmation to the server which completes the actual send.
```

- [ ] **Step 3: Commit CLAUDE.md updates**
```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md — personal assistant scope, email draft flow"
```

### Task 12: Add New Files to Xcode Project

**Files:**
- Modify: `ios/Abyss/Abyss.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add new Swift files to the Xcode project**

The new files that need to be added to the Xcode project file group:
- `ios/Abyss/Abyss/Models/EmailDraftCard.swift`
- `ios/Abyss/Abyss/Services/EmailDraftManager.swift`
- `ios/Abyss/Abyss/Tools/GmailSendConfirmTool.swift`
- `ios/Abyss/Abyss/Tools/GmailReplyConfirmTool.swift`
- `ios/Abyss/Abyss/Views/EmailDraftCardView.swift`

Use the `xcodebuild` trick or manually add the file references to `project.pbxproj`. If using Xcode's standard project structure with automatic file discovery, the files may already be picked up. Otherwise, add PBXFileReference and PBXBuildFile entries for each new file.

**Important:** Check the existing `project.pbxproj` patterns for how other similar files (e.g., `EmailCard.swift`, `EmailCardView.swift`, `RepositorySelectionManager.swift`) are referenced, and follow the same pattern.

- [ ] **Step 2: Verify build**
```bash
cd ios/Abyss && xcodebuild -scheme Abyss -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 3: Commit Xcode project changes**
```bash
git add ios/Abyss/Abyss.xcodeproj/project.pbxproj
git commit -m "chore: add new email draft files to Xcode project"
```

### Task 13: Verify Server Build

**Files:** None (verification only)

- [ ] **Step 1: Run server TypeScript build**
```bash
cd server && npm run build 2>&1 | tail -10
```

- [ ] **Step 2: Run server tests**
```bash
cd server && npm test 2>&1 | tail -20
```

Fix any issues found.
