import XCTest
@testable import Abyss

@MainActor
final class WebSocketConductorClientTests: XCTestCase {

    func testReconnectDeduplicatesInboundEventIDs() async throws {
        let transportOne = MockWebSocketTransport()
        let transportTwo = MockWebSocketTransport()
        let factoryQueue = TransportFactoryQueue(queue: [transportOne, transportTwo])
        let factory: @Sendable () -> WebSocketTransport = {
            factoryQueue.nextTransport()
        }

        let client = WebSocketConductorClient(
            backendURL: URL(string: "ws://localhost:8080/ws")!,
            transportFactory: factory,
            reconnectBaseDelayNs: 10_000_000,
            reconnectMaxDelayNs: 40_000_000,
            reconnectJitterRange: 0.0...0.0
        )

        var receivedEvents: [Event] = []
        let collector = Task {
            for await event in client.inboundEvents {
                await MainActor.run {
                    receivedEvents.append(event)
                }
            }
        }

        try await client.connect(sessionId: "session-1", githubToken: nil)

        let duplicateEvent = Event(
            id: "evt-1",
            timestamp: Date(),
            sessionId: "session-1",
            kind: .assistantSpeechPartial(.init(text: "chunk-1"))
        )
        let uniqueEvent = Event(
            id: "evt-2",
            timestamp: Date(),
            sessionId: "session-1",
            kind: .assistantSpeechFinal(.init(text: "final text"))
        )

        transportOne.emitInboundText(try encodeEnvelope(EventEnvelope(event: duplicateEvent)))
        transportOne.emitInboundText(try encodeEnvelope(EventEnvelope(event: duplicateEvent)))

        // Trigger reconnect.
        transportOne.finishInbound()
        try? await Task.sleep(nanoseconds: 90_000_000)

        // Duplicate should be ignored even after reconnect.
        transportTwo.emitInboundText(try encodeEnvelope(EventEnvelope(event: duplicateEvent)))
        transportTwo.emitInboundText(try encodeEnvelope(EventEnvelope(event: uniqueEvent)))

        try? await Task.sleep(nanoseconds: 120_000_000)

        let ids = receivedEvents.map(\.id)
        XCTAssertEqual(ids, ["evt-1", "evt-2"])

        // session.start should be sent on initial connect and reconnect.
        XCTAssertGreaterThanOrEqual(transportOne.sentTexts.count, 1)
        XCTAssertGreaterThanOrEqual(transportTwo.sentTexts.count, 1)

        collector.cancel()
        await client.disconnect()
    }

    func testBridgeExecOutputDeduplicatesRepeatedEventID() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketConductorClient(
            backendURL: URL(string: "ws://localhost:8080/ws")!,
            transportFactory: { transport }
        )

        var receivedEvents: [Event] = []
        let collector = Task {
            for await event in client.inboundEvents {
                await MainActor.run {
                    receivedEvents.append(event)
                }
            }
        }

        try await client.connect(sessionId: "session-1", githubToken: nil)

        let outputEvent = Event(
            id: "evt-bridge-output-1",
            timestamp: Date(),
            sessionId: "session-1",
            kind: .bridgeExecOutput(.init(
                deviceId: "device-1",
                commandId: "cmd-1",
                stream: "stdout",
                chunk: "line\n",
                isFinal: false
            ))
        )

        transport.emitInboundText(try encodeEnvelope(EventEnvelope(event: outputEvent)))
        transport.emitInboundText(try encodeEnvelope(EventEnvelope(event: outputEvent)))
        try? await Task.sleep(nanoseconds: 120_000_000)

        let outputEvents = receivedEvents.filter {
            if case .bridgeExecOutput = $0.kind { return true }
            return false
        }
        XCTAssertEqual(outputEvents.count, 1)

        collector.cancel()
        await client.disconnect()
    }

    func testRememberedInboundEventIDsStayBounded() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketConductorClient(
            backendURL: URL(string: "ws://localhost:8080/ws")!,
            transportFactory: { transport },
            maxRememberedEventIDs: 3
        )

        let collector = Task {
            for await _ in client.inboundEvents {}
        }

        try await client.connect(sessionId: "session-1", githubToken: nil)

        for index in 0..<6 {
            let event = Event(
                id: "evt-\(index)",
                timestamp: Date(),
                sessionId: "session-1",
                kind: .assistantSpeechPartial(.init(text: "chunk-\(index)"))
            )
            transport.emitInboundText(try encodeEnvelope(EventEnvelope(event: event)))
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(client.rememberedInboundEventCount, 3)

        collector.cancel()
        await client.disconnect()
    }

    private func encodeEnvelope(_ envelope: EventEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to encode envelope")
            return "{}"
        }
        return text
    }
}

private final class TransportFactoryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [MockWebSocketTransport]

    init(queue: [MockWebSocketTransport]) {
        self.queue = queue
    }

    func nextTransport() -> WebSocketTransport {
        lock.lock()
        defer { lock.unlock() }

        if queue.isEmpty {
            return MockWebSocketTransport()
        }
        return queue.removeFirst()
    }
}
