import SwiftUI

/// Displays the conversation transcript with auto-scrolling.
struct TranscriptView: View {
    let messages: [ConversationMessage]
    let partialTranscript: String
    let appState: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    // Show partial transcript while listening
                    if !partialTranscript.isEmpty && (appState == .listening || appState == .transcribing) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(partialTranscript)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                        .padding(.horizontal)
                        .id("partial")
                    }

                    // Empty state
                    if messages.isEmpty && partialTranscript.isEmpty {
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
            .onChange(of: partialTranscript) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("partial", anchor: .bottom)
                }
            }
        }
    }
}

struct MessageBubble: View {
    let message: ConversationMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, isUser ? 14 : 0)
            .padding(.vertical, isUser ? 10 : 0)
            .background(bubbleBackground)

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    private var bubbleBackground: some View {
        Group {
            if isUser {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 33 / 255, green: 33 / 255, blue: 33 / 255))
            } else {
                Color.clear
            }
        }
    }

    private var textColor: Color {
        if isUser {
            return .white
        }
        return message.isPartial ? .secondary : .primary
    }
}
