import Foundation
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

@Test("Bridge v1 capability defaults are enabled")
func bridgeCapabilitiesDefaults() {
    let capabilities = BridgeCapabilities()

    #expect(capabilities.execRun)
    #expect(capabilities.execStart)
    #expect(capabilities.execCancel)
    #expect(capabilities.fsSearch)
    #expect(capabilities.gitPush)
}

@Test("Bridge exec output event payload is codable")
func bridgeExecOutputPayloadCodable() throws {
    let payload = BridgeExecOutputEventPayload(
        deviceId: "device-1",
        commandId: "cmd-1",
        stream: "stdout",
        chunk: "hello",
        isFinal: false
    )

    let encoded = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(BridgeExecOutputEventPayload.self, from: encoded)

    #expect(decoded.commandId == "cmd-1")
    #expect(decoded.chunk == "hello")
}
