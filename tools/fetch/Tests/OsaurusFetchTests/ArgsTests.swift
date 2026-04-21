import XCTest

@testable import OsaurusFetch

final class ArgsTests: XCTestCase {

    func test_bodyFromArgs_rejectsMultipleBodies() {
        let raw = #"{"url":"x","body":"a","json_body":{"k":"v"}}"#
        let parsed: CommonRequestArgs = try! decodeArgs(raw)
        XCTAssertThrowsError(try bodyFromArgs(parsed)) { error in
            XCTAssertEqual((error as? ToolError)?.code, "INVALID_ARGS")
        }
    }

    func test_bodyFromArgs_emptyReturnsNone() throws {
        let raw = #"{"url":"x"}"#
        let parsed: CommonRequestArgs = try decodeArgs(raw)
        let body = try bodyFromArgs(parsed)
        if case .none = body {
        } else {
            XCTFail("expected .none, got \(body)")
        }
    }

    func test_bodyFromArgs_rawString() throws {
        let raw = #"{"url":"x","body":"hello"}"#
        let parsed: CommonRequestArgs = try decodeArgs(raw)
        if case .rawString(let s, _) = try bodyFromArgs(parsed) {
            XCTAssertEqual(s, "hello")
        } else {
            XCTFail("expected .rawString")
        }
    }

    func test_bodyFromArgs_jsonBody() throws {
        let raw = #"{"url":"x","json_body":{"k":1}}"#
        let parsed: CommonRequestArgs = try decodeArgs(raw)
        if case .json(let value) = try bodyFromArgs(parsed) {
            let dict = value as? [String: Any]
            XCTAssertEqual(dict?["k"] as? Int, 1)
        } else {
            XCTFail("expected .json")
        }
    }

    func test_bodyFromArgs_form() throws {
        let raw = #"{"url":"x","form":{"a":"1","b":"two"}}"#
        let parsed: CommonRequestArgs = try decodeArgs(raw)
        if case .form(let dict) = try bodyFromArgs(parsed) {
            XCTAssertEqual(dict["a"], "1")
            XCTAssertEqual(dict["b"], "two")
        } else {
            XCTFail("expected .form")
        }
    }

    func test_bodyFromArgs_base64() throws {
        let payload = "hello".data(using: .utf8)!.base64EncodedString()
        let raw = #"{"url":"x","body_base64":"\#(payload)"}"#
        let parsed: CommonRequestArgs = try decodeArgs(raw)
        if case .rawBytes(let data, _) = try bodyFromArgs(parsed) {
            XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
        } else {
            XCTFail("expected .rawBytes")
        }
    }

    func test_bodyFromArgs_invalidBase64Throws() {
        let raw = #"{"url":"x","body_base64":"!!!not base64!!!"}"#
        let parsed: CommonRequestArgs = try! decodeArgs(raw)
        XCTAssertThrowsError(try bodyFromArgs(parsed))
    }

    // MARK: headersFromAuth

    func test_headersFromAuth_bearer() throws {
        let raw = #"{"type":"bearer","token":"abc"}"#
        let auth: AuthHelper = try decodeArgs(raw)
        let headers = try headersFromAuth(auth)
        XCTAssertEqual(headers["Authorization"], "Bearer abc")
    }

    func test_headersFromAuth_basic() throws {
        let raw = #"{"type":"basic","username":"u","password":"p"}"#
        let auth: AuthHelper = try decodeArgs(raw)
        let headers = try headersFromAuth(auth)
        // u:p base64-encoded = dTpw
        XCTAssertEqual(headers["Authorization"], "Basic dTpw")
    }

    func test_headersFromAuth_bearerRequiresToken() {
        let raw = #"{"type":"bearer"}"#
        let auth: AuthHelper = try! decodeArgs(raw)
        XCTAssertThrowsError(try headersFromAuth(auth)) { error in
            XCTAssertEqual((error as? ToolError)?.code, "INVALID_ARGS")
        }
    }

    func test_headersFromAuth_unknownType() {
        let raw = #"{"type":"oauth"}"#
        let auth: AuthHelper = try! decodeArgs(raw)
        XCTAssertThrowsError(try headersFromAuth(auth)) { error in
            XCTAssertEqual((error as? ToolError)?.code, "INVALID_ARGS")
        }
    }

    func test_headersFromAuth_nilReturnsEmpty() throws {
        let headers = try headersFromAuth(nil)
        XCTAssertTrue(headers.isEmpty)
    }
}
