import SwiftUI

struct EmailDraftCardView: View {
    let card: EmailDraftCard
    let onSend: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: card.isReply ? "arrowshape.turn.up.left.fill" : "envelope.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))

                Text(card.isReply ? "Draft Reply" : "Draft Email")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

                Spacer()

                statusBadge
            }

            // To field
            HStack(spacing: 4) {
                Text("To:")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                Text(card.to)
                    .font(.caption)
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .lineLimit(1)
            }

            // CC field (if present)
            if let cc = card.cc, !cc.isEmpty {
                HStack(spacing: 4) {
                    Text("Cc:")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    Text(cc)
                        .font(.caption)
                        .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                        .lineLimit(1)
                }
            }

            // Subject
            Text(card.subject)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

            Divider()

            // Body
            ScrollView {
                Text(card.body)
                    .font(.callout)
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)

            // Action buttons
            if card.sendState == .pending {
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(AppTheme.agentCardStroke(for: colorScheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onSend) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12))
                            Text("Send")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                }
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

    @ViewBuilder
    private var statusBadge: some View {
        switch card.sendState {
        case .pending:
            EmptyView()
        case .sending:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Sending...")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
        case .sent:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text("Sent")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.green)
        case .cancelled:
            Text("Cancelled")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
        case .failed(let error):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text(error.isEmpty ? "Failed" : error)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.red)
        }
    }
}
