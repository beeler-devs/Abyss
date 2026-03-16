import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Displays the conversation transcript with auto-scrolling.
struct TranscriptView: View {
    let messages: [ConversationMessage]
    var agentProgressCards: [AgentProgressCard] = []
    var partialTranscript: String = ""
    var assistantPartialSpeech: String = ""
    var appState: AppState = .idle
    var onRefreshAgent: (UUID) -> Void = { _ in }
    var onCancelAgent: (UUID) -> Void = { _ in }
    var onDismissAgent: (UUID) -> Void = { _ in }
    var onToggleAgentConversation: (UUID) -> Void = { _ in }
    var onToggleAgentExpanded: (UUID) -> Void = { _ in }
    var emailCards: [EmailCard] = []
    var onToggleEmailExpanded: (UUID) -> Void = { _ in }
    var emailDraftCards: [EmailDraftCard] = []
    var onSendDraft: (String, String, String, String) -> Void = { _, _, _, _ in }  // (callId, to, subject, body)
    var onCancelDraft: (String) -> Void = { _ in }
    var onEditDraft: (String, String, String, String) -> Void = { _, _, _, _ in }  // (callId, to, subject, body)
    var calendarEventCards: [CalendarEventCard] = []
    var onToggleCalendarExpanded: (UUID) -> Void = { _ in }
    var calendarDraftCards: [CalendarDraftCard] = []
    var onConfirmCalendar: (String) -> Void = { _ in }
    var onCancelCalendar: (String) -> Void = { _ in }
    var canvasCards: [CanvasCard] = []
    var onToggleCanvasExpanded: (UUID) -> Void = { _ in }
    var bridgeExecCards: [BridgeExecCard] = []
    var onToggleBridgeExecExpanded: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptItems) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message, cardResolver: resolveCard)
                                .id(item.id)
                        case .agentCard(let card):
                            AgentProgressCardView(
                                card: card,
                                onRefresh: { onRefreshAgent(card.id) },
                                onCancel: { onCancelAgent(card.id) },
                                onDismiss: { onDismissAgent(card.id) },
                                onToggleConversation: { onToggleAgentConversation(card.id) },
                                onToggleExpanded: { onToggleAgentExpanded(card.id) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)

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
                                onSend: { to, subject, body in onSendDraft(card.callId, to, subject, body) },
                                onCancel: { onCancelDraft(card.callId) },
                                onFieldEdit: { to, subject, body in onEditDraft(card.callId, to, subject, body) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)

                        case .calendarEventCard(let card):
                            CalendarEventCardView(
                                card: card,
                                onToggleExpanded: { onToggleCalendarExpanded(card.id) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)

                        case .calendarDraftCard(let card):
                            CalendarDraftCardView(
                                card: card,
                                onConfirm: { onConfirmCalendar(card.callId) },
                                onCancel: { onCancelCalendar(card.callId) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)

                        case .canvasCard(let card):
                            CanvasCardView(
                                card: card,
                                onToggleExpanded: { onToggleCanvasExpanded(card.id) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)

                        case .bridgeExecCard(let card):
                            BridgeExecCardView(
                                card: card,
                                onToggleExpanded: { onToggleBridgeExecExpanded(card.id) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)

                        case .messageActions(let message):
                            MessageActionsView(message: message)
                                .id(item.id)
                        }
                    }

                    // Live AI response building up
                    if !assistantPartialSpeech.isEmpty && !hasPersistedAssistantPartial {
                        MessageBubble(
                            message: ConversationMessage(
                                role: .assistant,
                                text: assistantPartialSpeech,
                                isPartial: true
                            ),
                            cardResolver: resolveCard
                        )
                        .id("partial_assistant")
                    } else if showsTypingIndicator {
                        HStack {
                            ThinkingIndicatorView(font: .body, baseColor: .secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                        .id("typing_assistant")
                    }

                    // Empty state
                    if messages.isEmpty && agentProgressCards.isEmpty && emailCards.isEmpty && emailDraftCards.isEmpty && calendarEventCards.isEmpty && calendarDraftCards.isEmpty && canvasCards.isEmpty && bridgeExecCards.isEmpty && assistantPartialSpeech.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                            Text("Live conversation is on. Tap mute when needed.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }

                    // Stable scroll anchor — always at the very bottom of all content.
                    // Scrolling to a growing view (like partial_assistant) causes overshoot
                    // when updates are rapid; this fixed-size anchor avoids that.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lastMessageSnapshot) { _, newValue in
                guard let snapshot = newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(TranscriptItem.messageID(snapshot.id), anchor: .bottom)
                }
            }
            .onChange(of: agentProgressCards.map(\.id)) { oldValue, newValue in
                guard newValue.count > oldValue.count,
                      let insertedID = newValue.first(where: { !oldValue.contains($0) }) else {
                    return
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(TranscriptItem.agentCardID(insertedID), anchor: .center)
                }
            }
            .onChange(of: assistantPartialSpeech) { _, newValue in
                guard !newValue.isEmpty else { return }
                // No animation — rapid streaming causes overlapping animated scrollTo
                // calls to overshoot past content when the target view keeps growing.
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
            .onChange(of: appState) { _, newValue in
                guard newValue == .thinking else { return }
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
    }

    private var transcriptItems: [TranscriptItem] {
        let messageIDs = Set(messages.map(\.id))

        // Build exclusion set of card IDs that are inline-referenced in message text
        var inlineCardIds = Set<String>()
        for message in messages where message.role == .assistant {
            for block in MarkdownTextView.parse(message.text) {
                if case .cardReference(_, let id) = block {
                    inlineCardIds.insert(id)
                }
            }
        }
        // Also check partial speech for inline references
        if !assistantPartialSpeech.isEmpty {
            for block in MarkdownTextView.parse(assistantPartialSpeech) {
                if case .cardReference(_, let id) = block {
                    inlineCardIds.insert(id)
                }
            }
        }

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

        let anchoredCalEventCards = Dictionary(grouping: calendarEventCards.compactMap { card -> (UUID, CalendarEventCard)? in
            guard let anchor = card.anchorMessageID else { return nil }
            return (anchor, card)
        }, by: \.0)

        let anchoredCalDraftCards = Dictionary(grouping: calendarDraftCards.compactMap { card -> (UUID, CalendarDraftCard)? in
            guard let anchor = card.anchorMessageID else { return nil }
            return (anchor, card)
        }, by: \.0)

        let anchoredCanvasCards = Dictionary(grouping: canvasCards.compactMap { card -> (UUID, CanvasCard)? in
            guard let anchor = card.anchorMessageID else { return nil }
            return (anchor, card)
        }, by: \.0)

        let anchoredBridgeExecCards = Dictionary(grouping: bridgeExecCards.compactMap { card -> (UUID, BridgeExecCard)? in
            guard let anchor = card.anchorMessageID else { return nil }
            return (anchor, card)
        }, by: \.0)

        var items: [TranscriptItem] = []
        for message in messages {
            items.append(.message(message))
            if let agentCards = anchoredAgentCards[message.id] {
                for entry in agentCards {
                    if let sid = entry.1.serverCardId, inlineCardIds.contains(sid) { continue }
                    items.append(.agentCard(entry.1))
                }
            }
            if let emailCardsForMsg = anchoredEmailCards[message.id] {
                for entry in emailCardsForMsg {
                    if let sid = entry.1.serverCardId, inlineCardIds.contains(sid) { continue }
                    items.append(.emailCard(entry.1))
                }
            }
            if let draftCardsForMsg = anchoredDraftCards[message.id] {
                for entry in draftCardsForMsg {
                    items.append(.emailDraftCard(entry.1))
                }
            }
            if let calEventCards = anchoredCalEventCards[message.id] {
                for entry in calEventCards {
                    if let sid = entry.1.serverCardId, inlineCardIds.contains(sid) { continue }
                    items.append(.calendarEventCard(entry.1))
                }
            }
            if let calDraftCards = anchoredCalDraftCards[message.id] {
                for entry in calDraftCards {
                    items.append(.calendarDraftCard(entry.1))
                }
            }
            if let canvasCardsForMsg = anchoredCanvasCards[message.id] {
                for entry in canvasCardsForMsg {
                    if let sid = entry.1.serverCardId, inlineCardIds.contains(sid) { continue }
                    items.append(.canvasCard(entry.1))
                }
            }
            if let bridgeExecCardsForMsg = anchoredBridgeExecCards[message.id] {
                for entry in bridgeExecCardsForMsg {
                    if let sid = entry.1.serverCardId, inlineCardIds.contains(sid) { continue }
                    items.append(.bridgeExecCard(entry.1))
                }
            }
            // Emit action buttons after any anchored cards for assistant messages
            if message.role == .assistant && !message.isPartial && !message.text.isEmpty {
                items.append(.messageActions(message))
            }
        }

        for card in agentProgressCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            if let sid = card.serverCardId, inlineCardIds.contains(sid) { continue }
            items.append(.agentCard(card))
        }
        for card in emailCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            if let sid = card.serverCardId, inlineCardIds.contains(sid) { continue }
            items.append(.emailCard(card))
        }
        for card in emailDraftCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            items.append(.emailDraftCard(card))
        }
        for card in calendarEventCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            if let sid = card.serverCardId, inlineCardIds.contains(sid) { continue }
            items.append(.calendarEventCard(card))
        }
        for card in calendarDraftCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            items.append(.calendarDraftCard(card))
        }
        for card in canvasCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            if let sid = card.serverCardId, inlineCardIds.contains(sid) { continue }
            items.append(.canvasCard(card))
        }
        for card in bridgeExecCards where card.anchorMessageID == nil || !messageIDs.contains(card.anchorMessageID!) {
            if let sid = card.serverCardId, inlineCardIds.contains(sid) { continue }
            items.append(.bridgeExecCard(card))
        }

        return items
    }

    private var hasPersistedAssistantPartial: Bool {
        messages.contains { $0.role == .assistant && $0.isPartial }
    }

    private var showsTypingIndicator: Bool {
        appState == .thinking && assistantPartialSpeech.isEmpty && !hasPersistedAssistantPartial
            && emailDraftCards.isEmpty && calendarDraftCards.isEmpty
    }

    private var lastMessageSnapshot: MessageSnapshot? {
        guard let last = messages.last else { return nil }
        return MessageSnapshot(id: last.id, text: last.text, isPartial: last.isPartial)
    }

    private func resolveCard(type: String, id: String) -> AnyView? {
        switch type {
        case "email":
            guard let card = emailCards.first(where: { $0.serverCardId == id }) else { return nil }
            return AnyView(
                EmailCardView(card: card, onToggleExpanded: { onToggleEmailExpanded(card.id) })
                    .padding(.horizontal, 12)
            )
        case "calendar":
            guard let card = calendarEventCards.first(where: { $0.serverCardId == id }) else { return nil }
            return AnyView(
                CalendarEventCardView(card: card, onToggleExpanded: { onToggleCalendarExpanded(card.id) })
                    .padding(.horizontal, 12)
            )
        case "canvas":
            guard let card = canvasCards.first(where: { $0.serverCardId == id }) else { return nil }
            return AnyView(
                CanvasCardView(card: card, onToggleExpanded: { onToggleCanvasExpanded(card.id) })
                    .padding(.horizontal, 12)
            )
        case "agent":
            guard let card = agentProgressCards.first(where: { $0.serverCardId == id }) else { return nil }
            return AnyView(
                AgentProgressCardView(
                    card: card,
                    onRefresh: { onRefreshAgent(card.id) },
                    onCancel: { onCancelAgent(card.id) },
                    onDismiss: { onDismissAgent(card.id) },
                    onToggleConversation: { onToggleAgentConversation(card.id) },
                    onToggleExpanded: { onToggleAgentExpanded(card.id) }
                )
                .padding(.horizontal, 12)
            )
        case "bridge":
            guard let card = bridgeExecCards.first(where: { $0.serverCardId == id }) else { return nil }
            return AnyView(
                BridgeExecCardView(card: card, onToggleExpanded: { onToggleBridgeExecExpanded(card.id) })
                    .padding(.horizontal, 12)
            )
        default:
            return nil
        }
    }
}

