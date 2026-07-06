import XCTest

@testable import OsaurusSearch

final class ExtractionSafetyTests: XCTestCase {
    func test_extractReadability_blocksUnsafeSchemeWithoutNetwork() {
        let attempt = extractReadability(url: "file:///etc/passwd", timeout: 0.01)
        XCTAssertNil(attempt.data)
        XCTAssertEqual(attempt.errorCode, "UNSAFE_SCHEME")
    }

    func test_extractReadability_blocksMetadataAddressWithoutNetwork() {
        let attempt = extractReadability(url: "http://169.254.169.254/latest/meta-data/", timeout: 0.01)
        XCTAssertNil(attempt.data)
        XCTAssertEqual(attempt.errorCode, "SSRF_BLOCKED")
        XCTAssertTrue(attempt.message?.contains("metadata") ?? false)
    }

    func test_extractReadability_blocksURLUserInfo() {
        let attempt = extractReadability(url: "https://user:pass@example.com/", timeout: 0.01)
        XCTAssertNil(attempt.data)
        XCTAssertEqual(attempt.errorCode, "SECRET_IN_URL")
    }
}
