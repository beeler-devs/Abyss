import XCTest
@testable import Abyss

@MainActor
final class EventBusTests: XCTestCase {

    func testAppendOnlyOrdering() {
        let bus = EventBus()

        bus.emit(Event.sessionStart())
        bus.emit(Event.transcriptPartial("Hello"))
        bus.emit(Event.transcriptFinal("Hello world"))

        XCTAssertEqual(bus.events.count, 3)

        // Verify ordering
        switch bus.events[0].kind {
        case .sessionStart: break
        default: XCTFail("First event should be sessionStart")
        }

        switch bus.events[1].kind {
        case .userAudioTranscriptPartial(let p):
            XCTAssertEqual(p.text, "Hello")
        default: XCTFail("Second event should be transcriptPartial")
        }

        switch bus.events[2].kind {
        case .userAudioTranscriptFinal(let f):
            XCTAssertEqual(f.text, "Hello world")
        default: XCTFail("Third event should be transcriptFinal")
        }
    }

    func testBatchEmit() {
        let bus = EventBus()

        bus.emit([
            Event.sessionStart(),
            Event.transcriptFinal("test"),
            Event.speechFinal("response"),
        ])

        XCTAssertEqual(bus.events.count, 3)
    }

    func testReplay() {
        let bus = EventBus()

        bus.emit(Event.sessionStart())
        bus.emit(Event.transcriptFinal("hello"))

        let replayed = bus.replay()
        XCTAssertEqual(replayed.count, 2)
        XCTAssertEqual(replayed[0].id, bus.events[0].id)
        XCTAssertEqual(replayed[1].id, bus.events[1].id)
    }

    func testReset() {
        let bus = EventBus()
        bus.emit(Event.sessionStart())
        XCTAssertEqual(bus.events.count, 1)

        bus.reset()
        XCTAssertEqual(bus.events.count, 0)
    }

    func testTimestampOrdering() {
        let bus = EventBus()
        bus.emit(Event.sessionStart())
        bus.emit(Event.transcriptFinal("test"))

        XCTAssertTrue(bus.events[0].timestamp <= bus.events[1].timestamp)
    }
}