private enum TranscriptItem: Identifiable {
    case message(ConversationMessage)
    case agentCard(AgentProgressCard)
    case emailCard(EmailCard)
    case emailDraftCard(EmailDraftCard)
    case calendarEventCard(CalendarEventCard)
    case calendarDraftCard(CalendarDraftCard)
    case canvasCard(CanvasCard)
    case bridgeExecCard(BridgeExecCard)
    case messageActions(ConversationMessage)

    var id: String {
        switch self {
        case .message(let message):
            return Self.messageID(message.id)
        case .agentCard(let card):
            return Self.agentCardID(card.id)
        case .emailCard(let card):
            return "email-\(card.id.uuidString)"
        case .emailDraftCard(let card):
            return "draft-\(card.id.uuidString)"
        case .calendarEventCard(let card):
            return "cal-\(card.id.uuidString)"
        case .calendarDraftCard(let card):
            return "cal-draft-\(card.id.uuidString)"
        case .canvasCard(let card):
            return "canvas-\(card.id.uuidString)"
        case .bridgeExecCard(let card):
            return "bridge-exec-\(card.id.uuidString)"
        case .messageActions(let message):
            return "actions-\(message.id.uuidString)"
        }
    }

    static func agentCardID(_ id: UUID) -> String {
        "agent-card-\(id.uuidString)"
    }

