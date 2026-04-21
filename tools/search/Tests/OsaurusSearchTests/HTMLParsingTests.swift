import XCTest

@testable import OsaurusSearch

final class HTMLParsingTests: XCTestCase {

    // MARK: parseDDGHTML

    func test_parseDDGHTML_unwrapsUDDGRedirects() {
        let html = """
            <div class="result"><a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa">Example A</a>
              <a class="result__snippet">Snippet text</a></div>
            <div class="result"><a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fb">Example B</a>
              <a class="result__snippet">Other snippet</a></div>
            """
        let hits = parseDDGHTML(html, max: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].url, "https://example.com/a")
        XCTAssertEqual(hits[0].title, "Example A")
        XCTAssertEqual(hits[0].snippet, "Snippet text")
        XCTAssertEqual(hits[1].url, "https://example.com/b")
        XCTAssertEqual(hits[1].engine, "ddg")
    }

    func test_parseDDGHTML_returnsEmptyOnUnknownMarkup() {
        let hits = parseDDGHTML("<html><body><p>nothing here</p></body></html>", max: 5)
        XCTAssertEqual(hits.count, 0)
    }

    func test_parseDDGHTML_respectsMax() {
        var html = ""
        for i in 0..<10 {
            html += """
                <div class="result"><a class="result__a" href="https://example.com/\(i)">Title \(i)</a></div>
                """
        }
        let hits = parseDDGHTML(html, max: 3)
        XCTAssertEqual(hits.count, 3)
    }

    // MARK: parseBingHTML

    func test_parseBingHTML_extractsTitleAndSnippet() {
        let html = """
            <li class="b_algo"><h2><a href="https://example.com/x">Headline</a></h2>
              <p>This is the snippet.</p></li>
            """
        let hits = parseBingHTML(html, max: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].title, "Headline")
        XCTAssertEqual(hits[0].url, "https://example.com/x")
        XCTAssertEqual(hits[0].snippet, "This is the snippet.")
        XCTAssertEqual(hits[0].engine, "bing_html")
    }
}
