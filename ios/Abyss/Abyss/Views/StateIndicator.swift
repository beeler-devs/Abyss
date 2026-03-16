import SwiftUI

/// Shows the current app state with an animated indicator.
struct StateIndicator: View {
    let state: AppState
    var isMuted: Bool = false

    private var color: Color {
        if isMuted { return .secondary }
        switch state {
        case .idle: return .secondary
        case .listening: return .red
        case .transcribing: return .orange
        case .thinking: return .purple
        case .speaking: return .green
        case .error: return .red
        }
    }

    private var label: String? {
        if isMuted { return "Muted" }
        switch state {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .transcribing: return "Transcribing..."
        case .thinking: return nil // uses ThinkingIndicatorView instead
        case .speaking: return "Speaking..."
        case .error: return "Error"
        }
    }

    private var iconName: String {
        if isMuted { return "mic.slash" }
        switch state {
        case .idle: return "circle"
        case .listening: return "mic.fill"
        case .transcribing: return "text.cursor"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: !isMuted && (state == .listening || state == .thinking))

            if let label {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(color)
            } else if state == .thinking {
                ThinkingIndicatorView(font: .subheadline, baseColor: color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: state)
        .animation(.easeInOut(duration: 0.2), value: isMuted)
    }
}