    static func messageID(_ id: UUID) -> String {
        "message-\(id.uuidString)"
    }
}

private struct MessageSnapshot: Equatable {
    let id: UUID
    let text: String
    let isPartial: Bool
}

struct MessageBubble: View {
    let message: ConversationMessage
    var cardResolver: ((String, String) -> AnyView?)?
    @Environment(\.colorScheme) private var colorScheme

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                if isUser {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(textColor)
                } else {
                    MarkdownTextView(text: message.text, foregroundColor: textColor, cardResolver: cardResolver)
                }
            }
            .padding(.horizontal, isUser ? 14 : 0)
            .padding(.vertical, isUser ? 10 : 0)
            .background(bubbleBackground)

        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    private var bubbleBackground: some View {
        Group {
            if isUser {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppTheme.userBubbleBackground(for: colorScheme))
            } else {
                Color.clear
            }
        }
    }

    private var textColor: Color {
        if isUser {
            return AppTheme.userBubbleText(for: colorScheme)
        }
        return message.isPartial ? .secondary : .primary
    }
}

private struct MessageActionsView: View {
    let message: ConversationMessage
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                copyMessage()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "square.on.square")
            }
            .accessibilityLabel("Copy assistant response")

            Button {
                // Reserved for future feedback handling.
            } label: {
                Image(systemName: "hand.thumbsup")
            }
            .accessibilityLabel("Thumbs up")

            Button {
                // Reserved for future feedback handling.
            } label: {
                Image(systemName: "hand.thumbsdown")
            }
            .accessibilityLabel("Thumbs down")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 2)
    }

    private func copyMessage() {
#if canImport(UIKit)
        UIPasteboard.general.string = message.text
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
#endif
        withAnimation(.easeInOut(duration: 0.15)) {
            didCopy = true
        }

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) {
                    didCopy = false
                }
            }
        }
    }
}
