import SwiftUI

struct EmailCardView: View {
    let card: EmailCard
    let onToggleExpanded: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggleExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.from)
                                .font(.subheadline.bold())
                                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                                .lineLimit(1)

                            Text(card.subject)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                                .lineLimit(card.isExpanded ? nil : 1)
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(card.date)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                                .lineLimit(1)

                            Image(systemName: card.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                        }
                    }

                    if !card.isExpanded {
                        Text(card.snippet)
                            .font(.caption)
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if card.isExpanded {
                if !card.to.isEmpty {
                    HStack(spacing: 4) {
                        Text("To:")
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                        Text(card.to.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                            .lineLimit(2)
                    }
                }

                Divider()

                if let body = card.body, !body.isEmpty {
                    ScrollView {
                        Text(body)
                            .font(.callout)
                            .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                } else {
                    Text(card.snippet)
                        .font(.callout)
                        .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
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
}
