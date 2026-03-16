import XCTest
@testable import Abyss

@MainActor
final class ConversationStoreTests: XCTestCase {

    func testUpsertStreamingMessageAccumulatesDeltaChunksIntoSinglePartial() {
        let store = ConversationStore()

        store.upsertStreamingMessage(role: .assistant, text: "First sentence.")
        store.upsertStreamingMessage(role: .assistant, text: "Second sentence.")

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.role, .assistant)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, true)
    }

    func testUpsertStreamingMessagePrefersGrowingSnapshots() {
        let store = ConversationStore()

        store.upsertStreamingMessage(role: .assistant, text: "First sentence.")
        store.upsertStreamingMessage(role: .assistant, text: "First sentence. Second sentence.")

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, true)
    }

    func testFinalizeLastPartialMessageTurnsPendingAssistantTurnWhite() {
        let store = ConversationStore()

        store.upsertStreamingMessage(role: .assistant, text: "First sentence.")
        store.upsertStreamingMessage(role: .assistant, text: "Second sentence.")
        store.finalizeLastPartialMessage(role: .assistant)

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, false)
    }

    func testLiveResponseIdReplacesExistingPartialInsteadOfAppendingDuplicate() {
        let store = ConversationStore()

        store.append(ConversationMessage(
            role: .assistant,
            text: "First sentence.",
            isPartial: true,
            liveResponseId: "live-1"
        ))
        store.append(ConversationMessage(
            role: .assistant,
            text: "First sentence. Second sentence.",
            isPartial: false,
            liveResponseId: "live-1"
        ))

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "First sentence. Second sentence.")
        XCTAssertEqual(store.messages.first?.isPartial, false)
        XCTAssertEqual(store.messages.first?.liveResponseId, "live-1")
    }

    func testRemovePartialMessageClearsOnlyMatchingLiveResponseDraft() {
        let store = ConversationStore()

        store.append(ConversationMessage(
            role: .assistant,
            text: "Old draft",
            isPartial: true,
            liveResponseId: "live-old"
        ))
        store.append(ConversationMessage(
            role: .assistant,
            text: "Finalized reply",
            isPartial: false,
            liveResponseId: "live-final"
        ))

        store.removePartialMessage(role: .assistant, liveResponseId: "live-old")

        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "Finalized reply")
        XCTAssertEqual(store.messages.first?.isPartial, false)
    }
}
