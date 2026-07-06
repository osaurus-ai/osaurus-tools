import XCTest

@testable import OsaurusToolSecurity

final class URLPolicyTests: XCTestCase {
    private func policy(resolutions: [String: [String]] = [:]) -> URLPolicy {
        URLPolicy { host in
            resolutions[host] ?? ["93.184.216.34"]
        }
    }

    func testAllowsPublicHTTPSURL() throws {
        let decision = try policy().validate("https://example.com/path?q=search")
        XCTAssertEqual(decision.host, "example.com")
        XCTAssertEqual(decision.resolvedAddresses, ["93.184.216.34"])
        XCTAssertTrue(decision.warnings.isEmpty)
    }

    func testRejectsUnsafeSchemesEvenWhenPrivateAccessIsAllowed() {
        for rawURL in ["file:///etc/passwd", "data:text/plain,hello", "javascript:alert(1)"] {
            assertRejected(rawURL, code: .unsafeScheme, options: .init(allowPrivateNetwork: true))
        }
    }

    func testAboutBlankRequiresExplicitOptIn() throws {
        assertRejected("about:blank", code: .unsafeScheme)

        let decision = try policy().validate("about:blank", options: .init(allowAboutBlank: true))
        XCTAssertTrue(decision.isAboutBlank)
    }

    func testRejectsUserInfoAsSecretInURL() {
        assertRejected("https://user:pass@example.com/path", code: .secretInURL)
        assertRejected("http://169.254.169.254@expected.com/", code: .secretInURL)
        assertRejected("http://expected.com@169.254.169.254/", code: .secretInURL)
    }

    func testBlocksLocalhostAndPrivateIPv4ByDefault() {
        assertRejected("http://localhost:8080/", code: .ssrfBlocked)
        assertRejected("http://127.0.0.1/", code: .ssrfBlocked)
        assertRejected("http://10.0.0.1/", code: .ssrfBlocked)
        assertRejected("http://172.16.0.1/", code: .ssrfBlocked)
        assertRejected("http://192.168.1.1/", code: .ssrfBlocked)
        assertRejected("http://0.0.0.0/", code: .ssrfBlocked)
    }

    func testBlocksLocalAndInternalHostnamesByDefault() {
        assertRejected("http://printer.local/", code: .ssrfBlocked)
        assertRejected("http://service.internal./", code: .ssrfBlocked)
        assertRejected("http://%6cocalhost/", code: .ssrfBlocked)
        assertRejected("http://LOCALHOST/", code: .ssrfBlocked)
    }

    func testAllowsPrivateNetworkWhenExplicitlyEnabledExceptMetadata() throws {
        let decision = try policy().validate(
            "http://192.168.1.1/admin",
            options: .init(allowPrivateNetwork: true)
        )
        XCTAssertEqual(decision.host, "192.168.1.1")
    }

    func testBlocksMetadataHostnamesEvenWhenPrivateAccessIsAllowed() {
        let options = URLPolicyOptions(allowPrivateNetwork: true)
        assertRejected("http://metadata.google.internal/", code: .ssrfBlocked, options: options)
        assertRejected("http://metadata.amazonaws.com/", code: .ssrfBlocked, options: options)
        assertRejected("http://instance-data.ec2.internal/", code: .ssrfBlocked, options: options)
    }

    func testBlocksMetadataIPv4EncodingsEvenWhenPrivateAccessIsAllowed() {
        let options = URLPolicyOptions(allowPrivateNetwork: true)
        assertRejected("http://169.254.169.254/", code: .ssrfBlocked, options: options)
        assertRejected("http://2852039166/", code: .ssrfBlocked, options: options)
        assertRejected("http://0xa9fea9fe/", code: .ssrfBlocked, options: options)
        assertRejected("http://025177524776/", code: .ssrfBlocked, options: options)
        assertRejected("http://169.254.43518/", code: .ssrfBlocked, options: options)
        assertRejected("http://100.100.100.200/", code: .ssrfBlocked, options: options)
    }

    func testBlocksNonDottedLoopbackIPv4Forms() {
        assertRejected("http://2130706433/", code: .ssrfBlocked)
        assertRejected("http://0x7f000001/", code: .ssrfBlocked)
        assertRejected("http://017700000001/", code: .ssrfBlocked)
        assertRejected("http://127.1/", code: .ssrfBlocked)
    }

    func testBlocksIPv6LoopbackLinkLocalULAAndMetadataForms() {
        assertRejected("http://[::1]/", code: .ssrfBlocked)
        assertRejected("http://[fe80::1%25en0]/", code: .ssrfBlocked)
        assertRejected("http://[fd12:3456::1]/", code: .ssrfBlocked)
        assertRejected("http://[::ffff:169.254.169.254]/", code: .ssrfBlocked)
        assertRejected("http://[64:ff9b::a9fe:a9fe]/", code: .ssrfBlocked)
        assertRejected("http://[2002:a9fe:a9fe::1]/", code: .ssrfBlocked)
        assertRejected("http://[2001:0000:0808:0808:0000:0000:5601:5601]/", code: .ssrfBlocked)
    }

    func testBlocksResolvedPrivateAddressesByDefault() {
        let guarded = policy(resolutions: ["public.example": ["93.184.216.34", "192.168.1.10"]])
        assertRejected("https://public.example/", code: .ssrfBlocked, policy: guarded)
    }

    func testBlocksHostnameWhenResolutionFailsClosed() {
        let guarded = URLPolicy { _ in [] }
        assertRejected("https://unresolved.example/", code: .ssrfBlocked, policy: guarded)
    }

    func testAllowsResolvedPrivateAddressWithPrivateAccessButStillBlocksResolvedMetadata() throws {
        let guarded = policy(resolutions: [
            "private.example": ["192.168.1.10"],
            "metadata.example": ["169.254.169.254"],
        ])

        _ = try guarded.validate(
            "https://private.example/",
            options: .init(allowPrivateNetwork: true)
        )
        assertRejected(
            "https://metadata.example/",
            code: .ssrfBlocked,
            options: .init(allowPrivateNetwork: true),
            policy: guarded
        )
    }

    func testSignedCloudQueryStringsAreRedactedButNotRejected() throws {
        let decision = try policy().validate(
            "https://storage.googleapis.com/bucket/object?X-Goog-Signature=abc123&X-Goog-Credential=issuer&q=benign"
        )
        XCTAssertTrue(decision.warnings.contains("credential-looking URL components were redacted"))
        XCTAssertTrue(decision.redactedURL.contains("X-Goog-Signature=REDACTED"))
        XCTAssertTrue(decision.redactedURL.contains("X-Goog-Credential=REDACTED"))
        XCTAssertTrue(decision.redactedURL.contains("q=benign"))
    }

    func testPercentDecodedSecretPrefixesAreRedactedButNotRejected() throws {
        let decision = try policy().validate("https://example.com/callback?next=sk-%255Fsecret-value")
        XCTAssertTrue(decision.redactedURL.contains("next=REDACTED"))
        XCTAssertTrue(decision.warnings.contains("credential-looking URL components were redacted"))
    }

    private func assertRejected(
        _ rawURL: String,
        code: WebSafetyErrorCode,
        options: URLPolicyOptions = URLPolicyOptions(),
        policy: URLPolicy? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let guarded = policy ?? self.policy()
        do {
            _ = try guarded.validate(rawURL, options: options)
            XCTFail("Expected \(rawURL) to be rejected", file: file, line: line)
        } catch let error as WebSafetyError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
