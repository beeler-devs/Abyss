import XCTest
@testable import Abyss

final class WhisperKitSpeechTranscriberTests: XCTestCase {

    func testNormalizeTranscriptCollapsesWhitespace() {
        XCTAssertEqual(
            WhisperKitSpeechTranscriber.normalizeTranscript("  hello\n\n   world\tagain  "),
            "hello world again"
        )
    }

    func testMergePartialTranscriptUsesOverlap() {
        XCTAssertEqual(
            WhisperKitSpeechTranscriber.mergePartialTranscript(
                existing: "please open the repository list",
                trailing: "repository list and show the latest one"
            ),
            "please open the repository list and show the latest one"
        )
    }

    func testMergePartialTranscriptKeepsExistingWhenTrailingContained() {
        XCTAssertEqual(
            WhisperKitSpeechTranscriber.mergePartialTranscript(
                existing: "show me the connected repositories",
                trailing: "connected repositories"
            ),
            "show me the connected repositories"
        )
    }
}
