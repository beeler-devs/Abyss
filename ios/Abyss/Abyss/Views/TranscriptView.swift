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
    var onSendDraft: (String) -> Void = { _ in }
    var onCancelDraft: (String) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptItems) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message)
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
                                onSend: { onSendDraft(card.callId) },
                                onCancel: { onCancelDraft(card.callId) }
                            )
                            .padding(.horizontal, 12)
                            .id(item.id)
                        }
                    }

                    // Live AI response building up
                    if !assistantPartialSpeech.isEmpty {
                        MessageBubble(message: ConversationMessage(
                            role: .assistant,
                            text: assistantPartialSpeech,
                            isPartial: true
                        ))
                        .id("partial_assistant")
                    } else if appState == .thinking {
                        MessageBubble(message: ConversationMessage(
                            role: .assistant,
                            text: "Typing...",
                            isPartial: true
                        ))
                        .id("typing_assistant")
                    }

                    // Empty state
                    if messages.isEmpty && agentProgressCards.isEmpty && emailCards.isEmpty && emailDraftCards.isEmpty && assistantPartialSpeech.isEmpty {
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
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(TranscriptItem.message(last).id, anchor: .bottom)
                    }
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
            .onChange(of: assistantPartialSpeech) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("partial_assistant", anchor: .bottom)
                }
            }
            .onChange(of: appState) { _, newValue in
                guard newValue == .thinking else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("typing_assistant", anchor: .bottom)
                }
            }
        }
    }

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
}

private enum TranscriptItem: Identifiable {
    case message(ConversationMessage)
    case agentCard(AgentProgressCard)
    case emailCard(EmailCard)
    case emailDraftCard(EmailDraftCard)

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

    static func agentCardID(_ id: UUID) -> String {
        "agent-card-\(id.uuidString)"
    }
}

struct MessageBubble: View {
    let message: ConversationMessage
    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false

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
                    MarkdownTextView(text: message.text, foregroundColor: textColor)
                }

                if showsAssistantActions {
                    assistantActions
                }
            }
            .padding(.horizontal, isUser ? 14 : 0)
            .padding(.vertical, isUser ? 10 : 0)
            .background(bubbleBackground)

        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    private var showsAssistantActions: Bool {
        !isUser && !message.isPartial && !message.text.isEmpty
    }

    private var assistantActions: some View {
        HStack(spacing: 16) {
            Button {
                copyAssistantMessage()
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
        .padding(.top, 2)
    }

    private func copyAssistantMessage() {
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
