import XCTest

@testable import OsaurusBrowser

/// Tests for the CSS selector → JS string-literal escape helper.
///
/// Pre-2.0.0 only escaped single quotes — selectors containing backslashes,
/// newlines, tabs, or carriage returns could break the injected JS. These
/// tests pin down the new behavior.
final class EscapeSelectorTests: XCTestCase {

    func test_passesThroughOrdinarySelectors() {
        XCTAssertEqual(escapeSelector("button.primary"), "button.primary")
        XCTAssertEqual(
            escapeSelector("#login-form input[name=email]"),
            "#login-form input[name=email]")
    }

    func test_escapesSingleQuotes() {
        XCTAssertEqual(escapeSelector("a[title='hi']"), #"a[title=\'hi\']"#)
    }

    func test_escapesBackslash() {
        // input: a\b → output: a\\b (so the JS literal sees a single backslash)
        XCTAssertEqual(escapeSelector(#"a\b"#), #"a\\b"#)
    }

    func test_backslashIsEscapedBeforeQuote() {
        // Order matters: if backslash were escaped after the quote, "a'" would
        // become a\\' instead of a\'. Pin the order so a regression can't sneak
        // back in.
        XCTAssertEqual(escapeSelector("a'"), #"a\'"#)
    }

    func test_escapesNewlinesAndTabs() {
        XCTAssertEqual(escapeSelector("a\nb"), "a\\nb")
        XCTAssertEqual(escapeSelector("a\tb"), "a\\tb")
        XCTAssertEqual(escapeSelector("a\rb"), "a\\rb")
    }

    func test_emptyStringStaysEmpty() {
        XCTAssertEqual(escapeSelector(""), "")
    }
}
