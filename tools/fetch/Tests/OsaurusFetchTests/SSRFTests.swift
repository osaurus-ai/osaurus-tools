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
}
