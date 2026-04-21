import XCTest

@testable import OsaurusFetch

final class HTMLTests: XCTestCase {

    // MARK: decodeHTMLEntities

    func test_decodeHTMLEntities_namedEntities() {
        XCTAssertEqual(decodeHTMLEntities("a &amp; b"), "a & b")
        XCTAssertEqual(decodeHTMLEntities("&lt;div&gt;"), "<div>")
        XCTAssertEqual(decodeHTMLEntities("&quot;hi&quot;"), #""hi""#)
        XCTAssertEqual(decodeHTMLEntities("don&apos;t"), "don't")
        XCTAssertEqual(decodeHTMLEntities("don&#39;t"), "don't")
        XCTAssertEqual(decodeHTMLEntities("a&nbsp;b"), "a b")
    }

    func test_decodeHTMLEntities_decimalNumeric_preservesCodepoint() {
        // The pre-2.0.0 decoder stripped numeric entities to empty strings;
        // 2.0.0 must preserve them.
        XCTAssertEqual(decodeHTMLEntities("&#65;"), "A")
        XCTAssertEqual(decodeHTMLEntities("&#8217;"), "\u{2019}")  // right single quote
    }

    func test_decodeHTMLEntities_hexNumeric_preservesCodepoint() {
        XCTAssertEqual(decodeHTMLEntities("&#x41;"), "A")
        XCTAssertEqual(decodeHTMLEntities("&#x2014;"), "—")
    }

    func test_decodeHTMLEntities_isCaseInsensitiveForNamedEntities() {
        XCTAssertEqual(decodeHTMLEntities("&AMP; &Lt;"), "& <")
    }

    // MARK: htmlToPlainText

    func test_htmlToPlainText_stripsScriptsAndStyles() {
        let html = "<style>body{color:red}</style><p>Hello <b>world</b></p><script>alert(1)</script>"
        let plain = htmlToPlainText(html)
        XCTAssertEqual(plain, "Hello world")
    }

    func test_htmlToPlainText_normalizesWhitespace() {
        let html = "<p>Hello\n\n\n   world</p>"
        XCTAssertEqual(htmlToPlainText(html), "Hello world")
    }

    func test_htmlToPlainText_decodesEntities() {
        XCTAssertEqual(htmlToPlainText("<p>caf&eacute;? &amp; tea</p>"), "caf&eacute;? & tea")
    }

    // MARK: htmlToMarkdown

    func test_htmlToMarkdown_headings() {
        let md = htmlToMarkdown("<h1>Title</h1><h2>Sub</h2>")
        XCTAssertTrue(md.contains("# Title"), "got: \(md)")
        XCTAssertTrue(md.contains("## Sub"), "got: \(md)")
    }

    func test_htmlToMarkdown_listItems() {
        let md = htmlToMarkdown("<ul><li>one</li><li>two</li></ul>")
        XCTAssertTrue(md.contains("- one"), "got: \(md)")
        XCTAssertTrue(md.contains("- two"), "got: \(md)")
    }

    func test_htmlToMarkdown_anchors() {
        let md = htmlToMarkdown(#"<a href="https://example.com">click</a>"#)
        XCTAssertTrue(md.contains("[click](https://example.com)"), "got: \(md)")
    }

    func test_htmlToMarkdown_images() {
        let md = htmlToMarkdown(#"<img src="https://x/y.png" alt="logo">"#)
        XCTAssertTrue(md.contains("![logo](https://x/y.png)"), "got: \(md)")
    }

    func test_htmlToMarkdown_inlineEmphasis() {
        let md = htmlToMarkdown("<p>Hello <strong>bold</strong> and <em>italic</em></p>")
        XCTAssertTrue(md.contains("**bold**"), "got: \(md)")
        XCTAssertTrue(md.contains("*italic*"), "got: \(md)")
    }

    // MARK: readabilityExtract

    func test_readability_extractsTitleAndMarkdown() {
        let html = """
            <html lang="en">
              <head>
                <title>My Article</title>
                <meta name="author" content="Jane Doe">
                <meta name="description" content="A short summary.">
              </head>
              <body>
                <header>top nav</header>
                <article>
                  <h1>The Heading</h1>
                  <p>First paragraph with <a href="/x">link</a>.</p>
                  <p>Second paragraph.</p>
                </article>
                <footer>copyright stuff</footer>
              </body>
            </html>
            """
        let result = readabilityExtract(html: html, selector: nil)
        XCTAssertEqual(result.title, "My Article")
        XCTAssertEqual(result.byline, "Jane Doe")
        XCTAssertEqual(result.excerpt, "A short summary.")
        XCTAssertEqual(result.lang, "en")
        XCTAssertTrue(result.markdown.contains("# The Heading"), "got: \(result.markdown)")
        XCTAssertTrue(result.markdown.contains("First paragraph"), "got: \(result.markdown)")
        XCTAssertFalse(result.markdown.contains("top nav"), "header was not stripped: \(result.markdown)")
        XCTAssertFalse(result.markdown.contains("copyright"), "footer was not stripped: \(result.markdown)")
        XCTAssertGreaterThan(result.wordCount, 0)
    }

    func test_readability_fallsBackToBodyWhenNoArticle() {
        let html = "<html><body><p>Just a paragraph.</p></body></html>"
        let result = readabilityExtract(html: html, selector: nil)
        XCTAssertTrue(result.markdown.contains("Just a paragraph"), "got: \(result.markdown)")
    }

    func test_readability_appliesIdSelector() {
        let html = "<html><body><div id=\"good\"><p>kept</p></div><div id=\"bad\"><p>dropped</p></div></body></html>"
        let result = readabilityExtract(html: html, selector: "#good")
        XCTAssertTrue(result.markdown.contains("kept"), "got: \(result.markdown)")
        XCTAssertFalse(result.markdown.contains("dropped"), "got: \(result.markdown)")
    }
}
