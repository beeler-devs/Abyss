import SwiftUI

/// Bottom input control for live conversation mode.
/// Supports mute toggle, optional AI interrupt, and typed fallback.
struct MicButton: View {
    let isMuted: Bool
    let isSpeaking: Bool
    @Binding var isTypingMode: Bool
    @Binding var typedText: String
    let recordingMode: RecordingMode
    let isRecording: Bool
    let onToggleMute: () -> Void
    let onInterruptSpeaking: () -> Void
    let onMicPressed: () -> Void
    let onMicReleased: () -> Void
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
            if recordingMode == .pushToTalk {
                pushToTalkButton
            } else {
                muteToggleButton
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTypingMode = true
                }
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                    .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                    .frame(width: UIConstants.actionBarControlHeight, height: UIConstants.actionBarControlHeight)
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
            .accessibilityLabel("Switch to typing mode")

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

    private var muteToggleButton: some View {
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
    }

    private var pushToTalkButton: some View {
        RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
            .fill(isRecording ? Color.red : AppTheme.pillBackground(for: colorScheme))
            .overlay(
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                    Text(isRecording ? "Recording…" : "Hold to Speak")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(isRecording ? .white : AppTheme.actionBarIconTint(for: colorScheme))
                .padding(.horizontal, UIConstants.actionBarPillHorizontalPadding)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIConstants.actionBarControlHeight / 2)
                    .stroke(AppTheme.pillStroke(for: colorScheme), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .frame(height: UIConstants.actionBarControlHeight)
            // DragGesture(minimumDistance: 0) was replaced because iOS's system gesture gate
            // fires spurious .onEnded events (visible as "System gesture gate timed out" in logs).
            // onLongPressGesture with minimumDuration: .infinity never fires perform(), so
            // pressing: false is the only release signal — reliable for PTT.
            .onLongPressGesture(minimumDuration: .infinity, pressing: { isPressing in
                if isPressing { onMicPressed() } else { onMicReleased() }
            }, perform: {})
            .accessibilityLabel(isRecording ? "Recording, release to send" : "Hold to speak")
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
