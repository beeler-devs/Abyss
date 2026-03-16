import SwiftUI

/// Placeholder shown while inline card references are resolving during streaming.
struct CardPlaceholderView: View {
    enum State {
        case generic
        case typed(String)
        case unresolved(type: String)
    }

    let state: State

    @Environment(\.colorScheme) private var colorScheme
    @SwiftUI.State private var shimmerPhase: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            icon
                .font(.body)
                .foregroundStyle(accentColor)
            label
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
        )
        .overlay(shimmerOverlay)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .generic:
            Image(systemName: "rectangle.on.rectangle")
        case .typed(let type), .unresolved(type: let type):
            Image(systemName: iconName(for: type))
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .generic:
            Text("Loading card…")
        case .typed(let type):
            Text("Loading \(type) card…")
        case .unresolved(type: let type):
            Text("Loading \(type) card…")
        }
    }

    private var accentColor: Color {
        switch state {
        case .generic:
            return .secondary
        case .typed(let type), .unresolved(type: let type):
            return typeColor(for: type)
        }
    }

    private var backgroundColor: Color {
        Color(UIColor.systemGray6)
    }

    @ViewBuilder
    private var shimmerOverlay: some View {
        switch state {
        case .unresolved:
            EmptyView()
        default:
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.15), .clear],
                        startPoint: UnitPoint(x: shimmerPhase - 0.3, y: 0.5),
                        endPoint: UnitPoint(x: shimmerPhase + 0.3, y: 0.5)
                    )
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        shimmerPhase = 1.3
                    }
                }
        }
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "email": return "envelope.fill"
        case "calendar": return "calendar"
        case "canvas": return "book.fill"
        case "agent": return "terminal.fill"
        case "bridge": return "desktopcomputer"
        default: return "rectangle.on.rectangle"
        }
    }

    private func typeColor(for type: String) -> Color {
        switch type {
        case "email": return .blue
        case "calendar": return .orange
        case "canvas": return .indigo
        case "agent": return .green
        case "bridge": return .purple
        default: return .secondary
        }
    }

    static func placeholderState(from partialInfo: String) -> State {
        let parts = partialInfo.split(separator: ":")
        if parts.count >= 2 { return .typed(String(parts[1])) }
        return .generic
    }
}
