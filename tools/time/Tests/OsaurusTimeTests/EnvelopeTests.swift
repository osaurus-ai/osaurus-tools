import XCTest

@testable import OsaurusTime

final class EnvelopeTests: XCTestCase {
    func test_okResponse_includesData() throws {
        let raw = okResponse(["x": 1, "y": "two"])
        let json = try jsonObject(raw)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let data = json["data"] as? [String: Any]
        XCTAssertEqual(data?["x"] as? Int, 1)
        XCTAssertEqual(data?["y"] as? String, "two")
        XCTAssertNil(json["warnings"], "warnings should be omitted when empty")
    }

    func test_okResponse_warningsArePreserved() throws {
        let raw = okResponse(["k": "v"], warnings: ["heads up"])
        let json = try jsonObject(raw)
        XCTAssertEqual(json["warnings"] as? [String], ["heads up"])
    }

    func test_errorResponse_carriesCodeMessageHint() throws {
        let raw = errorResponse(code: "INVALID_ARGS", message: "boom", hint: "try again")
        let json = try jsonObject(raw)
        XCTAssertEqual(json["ok"] as? Bool, false)
        let err = json["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? String, "INVALID_ARGS")
        XCTAssertEqual(err?["message"] as? String, "boom")
        XCTAssertEqual(err?["hint"] as? String, "try again")
    }

    func test_errorResponse_omitsHintWhenAbsent() throws {
        let raw = errorResponse(code: "INTERNAL", message: "x")
        let json = try jsonObject(raw)
        let err = json["error"] as? [String: Any]
        XCTAssertNil(err?["hint"])
    }

    private func jsonObject(_ s: String) throws -> [String: Any] {
        guard let data = s.data(using: .utf8),
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw XCTSkip("Could not parse JSON: \(s)")
        }
        return obj
    }
}
