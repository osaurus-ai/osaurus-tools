import XCTest

@testable import OsaurusBrowser

final class SnapshotFilterConditionTests: XCTestCase {

    func testFilterConditionsReferenceTreeWalkerNode() {
        for filter in ["inputs", "buttons", "links", "forms"] {
            let condition = HeadlessBrowser.snapshotFilterCondition(for: filter)

            XCTAssertTrue(
                condition.contains("node.matches("),
                "\(filter) filter should evaluate the TreeWalker node")
            XCTAssertFalse(
                condition.contains("el.matches("),
                "\(filter) filter must not reference the walker loop variable")
        }
    }

    func testFilterConditionsPreserveSelectors() {
        XCTAssertEqual(
            HeadlessBrowser.snapshotFilterCondition(for: "inputs"),
            "node.matches('input, textarea, select, [contenteditable=\"true\"]')")
        XCTAssertEqual(
            HeadlessBrowser.snapshotFilterCondition(for: "buttons"),
            "node.matches('button, input[type=\"button\"], input[type=\"submit\"], [role=\"button\"]')")
        XCTAssertEqual(
            HeadlessBrowser.snapshotFilterCondition(for: "links"),
            "node.matches('a[href]')")
        XCTAssertEqual(
            HeadlessBrowser.snapshotFilterCondition(for: "forms"),
            "node.matches('form, input, textarea, select, button')")
        XCTAssertEqual(HeadlessBrowser.snapshotFilterCondition(for: "all"), "true")
        XCTAssertEqual(HeadlessBrowser.snapshotFilterCondition(for: "unknown"), "true")
    }
}

final class SnapshotFilterLiveTests: BrowserTestCase {

    override func setUp() {
        super.setUp()
        guard context != nil else { return }
        navigateToFixture("interactive-elements", detail: "none")
    }

    func testInputsFilterReturnsOnlyInputLikeElements() throws {
        try skipIfNeeded()

        let snapshot = takeSnapshot(filter: "inputs", detail: "full")
        let elements = elementLines(in: snapshot)

        XCTAssertFalse(elements.isEmpty, "Inputs filter should return matching elements")
        XCTAssertTrue(elements.contains("id=\"text-input\""))
        XCTAssertTrue(elements.contains("id=\"textarea\""))
        XCTAssertTrue(elements.contains("id=\"select-country\""))
        XCTAssertTrue(elements.contains("id=\"cb-agree\""))
        XCTAssertFalse(elements.contains("id=\"btn-primary\""))
        XCTAssertFalse(elements.contains("id=\"div-button\""))
        XCTAssertFalse(elements.contains("id=\"link-page1\""))
    }

    func testButtonsFilterReturnsOnlyButtonElements() throws {
        try skipIfNeeded()

        let snapshot = takeSnapshot(filter: "buttons", detail: "full")
        let elements = elementLines(in: snapshot)

        XCTAssertFalse(elements.isEmpty, "Buttons filter should return matching elements")
        XCTAssertTrue(elements.contains("id=\"btn-primary\""))
        XCTAssertTrue(elements.contains("id=\"btn-submit\""))
        XCTAssertTrue(elements.contains("id=\"div-button\""))
        XCTAssertFalse(elements.contains("id=\"text-input\""))
        XCTAssertFalse(elements.contains("id=\"select-country\""))
        XCTAssertFalse(elements.contains("id=\"link-page1\""))
    }

    func testLinksFilterReturnsOnlyLinks() throws {
        try skipIfNeeded()

        let snapshot = takeSnapshot(filter: "links", detail: "full")
        let elements = elementLines(in: snapshot)

        XCTAssertFalse(elements.isEmpty, "Links filter should return matching elements")
        XCTAssertTrue(elements.contains("id=\"link-page1\""))
        XCTAssertTrue(elements.contains("id=\"link-page2\""))
        XCTAssertTrue(elements.contains("id=\"link-external\""))
        XCTAssertFalse(elements.contains("id=\"text-input\""))
        XCTAssertFalse(elements.contains("id=\"btn-primary\""))
        XCTAssertFalse(elements.contains("id=\"select-country\""))
    }

    func testFormsFilterReturnsFormControlsOnly() throws {
        try skipIfNeeded()

        let snapshot = takeSnapshot(filter: "forms", detail: "full")
        let elements = elementLines(in: snapshot)

        XCTAssertFalse(elements.isEmpty, "Forms filter should return matching elements")
        XCTAssertTrue(elements.contains("id=\"text-input\""))
        XCTAssertTrue(elements.contains("id=\"textarea\""))
        XCTAssertTrue(elements.contains("id=\"select-country\""))
        XCTAssertTrue(elements.contains("id=\"btn-primary\""))
        XCTAssertFalse(elements.contains("id=\"link-page1\""))
        XCTAssertFalse(elements.contains("id=\"div-button\""))
        XCTAssertFalse(elements.contains("id=\"aria-switch\""))
    }

    func testVisibleOnlyExcludesHiddenFilteredElements() throws {
        try skipIfNeeded()

        let visibleSnapshot = takeSnapshot(filter: "buttons", visibleOnly: true, detail: "full")
        let visibleElements = elementLines(in: visibleSnapshot)

        XCTAssertTrue(visibleElements.contains("id=\"btn-primary\""))
        XCTAssertFalse(visibleElements.contains("id=\"hidden-btn-display\""))
        XCTAssertFalse(visibleElements.contains("id=\"hidden-btn-visibility\""))
        XCTAssertFalse(visibleElements.contains("id=\"hidden-btn-opacity\""))

        let allSnapshot = takeSnapshot(filter: "buttons", visibleOnly: false, detail: "full")
        let allElements = elementLines(in: allSnapshot)

        XCTAssertTrue(allElements.contains("id=\"hidden-btn-display\""))
        XCTAssertTrue(allElements.contains("id=\"hidden-btn-visibility\""))
        XCTAssertTrue(allElements.contains("id=\"hidden-btn-opacity\""))
    }

    private func elementLines(in snapshot: String) -> String {
        snapshot
            .split(separator: "\n")
            .filter { $0.hasPrefix("[E") }
            .joined(separator: "\n")
    }
}
