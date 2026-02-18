import SwiftUI

/// Collapsible debug view showing the event timeline.
/// Great for hackathon demos and debugging the tool pipeline.
struct EventTimelineView: View {
    let events: [Event]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                Text("Event Timeline")
                    .font(.caption.bold())
                Spacer()
                Text("\(events.count) events")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray5))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(events) { event in
                            EventRow(event: event)
                                .id(event.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: events.count) { _, _ in
                    if let last = events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .padding(.horizontal, 8)
    }
}

struct EventRow: View {
    let event: Event

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Timestamp
            Text(Self.timeFormatter.string(from: event.timestamp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Icon
            eventIcon
                .font(.caption2)
                .frame(width: 14)

            // Description
            Text(eventDescription)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(eventColor)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var eventIcon: some View {
        Group {
            switch event.kind {
            case .sessionStart:
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
            case .userAudioTranscriptPartial, .userAudioTranscriptFinal:
                Image(systemName: "waveform").foregroundStyle(.blue)
            case .assistantSpeechPartial, .assistantSpeechFinal:
                Image(systemName: "text.bubble").foregroundStyle(.purple)
            case .assistantUIPatch:
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.orange)
            case .agentStatus:
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.teal)
            case .audioOutputInterrupted:
                Image(systemName: "speaker.slash.fill").foregroundStyle(.orange)
            case .toolCall:
                Image(systemName: "wrench.fill").foregroundStyle(.indigo)
            case .toolResult(let tr):
                Image(systemName: tr.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tr.isError ? .red : .green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var eventDescription: String {
        switch event.kind {
        case .sessionStart(let s):
            return "session.start (\(s.sessionId.prefix(8))...)"
        case .userAudioTranscriptPartial(let p):
            return "transcript.partial: \"\(p.text.prefix(40))\""
        case .userAudioTranscriptFinal(let f):
            return "transcript.final: \"\(f.text.prefix(40))\""
        case .assistantSpeechPartial(let p):
            return "speech.partial: \"\(p.text.prefix(40))\""
        case .assistantSpeechFinal(let f):
            return "speech.final: \"\(f.text.prefix(40))\""
        case .assistantUIPatch(let p):
            return "ui.patch: \(p.patch.prefix(30))"
        case .agentStatus(let status):
            return "agent.status: \(status.status)"
        case .audioOutputInterrupted(let interrupted):
            return "audio.output.interrupted: \(interrupted.reason)"
        case .toolCall(let tc):
            return "tool.call: \(tc.name)(\(tc.arguments.prefix(30)))"
        case .toolResult(let tr):
            if let err = tr.error {
                return "tool.result: ERR \(err.prefix(30))"
            }
            return "tool.result: \(tr.result?.prefix(30) ?? "ok")"
        case .error(let e):
            return "error[\(e.code)]: \(e.message.prefix(30))"
        }
    }

    private var eventColor: Color {
        switch event.kind {
        case .toolCall: return .indigo
        case .toolResult(let tr): return tr.isError ? .red : .green
        case .error: return .red
        default: return .primary
        }
    }
}
