import SwiftUI

/// Bottom input control for live conversation mode.
/// Supports mute toggle, optional AI interrupt, and typed fallback.
struct MicButton: View {
    let isMuted: Bool
    let isSpeaking: Bool
    @Binding var isTypingMode: Bool
    @Binding var typedText: String
    let onToggleMute: () -> Void
    let onInterruptSpeaking: () -> Void
    let onSendTyped: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isTypingMode {
                typingBar
            } else {
                liveControls
            }
        }
        .frame(height: UIConstants.actionBarControlHeight)
    }

    private var liveControls: some View {
        HStack(spacing: UIConstants.actionBarSpacing) {
            Button(action: onToggleMute) {
                HStack(spacing: 8) {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                    Text(isMuted ? "Muted" : "Live")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !isMuted {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                }
                .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                .padding(.horizontal, UIConstants.actionBarPillHorizontalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: UIConstants.actionBarControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
                        .fill(AppTheme.pillBackground(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
                        .stroke(AppTheme.pillStroke(for: colorScheme), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")

            if isSpeaking {
                Button(action: onInterruptSpeaking) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: UIConstants.actionBarControlHeight, height: UIConstants.actionBarControlHeight)
                        .background(
                            Circle()
                                .fill(Color.red)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Interrupt assistant speech")
            }
        }
    }

    private var typingBar: some View {
        HStack(spacing: UIConstants.actionBarSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTypingMode = false
                }
            } label: {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                    .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
            }
            .buttonStyle(.plain)

            TextField("Type a message", text: $typedText)
                .font(.body)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(submitTypedText)

            Button(action: submitTypedText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                    .foregroundStyle(
                        canSubmitText
                        ? AppTheme.actionBarIconTint(for: colorScheme)
                        : AppTheme.actionBarIconTint(for: colorScheme).opacity(0.35)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitText)
        }
        .padding(.horizontal, UIConstants.actionBarPillHorizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: UIConstants.actionBarControlHeight)
        .background(
            RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
                .fill(AppTheme.pillBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
                .stroke(AppTheme.pillStroke(for: colorScheme), lineWidth: 1)
        )
    }

    private var canSubmitText: Bool {
        !typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitTypedText() {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSendTyped(trimmed)
        typedText = ""
    }
}
