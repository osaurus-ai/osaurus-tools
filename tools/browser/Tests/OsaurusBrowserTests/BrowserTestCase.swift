import AppKit
import XCTest

@testable import OsaurusBrowser

/// Base class for tests that require a live WebKit browser.
/// These tests require a full macOS application context (WKWebView).
/// They are skipped in `swift test` which lacks WebKit support.
/// Run with Xcode or `xcodebuild test` for full coverage, or set
/// the OSAURUS_BROWSER_TESTS=1 environment variable to enable.
class BrowserTestCase: XCTestCase {
    var context: PluginContext?
    private let browserQueue = DispatchQueue(label: "browser.test.queue")
    private var shouldSkip = false

    /// Check in setUp whether WebKit tests should run
    override func setUp() {
        super.setUp()

        let isXcodeTest = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        let isExplicitlyEnabled =
            ProcessInfo.processInfo.environment["OSAURUS_BROWSER_TESTS"] == "1"

        guard isXcodeTest || isExplicitlyEnabled else {
            shouldSkip = true
            return
        }

        if NSApp == nil, Thread.isMainThread {
            _ = NSApplication.shared
        } else if NSApp == nil {
            DispatchQueue.main.sync { _ = NSApplication.shared }
        }

        context = PluginContext()
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    /// Call at the start of each test to skip if WebKit is unavailable
    func skipIfNeeded() throws {
        try XCTSkipIf(
            shouldSkip,
            "WebKit tests require Xcode or xcodebuild. Set OSAURUS_BROWSER_TESTS=1 to enable.")
    }

    /// Run a block on the browser queue while pumping the main run loop.
    func browserSync<T>(_ block: @escaping () -> T) -> T {
        var result: T!
        var done = false

        browserQueue.async {
            result = block()
            done = true
        }

        let timeout = Date(timeIntervalSinceNow: 60)
        while !done && Date() < timeout {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertTrue(done, "Browser operation timed out after 60 seconds")
        return result
    }

    /// Returns a bundled test fixture URL. Keep this helper test-only so fixture
    /// navigation stays separate from any production URL policy.
    func fixtureURL(_ name: String) -> String {
        let bundle = Bundle.module
        guard
            let url = bundle.url(
                forResource: name, withExtension: "html", subdirectory: "Fixtures")
        else {
            XCTFail("Fixture '\(name).html' not found in test bundle")
            return "about:blank"
        }
        return url.absoluteString
    }

    @discardableResult
    func navigateToFixture(_ name: String, detail: String = "standard") -> String {
        guard let ctx = context else { return "" }
        let url = fixtureURL(name)
        let args = "{\"url\": \"\(url)\", \"detail\": \"\(detail)\"}"
        return browserSync { ctx.navigate(args: args) }
    }

    func takeSnapshot(
        filter: String? = nil,
        maxElements: Int? = nil,
        visibleOnly: Bool? = nil,
        detail: String = "standard"
    ) -> String {
        guard let ctx = context else { return "" }
        var fields = ["\"detail\": \"\(detail)\""]
        if let filter {
            fields.append("\"filter\": \"\(filter)\"")
        }
        if let maxElements {
            fields.append("\"max_elements\": \(maxElements)")
        }
        if let visibleOnly {
            fields.append("\"visible_only\": \(visibleOnly)")
        }
        let args = "{\(fields.joined(separator: ", "))}"
        return browserSync {
            return ctx.snapshot(args: args)
        }
    }
}
