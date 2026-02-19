import SwiftUI

/// Card UI that surfaces live Cursor Cloud Agent progress.
struct AgentProgressCardView: View {
    let card: AgentProgressCard
    let onRefresh: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    if let repository = card.repository {
                        Text(repository)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(card.statusLabel)
                    .font(.caption.bold())
                    .foregroundStyle(statusBadgeForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusBadgeBackground)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(card.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        stepIcon(for: step.state)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18, alignment: .center)

                        Text(step.text)
                            .font(.body)
                            .foregroundStyle(stepTextColor(for: step.state))
                    }
                }
            }

            Text(card.errorMessage ?? card.summary)
                .font(.footnote)
                .foregroundStyle(card.errorMessage == nil ? Color.white.opacity(0.8) : Color.red.opacity(0.85))
                .lineLimit(3)

            VStack(spacing: 8) {
                HStack {
                    Text(statusFooterText)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.75))

                    Spacer()

                    HStack(spacing: 8) {
                        Button("Refresh", action: onRefresh)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.85))

                        if !card.isTerminal {
                            Button("Stop", action: onCancel)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.9))
                        }
                    }
                }

                GeometryReader { proxy in
                    let width = max(0, proxy.size.width * card.progress)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 4)

                        Capsule()
                            .fill(progressFillColor)
                            .frame(width: width, height: 4)
                    }
                }
                .frame(height: 4)
            }

            footerMeta
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 20 / 255, green: 22 / 255, blue: 27 / 255))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var statusBadgeForeground: Color {
        switch card.normalizedStatus {
        case "FINISHED": return .green
        case "FAILED": return .red
        case "STOPPED", "CANCELLED": return .orange
        case "RUNNING": return .yellow
        default: return .white.opacity(0.85)
        }
    }

    private var statusBadgeBackground: Color {
        statusBadgeForeground.opacity(0.16)
    }

    private var progressFillColor: Color {
        switch card.normalizedStatus {
        case "FINISHED": return .green
        case "FAILED": return .red
        case "STOPPED", "CANCELLED": return .orange
        default: return .white.opacity(0.9)
        }
    }

    @ViewBuilder
    private func stepIcon(for state: AgentProgressCard.Step.State) -> some View {
        switch state {
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active:
            Image(systemName: "circle.dashed").foregroundStyle(.yellow)
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.gray)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func stepTextColor(for state: AgentProgressCard.Step.State) -> Color {
        switch state {
        case .pending:
            return Color.white.opacity(0.62)
        case .failed:
            return Color.red.opacity(0.9)
        default:
            return Color.white.opacity(0.92)
        }
    }

    private var statusFooterText: String {
        let updated = relativeFormatter.localizedString(for: card.updatedAt, relativeTo: Date())
        return "Updated \(updated)"
    }

    @ViewBuilder
    private var footerMeta: some View {
        HStack(spacing: 10) {
            if let branchName = card.branchName, !branchName.isEmpty {
                Text(branchName)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }

            if let prURL = card.prURL, let url = URL(string: prURL) {
                Link("PR", destination: url)
                    .font(.caption)
            }

            if let agentURL = card.agentURL, let url = URL(string: agentURL) {
                Link("Open Agent", destination: url)
                    .font(.caption)
            }
        }
    }

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
