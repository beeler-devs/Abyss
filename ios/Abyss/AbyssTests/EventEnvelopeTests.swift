import XCTest
@testable import Abyss

final class EventEnvelopeTests: XCTestCase {

    func testRoundTripEncodingAndDecoding() throws {
        let events: [Event] = [
            Event.sessionStart(sessionId: "session-1"),
            Event.transcriptFinal("hello world", sessionId: "session-1"),
            Event.speechPartial("hello", sessionId: "session-1"),
            Event.speechFinal("hello world", sessionId: "session-1"),
            Event.toolCall(name: "convo.setState", arguments: "{\"state\":\"thinking\"}", callId: "call-1", sessionId: "session-1"),
            Event.toolResult(callId: "call-1", result: "{\"ok\":true}", sessionId: "session-1"),
            Event.agentStatus("thinking", detail: "processing", sessionId: "session-1"),
            Event.uiPatch("{\"op\":\"replace\"}", sessionId: "session-1"),
            Event.audioOutputInterrupted("barge_in", sessionId: "session-1"),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for originalEvent in events {
            let envelope = EventEnvelope(event: originalEvent)
            let data = try encoder.encode(envelope)
            let decodedEnvelope = try decoder.decode(EventEnvelope.self, from: data)
            let roundTrippedEvent = try decodedEnvelope.toEvent()

            XCTAssertEqual(roundTrippedEvent.id, originalEvent.id)
            XCTAssertEqual(roundTrippedEvent.sessionId, originalEvent.sessionId)
            XCTAssertEqual(roundTrippedEvent.kind.displayName, originalEvent.kind.displayName)
        }
    }

    func testTranscriptFinalEnvelopeContainsPayloadTimestampAndSession() {
        let event = Event.transcriptFinal("hi", sessionId: "session-abc")
        let envelope = EventEnvelope(event: event)

        XCTAssertEqual(envelope.type, "user.audio.transcript.final")
        XCTAssertEqual(envelope.payload["text"]?.stringValue, "hi")
        XCTAssertEqual(envelope.payload["sessionId"]?.stringValue, "session-abc")
        XCTAssertNotNil(envelope.payload["timestamp"]?.stringValue)
    }

    func testBridgeWorkspaceSetEncodesCorrectly() {
        let event = Event.bridgeWorkspaceSet(deviceId: "dev-1", workspacePath: "/Users/benton/Dev", sessionId: "session-1")
        let envelope = EventEnvelope(event: event)
        XCTAssertEqual(envelope.type, "bridge.workspace.set")
        XCTAssertEqual(envelope.payload["deviceId"]?.stringValue, "dev-1")
        XCTAssertEqual(envelope.payload["workspacePath"]?.stringValue, "/Users/benton/Dev")
    }

    func testBridgePairedDecodesWorkspaceRoot() throws {
        let json = """
        {"id":"abc","type":"bridge.paired","timestamp":"2026-03-15T00:00:00.000Z","protocolVersion":1,"sessionId":"s1","payload":{"deviceId":"dev-1","deviceName":"My Mac","status":"online","workspaceRoot":"/Users/benton/Dev"}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(EventEnvelope.self, from: json)
        let event = try envelope.toEvent()
        guard case .bridgePaired(let paired) = event.kind else { XCTFail("wrong kind"); return }
        XCTAssertEqual(paired.workspaceRoot, "/Users/benton/Dev")
    }

    func testBridgePairedDecodesWithoutWorkspaceRoot() throws {
        let json = """
        {"id":"abc","type":"bridge.paired","timestamp":"2026-03-15T00:00:00.000Z","protocolVersion":1,"sessionId":"s1","payload":{"deviceId":"dev-1","deviceName":"My Mac","status":"online"}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(EventEnvelope.self, from: json)
        let event = try envelope.toEvent()
        guard case .bridgePaired(let paired) = event.kind else { XCTFail("wrong kind"); return }
        XCTAssertNil(paired.workspaceRoot)
    }
}
