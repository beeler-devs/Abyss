import Testing
@testable import SwiftProtocol

@Test("Event envelope defaults protocol version")
func eventEnvelopeDefaultsProtocolVersion() {
    let envelope = EventEnvelope(
        id: "evt-1",
        type: "session.start",
        sessionId: "session-1",
        payload: .object(["sessionId": .string("session-1")])
    )

    #expect(envelope.protocolVersion == AbyssProtocol.version)
}
