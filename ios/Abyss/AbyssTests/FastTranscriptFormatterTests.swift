import XCTest
@testable import Abyss

final class FastTranscriptFormatterTests: XCTestCase {
    private let formatter = FastTranscriptFormatter()

    func testNormalizesFillersAndCapitalization() {
        let output = formatter.normalizeForAgent("  um i need help fixing this bug  ")
        XCTAssertEqual(output, "I need help fixing this bug.")
    }

    func testNormalizesSpokenGithubDomain() {
        let output = formatter.normalizeForAgent("please review github dot com example repo")
        XCTAssertTrue(output.contains("github.com"))
        XCTAssertTrue(output.hasSuffix("."))
    }
}
