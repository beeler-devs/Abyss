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
    @GestureState private var isPTTPressing = false

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
                    .glassButtonBackground(cornerRadius: UIConstants.actionBarControlHeight / 2, colorScheme: colorScheme)
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
            .glassButtonBackground(cornerRadius: UIConstants.actionBarControlHeight / 2, colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
    }

    private var pushToTalkButton: some View {
        // PTT uses a DragGesture + @GestureState so that the press/release tracking
        // lives entirely within the gesture system. This prevents SwiftUI view re-renders
        // (from @Published state changes) from destroying the gesture recognizer mid-press.
        // The visual state is driven by isPTTPressing (local @GestureState), not the
        // external isRecording prop, so no parent re-render can interrupt the gesture.
        let pressing = isPTTPressing
        return HStack(spacing: 8) {
            Image(systemName: pressing ? "waveform" : "mic.fill")
                .font(.system(size: UIConstants.actionBarIconSize, weight: .semibold))
                .contentTransition(.identity)
            Text(pressing ? "Recording…" : "Hold to Speak")
                .font(.subheadline.weight(.semibold))
                .contentTransition(.identity)
            Spacer()
        }
        .foregroundStyle(pressing ? .white : AppTheme.actionBarIconTint(for: colorScheme))
        .padding(.horizontal, UIConstants.actionBarPillHorizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: UIConstants.actionBarControlHeight)
        .pttButtonBackground(isRecording: pressing,
                             cornerRadius: UIConstants.actionBarControlHeight / 2,
                             colorScheme: colorScheme)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPTTPressing) { _, state, _ in
                    state = true
                }
                .onEnded { _ in
                    onMicReleased()
                }
        )
        .onChange(of: isPTTPressing) { newValue in
            if newValue {
                onMicPressed()
            }
        }
        .accessibilityLabel(pressing ? "Recording, release to send" : "Hold to speak")
    }

    private var typingBar: some View {
        HStack(spacing: UIConstants.actionBarSpacing) {
            TextField("Type a message", text: $typedText)
                .font(.body)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(submitTypedText)

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
        .frame(maxWidth: .infinity)
        .frame(height: UIConstants.actionBarControlHeight)
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
