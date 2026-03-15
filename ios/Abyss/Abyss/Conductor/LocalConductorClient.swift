import Foundation

/// Adapter that makes the Phase 1 local conductor behave like a transport-backed client.
final class LocalConductorClient: ConductorClient, @unchecked Sendable {
    private let conductor: Conductor
    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var sessionId: String?

    var inboundEvents: AsyncStream<Event> { stream }

    init(conductor: Conductor) {
        self.conductor = conductor
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func connect(sessionId: String, githubToken: String? = nil, gmailAccessToken: String? = nil, gmailRefreshToken: String? = nil, gmailTokenExpiresAt: Double? = nil) async throws {
        self.sessionId = sessionId

        let startupEvents = await conductor.handleSessionStart()
        if startupEvents.contains(where: { event in
            if case .sessionStart = event.kind { return true }
            return false
        }) {
            for event in startupEvents {
                continuation.yield(Event(id: event.id, timestamp: event.timestamp, sessionId: sessionId, kind: event.kind))
            }
        } else {
            continuation.yield(Event.sessionStart(sessionId: sessionId))
        }
    }

    func disconnect() async {
        sessionId = nil
    }

    func send(event: Event) async throws {
        if case .userAudioStreamChunk = event.kind {} else {
            AppLogger.conductor.debug("Local conductor send: \(event.kind.displayName, privacy: .public)")
        }
        switch event.kind {
        case .userAudioTranscriptFinal(let final):
            let events = await conductor.handleTranscript(final.text)
            for outbound in events {
                continuation.yield(Event(
                    id: outbound.id,
                    timestamp: outbound.timestamp,
                    sessionId: sessionId ?? outbound.sessionId,
                    kind: outbound.kind
                ))
            }
            AppLogger.conductor.debug("Local conductor yielded \(events.count, privacy: .public) events")
        default:
            break
        }
    }
}
