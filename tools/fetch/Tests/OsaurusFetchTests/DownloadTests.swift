import XCTest

@testable import OsaurusFetch

final class DownloadTests: XCTestCase {

    private let url = URL(string: "https://example.com/foo")!

    func test_download_rejectsPathSeparator() {
        assertRejected("../etc/passwd")
    }

    func test_download_rejectsBackslash() {
        assertRejected("evil\\name")
    }

    func test_download_rejectsLeadingDot() {
        assertRejected(".secret")
    }

    func test_download_rejectsLeadingTilde() {
        assertRejected("~/foo")
    }

    func test_download_rejectsAbsolutePath() {
        assertRejected("/etc/passwd")
    }

    func test_download_rejectsParentTraversal() {
        assertRejected("ok..weird")
    }

    func test_download_acceptsPlainFilename() throws {
        let target = try resolveDownloadTarget(requestedFilename: "report.pdf", url: url)
        XCTAssertTrue(target.path.hasSuffix("/Downloads/report.pdf"), "got: \(target.path)")
    }

    func test_download_falls_back_to_url_basename() throws {
        let target = try resolveDownloadTarget(requestedFilename: nil, url: url)
        XCTAssertTrue(target.path.hasSuffix("/Downloads/foo"), "got: \(target.path)")
    }

    func test_download_generates_filename_when_url_has_none() throws {
        let bare = URL(string: "https://example.com/")!
        let target = try resolveDownloadTarget(requestedFilename: nil, url: bare)
        XCTAssertTrue(target.path.contains("/Downloads/download_"), "got: \(target.path)")
    }

    private func assertRejected(_ filename: String, file: StaticString = #file, line: UInt = #line) {
        do {
            _ = try resolveDownloadTarget(requestedFilename: filename, url: url)
            XCTFail("expected rejection of '\(filename)'", file: file, line: line)
        } catch let err as ToolError {
            XCTAssertEqual(err.code, "DOWNLOAD_PATH_INVALID", file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
