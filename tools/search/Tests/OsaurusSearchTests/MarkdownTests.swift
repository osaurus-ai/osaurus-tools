import XCTest

@testable import OsaurusSearch

final class MarkdownTests: XCTestCase {

    func test_pickMainContainer_prefersArticle() {
        let html = """
            <html><body>
              <header>nav</header>
              <article><h1>Yes</h1></article>
              <main><p>also main</p></main>
            </body></html>
            """
        let picked = pickMainContainer(html)
        XCTAssertNotNil(picked)
        XCTAssertTrue(picked?.contains("Yes") ?? false)
        XCTAssertFalse(picked?.contains("also main") ?? true)
    }

    func test_pickMainContainer_fallsBackToBody() {
        let html = "<html><body><div>plain</div></body></html>"
        XCTAssertEqual(pickMainContainer(html)?.trimmingCharacters(in: .whitespaces), "<div>plain</div>")
    }

    func test_htmlToMarkdown_basicShape() {
        let md = htmlToMarkdown("<h1>T</h1><p>One <strong>two</strong> three.</p>")
        XCTAssertTrue(md.contains("# T"), md)
        XCTAssertTrue(md.contains("**two**"), md)
    }

    func test_metaContent_findsAuthorByName() {
        let html = #"<meta name="author" content="Jane Doe">"#
        XCTAssertEqual(metaContent(in: html, name: "author"), "Jane Doe")
    }

    func test_metaContent_findsByProperty() {
        let html = #"<meta property="og:description" content="Hi">"#
        XCTAssertEqual(metaContent(in: html, property: "og:description"), "Hi")
    }

    func test_metaContent_returnsNilWhenAbsent() {
        XCTAssertNil(metaContent(in: "<html></html>", name: "author"))
    }
}
