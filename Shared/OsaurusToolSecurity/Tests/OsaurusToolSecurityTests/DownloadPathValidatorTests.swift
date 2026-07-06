import XCTest

@testable import OsaurusToolSecurity

final class DownloadPathValidatorTests: XCTestCase {
    private var tempDir: URL!
    private var validator: DownloadPathValidator!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        validator = DownloadPathValidator(baseDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testAcceptsPlainFilenameInsideBaseDirectory() throws {
        let target = try validator.resolve(requestedFilename: "report.pdf")
        XCTAssertEqual(target.deletingLastPathComponent().standardizedFileURL.path, tempDir.standardizedFileURL.path)
        XCTAssertEqual(target.lastPathComponent, "report.pdf")
    }

    func testFallsBackToSourceURLBasename() throws {
        let source = URL(string: "https://example.com/downloads/archive.zip")!
        let target = try validator.resolve(requestedFilename: nil, sourceURL: source)
        XCTAssertEqual(target.lastPathComponent, "archive.zip")
    }

    func testRejectsAbsolutePathsParentTraversalHiddenTildeAndSeparators() {
        for candidate in [
            "/etc/passwd",
            "../secret",
            "safe..name",
            ".secret",
            "~/secret",
            "nested/file.txt",
            "nested\\file.txt",
            "",
        ] {
            assertRejected(candidate)
        }
    }

    func testRejectsExistingSymlinkThatEscapesBaseDirectory() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let link = tempDir.appendingPathComponent("safe.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        assertRejected("safe.txt")
    }

    private func assertRejected(
        _ filename: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try validator.resolve(requestedFilename: filename)
            XCTFail("Expected \(filename) to be rejected", file: file, line: line)
        } catch let error as WebSafetyError {
            XCTAssertEqual(error.code, .downloadPathInvalid, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
