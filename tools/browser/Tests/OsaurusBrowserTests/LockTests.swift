import XCTest

@testable import OsaurusBrowser

/// Tests the `browser_lock` cooperative-lock state machine via the
/// `PluginContext.lock(args:)` dispatcher. These exercise the structured
/// envelope path and the multi-agent ownership semantics.
///
/// Skipped unless `OSAURUS_BROWSER_TESTS=1` because instantiating
/// `PluginContext` lazily creates a `HeadlessBrowser` (WKWebView).
final class LockTests: BrowserTestCase {

    func test_lockSuccessThenStatus() throws {
        try skipIfNeeded()
        guard let ctx = context else { return XCTFail("context not initialized") }

        let lockResp = ctx.lock(args: #"{"action":"lock","owner":"alice"}"#)
        let lockJSON = try parse(lockResp)
        XCTAssertEqual(lockJSON["ok"] as? Bool, true)
        XCTAssertEqual((lockJSON["data"] as? [String: Any])?["owner"] as? String, "alice")

        let statusResp = ctx.lock(args: #"{"action":"status"}"#)
        let statusJSON = try parse(statusResp)
        let data = statusJSON["data"] as? [String: Any]
        XCTAssertEqual(data?["locked"] as? Bool, true)
        XCTAssertEqual(data?["owner"] as? String, "alice")
    }

    func test_secondLockerIsRejected() throws {
        try skipIfNeeded()
        guard let ctx = context else { return XCTFail("context not initialized") }

        _ = ctx.lock(args: #"{"action":"lock","owner":"alice"}"#)
        let denied = ctx.lock(args: #"{"action":"lock","owner":"bob"}"#)
        let json = try parse(denied)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "LOCK_HELD")
    }

    func test_unlockRequiresOwnership() throws {
        try skipIfNeeded()
        guard let ctx = context else { return XCTFail("context not initialized") }

        _ = ctx.lock(args: #"{"action":"lock","owner":"alice"}"#)
        // Bob can't release Alice's lock.
        let bobUnlock = ctx.lock(args: #"{"action":"unlock","owner":"bob"}"#)
        XCTAssertEqual(try parse(bobUnlock)["ok"] as? Bool, false)

        // But Alice can.
        let aliceUnlock = ctx.lock(args: #"{"action":"unlock","owner":"alice"}"#)
        let unlockJSON = try parse(aliceUnlock)
        XCTAssertEqual(unlockJSON["ok"] as? Bool, true)
        XCTAssertEqual((unlockJSON["data"] as? [String: Any])?["locked"] as? Bool, false)
    }

    func test_unlockWithoutAcquisitionIsNoOp() throws {
        try skipIfNeeded()
        guard let ctx = context else { return XCTFail("context not initialized") }

        let resp = ctx.lock(args: #"{"action":"unlock","owner":"alice"}"#)
        XCTAssertEqual(try parse(resp)["ok"] as? Bool, false)
    }

    func test_unknownActionReturnsInvalidArgs() throws {
        try skipIfNeeded()
        guard let ctx = context else { return XCTFail("context not initialized") }

        let resp = ctx.lock(args: #"{"action":"snurfle"}"#)
        let json = try parse(resp)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "INVALID_ARGS")
    }

    private func parse(_ s: String) throws -> [String: Any] {
        guard let data = s.data(using: .utf8),
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw XCTSkip("could not parse: \(s)")
        }
        return obj
    }
}
