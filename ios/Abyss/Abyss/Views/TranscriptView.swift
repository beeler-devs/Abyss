import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Displays the conversation transcript with auto-scrolling.
struct TranscriptView: View {
    let messages: [ConversationMessage]
    var partialTranscript: String = ""
    var assistantPartialSpeech: String = ""
    var appState: AppState = .idle

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
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
                    if messages.isEmpty && assistantPartialSpeech.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                            Text("Tap the mic to start talking")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
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
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(textColor)

                if showsAssistantActions {
                    assistantActions
                }
            }
            .padding(.horizontal, isUser ? 14 : 0)
            .padding(.vertical, isUser ? 10 : 0)
            .background(bubbleBackground)

            if !isUser { Spacer(minLength: 60) }
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
