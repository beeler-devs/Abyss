import SwiftUI

struct CanvasCardView: View {
    let card: CanvasCard
    let onToggleExpanded: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation(AppTheme.cardExpandAnimation) { onToggleExpanded() } }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Image(systemName: iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.CardCategory.canvas.accentColor)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(AppTheme.cardIconBackground(category: .canvas, colorScheme: colorScheme))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline.bold())
                                .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                                .lineLimit(card.isExpanded ? nil : 1)

                            if let subtitle = subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                                    .lineLimit(card.isExpanded ? nil : 1)
                            }
                        }

                        Spacer(minLength: 4)

                        Image(systemName: card.isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if card.isExpanded {
                expandedContent
            }
        }
        .padding(14)
        .cardBackground(category: .canvas, colorScheme: colorScheme)
    }

    private var iconName: String {
        switch card.variant {
        case .course: return "book.closed"
        case .assignment: return "doc.text"
        case .todo: return "checklist"
        case .grade: return "chart.bar"
        case .announcement: return "megaphone"
        }
    }

    private var title: String {
        switch card.variant {
        case .course(let c): return c.name
        case .assignment(let a): return a.name
        case .todo(let t): return t.assignmentName
        case .grade(let g): return g.courseName ?? "Course"
        case .announcement(let a): return a.title
        }
    }

    private var subtitle: String? {
        switch card.variant {
        case .course(let c):
            return c.courseCode
        case .assignment(let a):
            return a.dueAt.map { formatDate($0) } ?? "No due date"
        case .todo(let t):
            return t.courseName
        case .grade(let g):
            if let grade = g.currentGrade {
                return grade
            } else if let score = g.currentScore {
                return String(format: "%.1f", score)
            }
            return nil
        case .announcement(let a):
            return a.postedAt.map { formatDate($0) }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch card.variant {
        case .course(let c):
            if let term = c.enrollmentTerm {
                detailRow(label: "Term", value: term)
            }
            if let code = c.courseCode {
                detailRow(label: "Code", value: code)
            }

        case .assignment(let a):
            if let points = a.pointsPossible {
                detailRow(label: "Points", value: String(format: "%.0f", points))
            }
            if let status = a.submissionStatus {
                detailRow(label: "Status", value: status)
            }
            if let course = a.courseName {
                detailRow(label: "Course", value: course)
            }

        case .todo(let t):
            if let dueAt = t.dueAt {
                detailRow(label: "Due", value: formatDate(dueAt))
            }
            if let type = t.type {
                detailRow(label: "Type", value: type)
            }

        case .grade(let g):
            if let score = g.currentScore {
                detailRow(label: "Current Score", value: String(format: "%.1f", score))
            }
            if let finalGrade = g.finalGrade {
                detailRow(label: "Final Grade", value: finalGrade)
            }
            if let finalScore = g.finalScore {
                detailRow(label: "Final Score", value: String(format: "%.1f", finalScore))
            }

        case .announcement(let a):
            if let author = a.authorName {
                detailRow(label: "Author", value: author)
            }
            if let message = a.message, !message.isEmpty {
                Divider()
                Text(stripHTML(message))
                    .font(.callout)
                    .foregroundStyle(AppTheme.agentCardText(for: colorScheme))
                    .textSelection(.enabled)
                    .lineLimit(10)
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption.bold())
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.agentCardMutedText(for: colorScheme))
        }
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return isoString
    }

    private func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else {
            return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
