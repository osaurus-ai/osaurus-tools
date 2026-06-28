import XCTest

@testable import OsaurusBrowser

/// Tests for `normalizeBrowserResult`, the single dispatch-boundary that
/// rewrites non-canonical tool errors into the Osaurus failure envelope.
///
/// The host treats any result that is not shaped like `{"ok": false, ...}` as a
/// SUCCESS, so bare `{"error": ...}` objects and `"Error: ..."` strings were
/// previously reported to the model as successful tool calls.
final class NormalizeResultTests: XCTestCase {

    private func parse(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func test_bareErrorObjectBecomesFailureEnvelope() throws {
        let out = normalizeBrowserResult("{\"error\": \"Invalid arguments. Required: url\"}")
        let dict = try XCTUnwrap(parse(out))
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "invalid_args")
        XCTAssertEqual(dict["retryable"] as? Bool, true)
        XCTAssertEqual(dict["message"] as? String, "Invalid arguments. Required: url")
    }

    func test_nestedErrorObjectUsesItsMessage() throws {
        let out = normalizeBrowserResult(
            "{\"error\": {\"code\": \"X\", \"message\": \"boom happened\"}}")
        let dict = try XCTUnwrap(parse(out))
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "execution_error")
        XCTAssertEqual(dict["message"] as? String, "boom happened")
    }

    func test_plainErrorStringBecomesFailureEnvelope() throws {
        let out = normalizeBrowserResult("Error: something went wrong")
        let dict = try XCTUnwrap(parse(out))
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "execution_error")
        XCTAssertEqual(dict["message"] as? String, "something went wrong")
    }

    func test_canonicalSuccessEnvelopeUntouched() {
        let input = "{\"data\":{\"x\":1},\"ok\":true}"
        XCTAssertEqual(normalizeBrowserResult(input), input)
    }

    func test_canonicalFailureEnvelopeUntouched() {
        let input = "{\"error\":{\"code\":\"X\",\"message\":\"y\"},\"ok\":false}"
        XCTAssertEqual(normalizeBrowserResult(input), input)
    }

    func test_plainSuccessTextUntouched() {
        let input = "- heading\n  - button \"OK\""
        XCTAssertEqual(normalizeBrowserResult(input), input)
    }
}
