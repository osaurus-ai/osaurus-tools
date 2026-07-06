import XCTest

@testable import OsaurusToolSecurity

final class RedactionTests: XCTestCase {
    func testRedactsURLUserInfoAndCredentialQueries() {
        let result = WebSafetyRedactor.redactURL(
            "https://user:pass@example.com/path?token=abc123&q=visible"
        )
        XCTAssertTrue(result.redacted)
        XCTAssertEqual(result.value, "https://example.com/path?token=REDACTED&q=visible")
    }

    func testDoesNotRedactBenignQuery() {
        let result = WebSafetyRedactor.redactURL("https://example.com/search?q=osaurus&page=1")
        XCTAssertFalse(result.redacted)
        XCTAssertEqual(result.value, "https://example.com/search?q=osaurus&page=1")
    }

    func testContainsCredentialsInURL() {
        XCTAssertTrue(WebSafetyRedactor.containsCredentials(inURL: "https://example.com/?api_key=abc"))
        XCTAssertFalse(WebSafetyRedactor.containsCredentials(inURL: "https://example.com/?q=abc"))
    }

    func testRedactsSignedCloudURLParameters() {
        let result = WebSafetyRedactor.redactURL(
            "https://s3.amazonaws.com/bucket/file?X-Amz-Signature=sig&X-Amz-Credential=cred&Expires=123"
        )
        XCTAssertTrue(result.redacted)
        XCTAssertTrue(result.value.contains("X-Amz-Signature=REDACTED"))
        XCTAssertTrue(result.value.contains("X-Amz-Credential=REDACTED"))
        XCTAssertTrue(result.value.contains("Expires=123"))
    }

    func testRedactsCredentialFragments() {
        let result = WebSafetyRedactor.redactURL(
            "https://example.com/callback#access_token=abc123&id_token=jwt-value&state=visible"
        )
        XCTAssertTrue(result.redacted)
        XCTAssertFalse(result.value.contains("abc123"))
        XCTAssertFalse(result.value.contains("jwt-value"))
        XCTAssertTrue(result.value.contains("access_token=REDACTED"))
        XCTAssertTrue(result.value.contains("id_token=REDACTED"))
        XCTAssertTrue(result.value.contains("state=visible"))
    }

    func testRedactsPercentDecodedSecretPrefixesInURLValues() {
        let result = WebSafetyRedactor.redactURL("https://example.com/?continue=ghp_%255Fsecret")
        XCTAssertTrue(result.redacted)
        XCTAssertTrue(result.value.contains("continue=REDACTED"))
    }

    func testHeaderRedactionCoversCredentialHeadersCaseInsensitively() {
        let result = WebSafetyRedactor.redactHeaders([
            "Authorization": "Bearer token",
            "Cookie": "session=abc",
            "Set-Cookie": "session=abc; Path=/",
            "Proxy-Authorization": "Basic abc",
            "X-Api-Key": "secret",
            "X_Api_Key": "secret",
            "Accept": "application/json",
        ])
        XCTAssertTrue(result.redacted)
        XCTAssertEqual(result.value["Authorization"], "<redacted>")
        XCTAssertEqual(result.value["Cookie"], "<redacted>")
        XCTAssertEqual(result.value["Set-Cookie"], "<redacted>")
        XCTAssertEqual(result.value["Proxy-Authorization"], "<redacted>")
        XCTAssertEqual(result.value["X-Api-Key"], "<redacted>")
        XCTAssertEqual(result.value["X_Api_Key"], "<redacted>")
        XCTAssertEqual(result.value["Accept"], "application/json")
    }

    func testCookieRedactionRemovesCookieValuesButKeepsAttributes() {
        let result = WebSafetyRedactor.redactCookieHeader(
            "session=abc123; theme=dark; Path=/; HttpOnly; SameSite=Lax"
        )
        XCTAssertTrue(result.redacted)
        XCTAssertEqual(
            result.value,
            "session=<redacted>; theme=<redacted>; Path=/; HttpOnly; SameSite=Lax"
        )
    }

    func testTextRedactionCoversCredentialURLsHeadersAndPairs() {
        let text = """
        GET https://example.com/callback?access_token=abc123&q=ok
        Authorization: Bearer secret-token-value
        api_key=plain-secret
        """
        let result = WebSafetyRedactor.redactText(text)
        XCTAssertTrue(result.redacted)
        XCTAssertFalse(result.value.contains("abc123"))
        XCTAssertFalse(result.value.contains("secret-token-value"))
        XCTAssertFalse(result.value.contains("plain-secret"))
        XCTAssertTrue(result.value.contains("access_token=REDACTED"))
        XCTAssertTrue(result.value.contains("Authorization: <redacted>"))
        XCTAssertTrue(result.value.contains("api_key=REDACTED"))
    }
}
