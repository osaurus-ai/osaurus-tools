import XCTest

@testable import OsaurusBrowser

final class FormatSnapshotTests: XCTestCase {

    // MARK: - Test Data

    private func makeSampleData(
        title: String = "Test Page",
        url: String = "https://example.com",
        hasMore: Bool = false,
        bodyText: String = "",
        elements: [[String: Any]] = []
    ) -> [String: Any] {
        return [
            "title": title,
            "url": url,
            "hasMore": hasMore,
            "bodyText": bodyText,
            "elementCount": elements.count,
            "elements": elements,
        ]
    }

    private func makeSampleElements() -> [[String: Any]] {
        return [
            [
                "ref": "E1", "type": "input", "text": "",
                "placeholder": "Enter email", "name": "email",
                "required": true, "id": "email-input",
                "ariaLabel": "Email address",
            ],
            [
                "ref": "E2", "type": "input", "text": "",
                "placeholder": "Password", "name": "password",
                "required": true, "id": "pwd-input",
            ],
            [
                "ref": "E3", "type": "button", "text": "Submit",
                "id": "submit-btn",
            ],
            [
                "ref": "E4", "type": "link", "text": "Forgot password?",
                "href": "https://example.com/forgot", "id": "forgot-link",
            ],
        ]
    }

    // MARK: - Detail: none

    func testFormatNone_returnsEmptyString() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .none)
        XCTAssertEqual(result, "")
    }

    // MARK: - Detail: compact

    func testFormatCompact_singleLine() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .compact)

        // Elements should be on a single line (after the header)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2, "Compact format should have exactly 2 lines: header + elements")
    }

    func testFormatCompact_includesPageHeader() {
        let data = makeSampleData(title: "My Page", url: "https://example.com/test")
        let result = formatSnapshotOutput(data, detail: .compact)
        XCTAssertTrue(result.contains("- page: My Page | url: https://example.com/test"))
    }

    func testFormatCompact_truncatesLongText() {
        let elements: [[String: Any]] = [
            ["ref": "E1", "type": "button", "text": "This is a very long button label that should be truncated"]
        ]
        let data = makeSampleData(elements: elements)
        let result = formatSnapshotOutput(data, detail: .compact)
        XCTAssertTrue(result.contains("This is a very long ..."))
        XCTAssertFalse(result.contains("should be truncated"))
    }

    func testFormatCompact_hasMoreIndicator() {
        let data = makeSampleData(hasMore: true, elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .compact)
        XCTAssertTrue(result.hasSuffix(" ..."))
    }

    func testFormatCompact_emptyElements() {
        let data = makeSampleData()
        let result = formatSnapshotOutput(data, detail: .compact)
        XCTAssertTrue(result.contains("(no interactive elements found)"))
    }

    // MARK: - Detail: standard

    func testFormatStandard_multiLine() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .standard)

        XCTAssertTrue(result.contains("[E1] input"))
        XCTAssertTrue(result.contains("[E2] input"))
        XCTAssertTrue(result.contains("[E3] button \"Submit\""))
        XCTAssertTrue(result.contains("[E4] link \"Forgot password?\""))

        // Each element on its own line
        let elementLines = result.split(separator: "\n").filter { $0.hasPrefix("[E") }
        XCTAssertEqual(elementLines.count, 4)
    }

    func testFormatStandard_includesKeyAttributes() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .standard)

        XCTAssertTrue(result.contains("placeholder=\"Enter email\""))
        XCTAssertTrue(result.contains("required"))
        XCTAssertTrue(result.contains("href=\"https://example.com/forgot\""))
    }

    func testFormatStandard_redactsCredentialURLsAndText() {
        let elements: [[String: Any]] = [
            [
                "ref": "E1", "type": "link", "text": "token=secret-value",
                "href": "https://example.com/callback?access_token=secret-value",
            ],
            [
                "ref": "E2", "type": "input", "value": "api_key=secret-value",
            ],
        ]
        let data = makeSampleData(
            title: "access_token=secret-value",
            url: "https://example.com/page?token=secret-value",
            elements: elements
        )
        let result = formatSnapshotOutput(data, detail: .standard)

        XCTAssertFalse(result.contains("secret-value"))
        XCTAssertTrue(result.contains("access_token=REDACTED"))
        XCTAssertTrue(result.contains("token=REDACTED"))
        XCTAssertTrue(result.contains("api_key=REDACTED"))
    }

    func testFormatStandard_separatePageHeader() {
        let data = makeSampleData(title: "Test", url: "https://test.com")
        let result = formatSnapshotOutput(data, detail: .standard)
        XCTAssertTrue(result.contains("- page: Test\n"))
        XCTAssertTrue(result.contains("- url: https://test.com\n"))
    }

    func testFormatStandard_checkedDisabledAttributes() {
        let elements: [[String: Any]] = [
            ["ref": "E1", "type": "checkbox", "text": "Remember me", "checked": true],
            ["ref": "E2", "type": "button", "text": "Save", "disabled": true],
        ]
        let data = makeSampleData(elements: elements)
        let result = formatSnapshotOutput(data, detail: .standard)

        XCTAssertTrue(result.contains("[E1] checkbox \"Remember me\" checked"))
        XCTAssertTrue(result.contains("[E2] button \"Save\" disabled"))
    }

    // MARK: - Detail: full

    func testFormatFull_includesPageText() {
        let data = makeSampleData(
            bodyText: "Welcome to our application. Please sign in to continue.",
            elements: makeSampleElements()
        )
        let result = formatSnapshotOutput(data, detail: .full)
        XCTAssertTrue(result.contains("- text: Welcome to our application."))
    }

    func testFormatFull_includesAllAttributes() {
        let data = makeSampleData(elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .full)

        // Full includes id, name, aria-label, and href on all element types (not just links)
        XCTAssertTrue(result.contains("id=\"email-input\""))
        XCTAssertTrue(result.contains("name=\"email\""))
        XCTAssertTrue(result.contains("aria-label=\"Email address\""))
        XCTAssertTrue(result.contains("id=\"submit-btn\""))
        XCTAssertTrue(result.contains("id=\"forgot-link\""))
    }

    func testFormatFull_hrefOnAllTypes() {
        // In full mode, href should appear even on non-link elements that have it
        let data = makeSampleData(elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .full)
        XCTAssertTrue(result.contains("href=\"https://example.com/forgot\""))
    }

    func testFormatFull_truncatesLongBodyText() {
        let longText = String(repeating: "Hello world. ", count: 50)
        let data = makeSampleData(bodyText: longText, elements: makeSampleElements())
        let result = formatSnapshotOutput(data, detail: .full)

        let textLine = result.split(separator: "\n").first { $0.hasPrefix("- text:") }
        XCTAssertNotNil(textLine)
        XCTAssertTrue(textLine!.hasSuffix("..."))
    }

    // MARK: - Edge Cases

    func testFormatWithSpecialCharacters() {
        let elements: [[String: Any]] = [
            ["ref": "E1", "type": "button", "text": "Click \"here\" now"]
        ]
        let data = makeSampleData(elements: elements)
        let result = formatSnapshotOutput(data, detail: .standard)
        XCTAssertTrue(result.contains("Click \"here\" now"))
    }

    func testFormatWithEmptyElements() {
        let data = makeSampleData(elements: [])
        for detail in [DetailLevel.compact, .standard, .full] {
            let result = formatSnapshotOutput(data, detail: detail)
            XCTAssertTrue(
                result.contains("(no interactive elements found)"),
                "Detail level \(detail.rawValue) should handle empty elements"
            )
        }
    }
}
