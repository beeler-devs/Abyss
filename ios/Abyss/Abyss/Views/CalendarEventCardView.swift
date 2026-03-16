import SwiftUI

struct CalendarEventCardView: View {
    let card: CalendarEventCard
    let onToggleExpanded: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation(AppTheme.cardExpandAnimation) { onToggleExpanded() } }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Image(systemName: "calendar")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.CardCategory.calendar.accentColor)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(AppTheme.cardIconBackground(category: .calendar, colorScheme: colorScheme))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.summary)
                                .font(.subheadline.bold())
                                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                                .lineLimit(card.isExpanded ? nil : 1)

                            Text(formatTimeRange)
                                .font(.caption)
                                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                        }

                        Spacer(minLength: 4)

                        Image(systemName: card.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    }

                    if !card.isExpanded, let location = card.location, !location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin")
                                .font(.system(size: 10))
                            Text(location)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if card.isExpanded {
                if let location = card.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                        Text(location)
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                }

                if !card.attendees.isEmpty {
                    HStack(spacing: 4) {
                        Text("Attendees:")
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                        Text(card.attendees.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                            .lineLimit(3)
                    }
                }

                if let description = card.description, !description.isEmpty {
                    Divider()
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .cardBackground(category: .calendar, colorScheme: colorScheme)
    }

    private var formatTimeRange: String {
        if card.isAllDay {
            return "All day \u{2022} \(card.startTime)"
        }
        return "\(card.startTime) — \(card.endTime)"
    }
}
