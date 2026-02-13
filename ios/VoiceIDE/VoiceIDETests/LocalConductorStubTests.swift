import XCTest
@testable import VoiceIDE

final class LocalConductorStubTests: XCTestCase {

    func testDeterministicOutput() async {
        let conductor = LocalConductorStub()
        let transcript = "Hello"

        let events1 = await conductor.handleTranscript(transcript)
        let events2 = await conductor.handleTranscript(transcript)

        // Same input should produce same number of events
        XCTAssertEqual(events1.count, events2.count)

        // Same tool call names in same order
        let names1 = events1.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.name }
            return nil
        }
        let names2 = events2.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.name }
            return nil
        }
        XCTAssertEqual(names1, names2)

        // Same call IDs (deterministic hashing)
        let ids1 = events1.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.callId }
            return nil
        }
        let ids2 = events2.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.callId }
            return nil
        }
        XCTAssertEqual(ids1, ids2)
    }

    func testEventSequenceStructure() async {
        let conductor = LocalConductorStub()
        let events = await conductor.handleTranscript("test")

        // Expected: setState(thinking), appendMessage(user), speechFinal,
        //           appendMessage(assistant), setState(speaking), tts.speak, setState(idle)
        XCTAssertEqual(events.count, 7)

        // 1. Set state to thinking
        if case .toolCall(let tc) = events[0].kind {
            XCTAssertEqual(tc.name, "convo.setState")
            XCTAssertTrue(tc.arguments.contains("thinking"))
        } else {
            XCTFail("Event 0 should be convo.setState(thinking)")
        }

        // 2. Append user message
        if case .toolCall(let tc) = events[1].kind {
            XCTAssertEqual(tc.name, "convo.appendMessage")
            XCTAssertTrue(tc.arguments.contains("user"))
        } else {
            XCTFail("Event 1 should be convo.appendMessage(user)")
        }

        // 3. Speech final
        if case .assistantSpeechFinal(let sf) = events[2].kind {
            XCTAssertFalse(sf.text.isEmpty)
        } else {
            XCTFail("Event 2 should be assistantSpeechFinal")
        }

        // 4. Append assistant message
        if case .toolCall(let tc) = events[3].kind {
            XCTAssertEqual(tc.name, "convo.appendMessage")
            XCTAssertTrue(tc.arguments.contains("assistant"))
        } else {
            XCTFail("Event 3 should be convo.appendMessage(assistant)")
        }

        // 5. Set state to speaking
        if case .toolCall(let tc) = events[4].kind {
            XCTAssertEqual(tc.name, "convo.setState")
            XCTAssertTrue(tc.arguments.contains("speaking"))
        } else {
            XCTFail("Event 4 should be convo.setState(speaking)")
        }

        // 6. TTS speak
        if case .toolCall(let tc) = events[5].kind {
            XCTAssertEqual(tc.name, "tts.speak")
        } else {
            XCTFail("Event 5 should be tts.speak")
        }

        // 7. Set state to idle
        if case .toolCall(let tc) = events[6].kind {
            XCTAssertEqual(tc.name, "convo.setState")
            XCTAssertTrue(tc.arguments.contains("idle"))
        } else {
            XCTFail("Event 6 should be convo.setState(idle)")
        }
    }

    func testSessionStartEvent() async {
        let conductor = LocalConductorStub()
        let events = await conductor.handleSessionStart()

        XCTAssertEqual(events.count, 1)
        if case .sessionStart = events[0].kind {
            // OK
        } else {
            XCTFail("Should emit session.start")
        }
    }

    func testDifferentInputsProduceDifferentCallIds() async {
        let conductor = LocalConductorStub()

        let events1 = await conductor.handleTranscript("Hello")
        let events2 = await conductor.handleTranscript("Goodbye")

        let ids1 = events1.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.callId }
            return nil
        }
        let ids2 = events2.compactMap { event -> String? in
            if case .toolCall(let tc) = event.kind { return tc.callId }
            return nil
        }

        // Different inputs should produce different call IDs
        XCTAssertNotEqual(ids1, ids2)
    }

    func testKnownResponseForHello() async {
        let conductor = LocalConductorStub()
        let events = await conductor.handleTranscript("Hello")

        // The speech final should contain the hello response
        let speechEvents = events.compactMap { event -> String? in
            if case .assistantSpeechFinal(let sf) = event.kind { return sf.text }
            return nil
        }
        XCTAssertEqual(speechEvents.count, 1)
        XCTAssertTrue(speechEvents[0].contains("Hello"))
    }
}
