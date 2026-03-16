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
    let showEventTimeline: Bool
    let onToggleMute: () -> Void
    let onInterruptSpeaking: () -> Void
    let onMicPressed: () -> Void
    let onMicReleased: () -> Void
    let onSendTyped: (String) -> Void
    let onToggleEventTimeline: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isTypingMode {
                typingBar
            } else {
                liveControls
                    .frame(height: UIConstants.actionBarControlHeight)
            }
        }
    }

    private var liveControls: some View {
        HStack(spacing: UIConstants.actionBarSpacing) {
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
                    .glassButtonBackground(cornerRadius: UIConstants.actionBarControlHeight / 2, colorScheme: colorScheme)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to typing mode")
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
            .glassButtonBackground(cornerRadius: UIConstants.actionBarControlHeight / 2, colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
    }

    private var pushToTalkButton: some View {
        // The gesture target is a RoundedRectangle whose structural identity never
        // changes regardless of isRecording. The visual content is overlaid on top.
        // isRecording is derived from appState (set asynchronously inside the Task),
        // NOT from a synchronous @Published flag, so the view doesn't re-render
        // until after the gesture's pressing callback has already fired.
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
            .onLongPressGesture(minimumDuration: .infinity, pressing: { isPressing in
                if isPressing { onMicPressed() } else { onMicReleased() }
            }, perform: {})
            .accessibilityLabel(isRecording ? "Recording, release to send" : "Hold to speak")
    }

    private var maxInputHeight: CGFloat { 120 }

    private var typingBar: some View {
        HStack(alignment: .bottom, spacing: UIConstants.actionBarSpacing) {
            ZStack(alignment: .topLeading) {
                if typedText.isEmpty {
                    Text("Type a message")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $typedText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .frame(minHeight: UIConstants.actionBarControlHeight - 16, maxHeight: maxInputHeight)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canSubmitText {
                Button(action: submitTypedText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                        .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                }
                .buttonStyle(.plain)
            } else {
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

                Button {
                    onToggleEventTimeline()
                } label: {
                    Image(systemName: showEventTimeline ? "list.bullet.circle.fill" : "list.bullet.circle")
                        .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                        .foregroundStyle(AppTheme.actionBarIconTint(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, UIConstants.actionBarPillHorizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .frame(minHeight: UIConstants.actionBarControlHeight)
        .glassButtonBackground(cornerRadius: UIConstants.actionBarControlHeight / 2, colorScheme: colorScheme)
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.height > 30 {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isTypingMode = false
                        }
                    }
                }
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
