import XCTest

@testable import OsaurusFetch

final class SSRFTests: XCTestCase {

    // MARK: isPrivateIPv4

    func test_isPrivateIPv4_blocksLoopback() {
        XCTAssertTrue(isPrivateIPv4("127.0.0.1"))
        XCTAssertTrue(isPrivateIPv4("127.255.255.254"))
    }

    func test_isPrivateIPv4_blocksRFC1918() {
        XCTAssertTrue(isPrivateIPv4("10.0.0.1"))
        XCTAssertTrue(isPrivateIPv4("10.255.255.255"))
        XCTAssertTrue(isPrivateIPv4("172.16.0.1"))
        XCTAssertTrue(isPrivateIPv4("172.31.255.255"))
        XCTAssertTrue(isPrivateIPv4("192.168.0.1"))
    }

    func test_isPrivateIPv4_blocksLinkLocal() {
        XCTAssertTrue(isPrivateIPv4("169.254.169.254"))  // AWS metadata
    }

    func test_isPrivateIPv4_blocksMulticastAndReserved() {
        XCTAssertTrue(isPrivateIPv4("224.0.0.1"))
        XCTAssertTrue(isPrivateIPv4("240.0.0.1"))
        XCTAssertTrue(isPrivateIPv4("255.255.255.255"))
    }

    func test_isPrivateIPv4_allowsPublicAddresses() {
        XCTAssertFalse(isPrivateIPv4("8.8.8.8"))
        XCTAssertFalse(isPrivateIPv4("1.1.1.1"))
        XCTAssertFalse(isPrivateIPv4("172.32.0.1"))  // just outside 172.16/12
        XCTAssertFalse(isPrivateIPv4("9.255.255.255"))
        XCTAssertFalse(isPrivateIPv4("11.0.0.0"))
    }

    func test_isPrivateIPv4_returnsFalseForGarbage() {
        XCTAssertFalse(isPrivateIPv4("not-an-ip"))
        XCTAssertFalse(isPrivateIPv4("1.2.3"))
        XCTAssertFalse(isPrivateIPv4("1.2.3.4.5"))
        XCTAssertFalse(isPrivateIPv4("256.0.0.1"))
    }

    // MARK: isReservedIPv6

    func test_isReservedIPv6_blocksLoopback() {
        XCTAssertTrue(isReservedIPv6("::1"))
    }

    func test_isReservedIPv6_blocksLinkLocal() {
        XCTAssertTrue(isReservedIPv6("fe80::1"))
        XCTAssertTrue(isReservedIPv6("FE80::ABCD"))  // case insensitive
    }

    func test_isReservedIPv6_blocksUniqueLocal() {
        XCTAssertTrue(isReservedIPv6("fc00::1"))
        XCTAssertTrue(isReservedIPv6("fd12:3456::1"))
    }

    func test_isReservedIPv6_blocksMulticast() {
        XCTAssertTrue(isReservedIPv6("ff02::1"))
    }

    func test_isReservedIPv6_allowsPublicAddresses() {
        XCTAssertFalse(isReservedIPv6("2001:4860:4860::8888"))  // Google DNS
        XCTAssertFalse(isReservedIPv6("2606:4700:4700::1111"))  // Cloudflare
    }

    // MARK: checkSSRF

    func test_checkSSRF_allowsPublicHttpsURL() {
        let url = URL(string: "https://example.com")!
        let result = checkSSRF(url: url, allowPrivate: false)
        XCTAssertTrue(result.allowed)
    }

    func test_checkSSRF_blocksLiteralPrivateIPv4() {
        let url = URL(string: "http://192.168.1.1/admin")!
        let result = checkSSRF(url: url, allowPrivate: false)
        XCTAssertFalse(result.allowed)
        XCTAssertNotNil(result.reason)
    }

    func test_checkSSRF_blocksLocalhostHostname() {
        let url = URL(string: "http://localhost:8080/")!
        let result = checkSSRF(url: url, allowPrivate: false)
        XCTAssertFalse(result.allowed)
    }

    func test_checkSSRF_blocksDotLocal() {
        let url = URL(string: "http://printer.local/")!
        let result = checkSSRF(url: url, allowPrivate: false)
        XCTAssertFalse(result.allowed)
    }

    func test_checkSSRF_blocksAWSMetadataHostname() {
        let url = URL(string: "http://metadata.amazonaws.com/")!
        let result = checkSSRF(url: url, allowPrivate: false)
        XCTAssertFalse(result.allowed)
    }

