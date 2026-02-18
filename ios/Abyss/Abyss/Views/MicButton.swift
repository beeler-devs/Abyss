import SwiftUI

/// Pill-style input control that supports voice and text entry.
struct MicButton: View {
    let appState: AppState
    let recordingMode: RecordingMode
    @Binding var isTypingMode: Bool
    @Binding var typedText: String
    let onTap: () -> Void
    let onPressDown: () -> Void
    let onPressUp: () -> Void
    let onSendTyped: (String) -> Void

    @State private var isPressing = false
    @State private var didSwitchToTyping = false

    private let controlHeight: CGFloat = 56
    private let iconTint = Color(red: 156 / 255, green: 156 / 255, blue: 156 / 255)
    private let barColor = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)

    private var isListening: Bool {
        appState == .listening || appState == .transcribing
    }

    var body: some View {
        Group {
            if isTypingMode {
                typingBar
            } else {
                voiceBar
            }
        }
        .frame(height: controlHeight)
    }

    private var voiceBar: some View {
        HStack(spacing: 12) {
            if isListening {
                LiveWaveformView(tint: iconTint)
                    .frame(width: 58, height: 24)
            } else {
                Color.clear
                    .frame(width: 58, height: 24)
            }

            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(iconTint)

            Color.clear
                .frame(width: 58, height: 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: controlHeight)
        .background(
            RoundedRectangle(cornerRadius: controlHeight / 2)
                .fill(barColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: controlHeight / 2)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: controlHeight / 2))
        .gesture(voiceGesture)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Tap to record or hold and swipe up to type")
    }

    private var typingBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTypingMode = false
                }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .buttonStyle(.plain)

            TextField("Type a message", text: $typedText)
                .font(.body)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit(submitTypedText)

            Button(action: submitTypedText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(canSubmitText ? iconTint : iconTint.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitText)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: controlHeight)
        .background(
            RoundedRectangle(cornerRadius: controlHeight / 2)
                .fill(barColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: controlHeight / 2)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var voiceGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if recordingMode == .pressAndHold && !isPressing {
                    isPressing = true
                    onPressDown()
                }

                if !didSwitchToTyping && value.translation.height < -36 {
                    didSwitchToTyping = true

                    if recordingMode == .pressAndHold && isPressing {
                        onPressUp()
                    } else if recordingMode == .tapToToggle && isListening {
                        onTap()
                    }

                    isPressing = false
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.92)) {
                        isTypingMode = true
                    }
                }
            }
            .onEnded { value in
                defer {
                    isPressing = false
                    didSwitchToTyping = false
                }

                if didSwitchToTyping {
                    return
                }

                switch recordingMode {
                case .tapToToggle:
                    if isTapGesture(value.translation) {
                        print("🖱️ [STEP 0] MicButton tap gesture recognized (translation=\(value.translation)) — calling onTap()")
                        onTap()
                    } else {
                        print("🖱️ [STEP 0-MISS] MicButton drag too large — not a tap (translation=\(value.translation))")
                    }
                case .pressAndHold:
                    if isPressing {
                        onPressUp()
                    }
                }
            }
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

    private func isTapGesture(_ translation: CGSize) -> Bool {
        abs(translation.width) < 12 && abs(translation.height) < 12
    }

    private var accessibilityLabel: String {
        switch appState {
        case .idle: return "Start recording"
        case .listening: return "Stop recording"
        case .transcribing: return "Finalizing transcript"
        case .thinking: return "Processing"
        case .speaking: return "Interrupt and speak"
        case .error: return "Retry"
        }
    }
}

private struct LiveWaveformView: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 3) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(0.9))
                        .frame(width: 4, height: barHeight(time: time, index: index))
                }
            }
        }
    }

    private func barHeight(time: TimeInterval, index: Int) -> CGFloat {
        let phase = time * 6 + Double(index) * 0.8
        let normalized = (sin(phase) + 1) / 2
        return 8 + CGFloat(normalized) * 12
    }
}
