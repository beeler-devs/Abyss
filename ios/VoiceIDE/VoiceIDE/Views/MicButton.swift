import SwiftUI

/// Large mic button with tap-to-toggle and press-and-hold support.
struct MicButton: View {
    let appState: AppState
    let recordingMode: RecordingMode
    let onTap: () -> Void
    let onPressDown: () -> Void
    let onPressUp: () -> Void

    @State private var isPressed = false

    private var isActive: Bool {
        appState == .listening || appState == .transcribing
    }

    private var buttonColor: Color {
        switch appState {
        case .idle: return .blue
        case .listening: return .red
        case .transcribing: return .orange
        case .thinking: return .purple
        case .speaking: return .green
        case .error: return .gray
        }
    }

    private var iconName: String {
        switch appState {
        case .listening, .transcribing: return "mic.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .thinking: return "brain"
        default: return "mic"
        }
    }

    var body: some View {
        ZStack {
            // Pulsing ring when active
            if isActive {
                Circle()
                    .stroke(buttonColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 88, height: 88)
                    .scaleEffect(isActive ? 1.2 : 1.0)
                    .opacity(isActive ? 0.0 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                        value: isActive
                    )
            }

            Circle()
                .fill(buttonColor.gradient)
                .frame(width: 72, height: 72)
                .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 8)
                .scaleEffect(isPressed ? 0.92 : 1.0)

            Image(systemName: iconName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .contentShape(Circle())
        .applyMicGesture(
            recordingMode: recordingMode,
            isPressed: $isPressed,
            onTap: onTap,
            onPressDown: onPressDown,
            onPressUp: onPressUp
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
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

    private var accessibilityHint: String {
        recordingMode == .tapToToggle
            ? "Tap to toggle recording"
            : "Press and hold to record"
    }
}

// MARK: - Gesture Modifier

/// Applies the correct gesture based on recording mode.
/// Using a ViewModifier avoids the opaque return type mismatch between gesture branches.
private struct MicGestureModifier: ViewModifier {
    let recordingMode: RecordingMode
    @Binding var isPressed: Bool
    let onTap: () -> Void
    let onPressDown: () -> Void
    let onPressUp: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        switch recordingMode {
        case .tapToToggle:
            content
                .onTapGesture {
                    onTap()
                }
        case .pressAndHold:
            content
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressed {
                                isPressed = true
                                onPressDown()
                            }
                        }
                        .onEnded { _ in
                            isPressed = false
                            onPressUp()
                        }
                )
        }
    }
}

private extension View {
    func applyMicGesture(
        recordingMode: RecordingMode,
        isPressed: Binding<Bool>,
        onTap: @escaping () -> Void,
        onPressDown: @escaping () -> Void,
        onPressUp: @escaping () -> Void
    ) -> some View {
        modifier(MicGestureModifier(
            recordingMode: recordingMode,
            isPressed: isPressed,
            onTap: onTap,
            onPressDown: onPressDown,
            onPressUp: onPressUp
        ))
    }
}
