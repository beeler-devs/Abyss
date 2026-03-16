import SwiftUI

/// Card UI that surfaces live bridge command execution output.
struct BridgeExecCardView: View {
    let card: BridgeExecCard
    let onToggleExpanded: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if card.isExpanded {
                expandedContent
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.agentCardBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.agentCardStroke(for: colorScheme), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))

                Text(card.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                statusPill

                Image(systemName: card.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    .frame(width: 24, height: 24)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.caption2.bold())
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(statusColor.opacity(colorScheme == .dark ? 0.16 : 0.12))
            )
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !card.outputLines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(card.outputLines)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppTheme.codeBlockText(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("output_bottom")
                    }
                    .frame(maxHeight: 300)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppTheme.codeBlockBackground(for: colorScheme))
                    )
                    .onChange(of: card.outputLines) { _, _ in
                        proxy.scrollTo("output_bottom", anchor: .bottom)
                    }
                }
            }

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let exitCode = card.exitCode {
                Text("exit \(exitCode)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(exitCode == 0
                        ? AppTheme.agentCardMutedText(for: colorScheme)
                        : Color.red)
            }

            if let duration = formattedDuration {
                Text(duration)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private var statusLabel: String {
        switch card.status {
        case .running: return "Running"
        case .finished: return "Done"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .running: return .orange
        case .finished: return .green
        case .failed: return .red
        }
    }

    private var formattedDuration: String? {
        let end = card.finishedAt ?? Date()
        let interval = end.timeIntervalSince(card.startedAt)
        guard interval >= 1 else { return nil }
        if interval < 60 {
            return "\(Int(interval))s"
        }
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes)m \(seconds)s"
    }
}
