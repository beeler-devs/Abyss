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

    func connect(sessionId: String, githubToken: String? = nil) async throws {
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
        print("🔌 [LOCAL-1] LocalConductorClient.send() ENTER — kind=\(event.kind.displayName)")
        switch event.kind {
        case .userAudioTranscriptFinal(let final):
            print("🔌 [LOCAL-2] calling conductor.handleTranscript('\(final.text)')")
            let events = await conductor.handleTranscript(final.text)
            print("🔌 [LOCAL-3] handleTranscript returned \(events.count) events — yielding to inboundEvents stream")
            for (i, outbound) in events.enumerated() {
                print("🔌 [LOCAL-4] yielding event[\(i)]: \(outbound.kind.displayName)")
                continuation.yield(Event(
                    id: outbound.id,
                    timestamp: outbound.timestamp,
                    sessionId: sessionId ?? outbound.sessionId,
                    kind: outbound.kind
                ))
            }
            print("🔌 [LOCAL-5] all \(events.count) events yielded")
        default:
            break
        }
        print("🔌 [LOCAL-6] LocalConductorClient.send() returning")
    }
}
