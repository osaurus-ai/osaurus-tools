import XCTest
import OsaurusToolSecurity

@testable import OsaurusBrowser

final class BrowserURLPolicyTests: XCTestCase {
    func test_validateBrowserNavigationURL_allowsPublicHTTPS() throws {
        let decision = try allowed("https://example.com/")
        XCTAssertEqual(decision.url.scheme, "https")
    }

    func test_validateBrowserNavigationURL_allowsAboutBlankExplicitly() throws {
        let decision = try allowed("about:blank")
        XCTAssertTrue(decision.isAboutBlank)
    }

    func test_validateBrowserNavigationURL_blocksFileScheme() {
        assertBlocked("file:///etc/passwd", contains: "Only http and https")
    }

    func test_validateBrowserNavigationURL_blocksMetadataEvenWhenEncoded() {
        assertBlocked("http://2852039166/latest/meta-data/", contains: "metadata")
    }

    func test_validateBrowserNavigationURL_blocksUserInfo() {
        assertBlocked("https://user:pass@example.com/", contains: "userinfo")
    }

    private func allowed(_ raw: String) throws -> URLPolicyDecision {
        switch validateBrowserNavigationURL(raw) {
        case .success(let decision):
            return decision
        case .failure(let failure):
            throw NSError(domain: "BrowserURLPolicyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.message])
        }
    }

    private func assertBlocked(_ raw: String, contains expected: String, file: StaticString = #file, line: UInt = #line) {
        switch validateBrowserNavigationURL(raw) {
        case .success:
            XCTFail("expected URL to be blocked: \(raw)", file: file, line: line)
        case .failure(let failure):
            XCTAssertTrue(
                failure.message.lowercased().contains(expected.lowercased()),
                "message did not contain \(expected): \(failure.message)",
                file: file,
                line: line
            )
        }
    }
}
