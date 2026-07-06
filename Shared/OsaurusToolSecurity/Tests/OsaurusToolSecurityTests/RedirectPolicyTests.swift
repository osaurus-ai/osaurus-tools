import XCTest

@testable import OsaurusToolSecurity

final class RedirectPolicyTests: XCTestCase {
    private func redirectPolicy(resolutions: [String: [String]] = [:]) -> RedirectPolicy {
        RedirectPolicy(urlPolicy: URLPolicy { host in
            resolutions[host] ?? ["93.184.216.34"]
        })
    }

    func testRedirectTargetReRunsPolicyAndBlocksPrivateHop() {
        assertRejectedRedirect(
            from: "https://example.com/start",
            to: "http://192.168.1.1/admin",
            code: .ssrfBlocked
        )
    }

    func testRedirectTargetBlocksMetadataEvenWithPrivateAccessAllowed() {
        assertRejectedRedirect(
            from: "https://example.com/start",
            to: "http://169.254.169.254/latest/meta-data/",
            code: .ssrfBlocked,
            options: .init(allowPrivateNetwork: true)
        )
    }

    func testSameOriginRedirectKeepsHeaders() throws {
        let decision = try redirectPolicy().evaluate(
            from: URL(string: "https://example.com/start")!,
            to: URL(string: "https://example.com/next")!,
            headers: ["Authorization": "Bearer abc", "Accept": "application/json"]
        )
        XCTAssertFalse(decision.strippedSensitiveHeaders)
        XCTAssertEqual(decision.headers["Authorization"], "Bearer abc")
        XCTAssertEqual(decision.headers["Accept"], "application/json")
    }

    func testCrossOriginRedirectStripsSensitiveHeaders() throws {
        let decision = try redirectPolicy().evaluate(
            from: URL(string: "https://example.com/start")!,
            to: URL(string: "https://other.example/next")!,
            headers: [
                "Authorization": "Bearer abc",
                "Cookie": "session=abc",
                "X-Api-Key": "secret",
                "Accept": "application/json",
            ]
        )
        XCTAssertTrue(decision.strippedSensitiveHeaders)
        XCTAssertNil(decision.headers["Authorization"])
        XCTAssertNil(decision.headers["Cookie"])
        XCTAssertNil(decision.headers["X-Api-Key"])
        XCTAssertEqual(decision.headers["Accept"], "application/json")
    }

    func testHTTPSDowngradeStripsSensitiveHeaders() throws {
        let decision = try redirectPolicy().evaluate(
            from: URL(string: "https://example.com/start")!,
            to: URL(string: "http://example.com/next")!,
            headers: ["Authorization": "Bearer abc", "User-Agent": "Osaurus"]
        )
        XCTAssertTrue(decision.strippedSensitiveHeaders)
        XCTAssertNil(decision.headers["Authorization"])
        XCTAssertEqual(decision.headers["User-Agent"], "Osaurus")
    }

    private func assertRejectedRedirect(
        from current: String,
        to target: String,
        code: WebSafetyErrorCode,
        options: URLPolicyOptions = URLPolicyOptions(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try redirectPolicy().evaluate(
                from: URL(string: current)!,
                to: URL(string: target)!,
                headers: ["Authorization": "Bearer abc"],
                options: options
            )
            XCTFail("Expected redirect to \(target) to be rejected", file: file, line: line)
        } catch let error as WebSafetyError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
