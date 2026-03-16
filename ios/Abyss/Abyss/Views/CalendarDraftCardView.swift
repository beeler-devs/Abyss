import SwiftUI

struct CalendarDraftCardView: View {
    let card: CalendarDraftCard
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: actionIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.CardCategory.calendar.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(AppTheme.cardIconBackground(category: .calendar, colorScheme: colorScheme))
                    )

                Text(actionTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

                Spacer()

                statusBadge
            }

            // Event summary
            Text(card.summary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))

            // Time range
            if let start = card.startTime, let end = card.endTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("\(start) — \(end)")
                }
                .font(.caption)
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
            }

            // Location
            if let location = card.location, !location.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10))
                    Text(location)
                }
                .font(.caption)
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
            }

            // Attendees
            if !card.attendees.isEmpty {
                HStack(spacing: 4) {
                    Text("Attendees:")
                        .font(.caption.bold())
                    Text(card.attendees.joined(separator: ", "))
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
            }

            // Description
            if let description = card.description, !description.isEmpty {
                Divider()
                Text(description)
                    .font(.callout)
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .lineLimit(4)
            }

            // Action buttons
            if card.state == .pending {
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

                    Button(action: onConfirm) {
                        HStack(spacing: 6) {
                            Image(systemName: confirmIcon)
                                .font(.system(size: 12))
                            Text(confirmLabel)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(confirmColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .cardBackground(category: .calendar, colorScheme: colorScheme)
    }

    private var actionIcon: String {
        switch card.action {
        case .create: return "calendar.badge.plus"
        case .update: return "calendar.badge.clock"
        case .delete: return "calendar.badge.minus"
        }
    }

    private var actionTitle: String {
        switch card.action {
        case .create: return "Create Event"
        case .update: return "Update Event"
        case .delete: return "Delete Event"
        }
    }

    private var confirmIcon: String {
        card.action == .delete ? "trash.fill" : "checkmark"
    }

    private var confirmLabel: String {
        card.action == .delete ? "Delete" : "Confirm"
    }

    private var confirmColor: Color {
        card.action == .delete ? .red : .blue
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch card.state {
        case .pending:
            EmptyView()
        case .confirming:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Processing...")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
        case .confirmed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text(card.action == .delete ? "Deleted" : "Done")
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