    func test_checkSSRF_blocksFileScheme() {
        let url = URL(string: "file:///etc/passwd")!
        let result = checkSSRF(url: url, allowPrivate: false)
        XCTAssertFalse(result.allowed)
    }

    func test_checkSSRF_allowPrivateBypassesAllChecks() {
        let url = URL(string: "http://127.0.0.1/")!
        let result = checkSSRF(url: url, allowPrivate: true)
        XCTAssertTrue(result.allowed)
    }

    // MARK: shared policy adoption

    func test_enforceSSRF_blocksUnsafeSchemeEvenWhenPrivateAllowed() {
        let url = URL(string: "file:///etc/passwd")!
        XCTAssertThrowsError(try enforceSSRF(url, allowPrivate: true)) { error in
            guard let toolError = error as? ToolError else {
                return XCTFail("expected ToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, "UNSAFE_SCHEME")
        }
    }

    func test_enforceSSRF_blocksMetadataEvenWhenPrivateAllowed() {
        let url = URL(string: "http://169.254.169.254/latest/meta-data/")!
        XCTAssertThrowsError(try enforceSSRF(url, allowPrivate: true)) { error in
            guard let toolError = error as? ToolError else {
                return XCTFail("expected ToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, "SSRF_BLOCKED")
            XCTAssertTrue(toolError.message.contains("metadata"))
        }
    }

    func test_enforceSSRF_rejectsURLUserInfo() {
        let url = URL(string: "https://user:pass@example.com/")!
        XCTAssertThrowsError(try enforceSSRF(url, allowPrivate: false)) { error in
            guard let toolError = error as? ToolError else {
                return XCTFail("expected ToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, "SECRET_IN_URL")
        }
    }

    func test_safeHeaders_redactsSensitiveValues() {
        let redacted = safeHeaders([
            "Authorization": "Bearer secret-token",
            "X-Request-ID": "abc",
            "Cookie": "session=abc",
        ])
        XCTAssertEqual(redacted["Authorization"], "<redacted>")
        XCTAssertEqual(redacted["Cookie"], "<redacted>")
        XCTAssertEqual(redacted["X-Request-ID"], "abc")
    }

    func test_safeURLString_redactsQueryAndFragmentSecrets() {
        let redacted = safeURLString("https://example.com/path?token=abc#access_token=xyz")
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertFalse(redacted.contains("xyz"))
        XCTAssertTrue(redacted.contains("token=REDACTED"))
    }

    func test_parseURL_redactsInvalidInputInErrorMessage() {
        XCTAssertThrowsError(try parseURL("https://example .com/path?token=secret-value")) { error in
            guard let toolError = error as? ToolError else {
                return XCTFail("expected ToolError, got \(error)")
            }
            XCTAssertEqual(toolError.code, "INVALID_ARGS")
            XCTAssertFalse(toolError.message.contains("secret-value"))
            XCTAssertTrue(toolError.message.contains("token=REDACTED"))
        }
    }

    func test_safeBodyFields_redactsTextAndBase64Mirror() throws {
        let fields = safeBodyFields(Data("Authorization: Bearer secret12345".utf8))
        XCTAssertTrue(fields.redacted)
        XCTAssertFalse(fields.body.contains("secret12345"))
        let decoded = try XCTUnwrap(String(data: try XCTUnwrap(Data(base64Encoded: fields.bodyBase64)), encoding: .utf8))
        XCTAssertEqual(decoded, fields.body)
    }

    func test_safeJSONValue_redactsSensitiveKeysAndStringLeaves() throws {
        let input: [String: Any] = [
            "access_token": "secret-value",
            "profile": [
                "name": "Ada",
                "callback": "https://example.com/callback?token=secret-value",
            ],
            "items": [
                ["api_key": "secret-value"],
                "Authorization: Bearer secret12345",
            ],
        ]

        let safe = safeJSONValue(input)
        XCTAssertTrue(safe.redacted)
        let output = try XCTUnwrap(safe.value as? [String: Any])
        XCTAssertEqual(output["access_token"] as? String, "REDACTED")
        XCTAssertFalse(String(describing: output).contains("secret-value"))
        XCTAssertFalse(String(describing: output).contains("secret12345"))
        XCTAssertTrue(String(describing: output).contains("token=REDACTED"))
    }
}
