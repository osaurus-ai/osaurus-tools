import XCTest

@testable import OsaurusSearch

final class HelpersTests: XCTestCase {

    // MARK: decodeHTMLEntities

    func test_decodeHTMLEntities_named() {
        XCTAssertEqual(decodeHTMLEntities("a &amp; b"), "a & b")
        XCTAssertEqual(decodeHTMLEntities("a &lt;b&gt;"), "a <b>")
        XCTAssertEqual(decodeHTMLEntities("&quot;hi&quot;"), #""hi""#)
    }

    func test_decodeHTMLEntities_numeric_preservesCodepoint() {
        // Pre-2.0.0 stripped numeric entities to "" — must preserve codepoint now.
        XCTAssertEqual(decodeHTMLEntities("&#65;"), "A")
        XCTAssertEqual(decodeHTMLEntities("&#8217;"), "\u{2019}")
    }

    func test_decodeHTMLEntities_hex_preservesCodepoint() {
        XCTAssertEqual(decodeHTMLEntities("&#x41;"), "A")
    }

    // MARK: stripHTML / sourceDomain

    func test_stripHTML_normalizesWhitespace() {
        XCTAssertEqual(stripHTML("<p>Hello\n\n   <b>world</b></p>"), "Hello world")
    }

    func test_sourceDomain_stripsWWW() {
        XCTAssertEqual(sourceDomain(of: "https://www.example.com/path"), "example.com")
        XCTAssertEqual(sourceDomain(of: "https://news.example.com/"), "news.example.com")
        XCTAssertNil(sourceDomain(of: "not a url"))
    }

    // MARK: unwrapDDG

    func test_unwrapDDG_unwrapsAbsoluteRedirect() {
        let wrapped = "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath"
        XCTAssertEqual(unwrapDDG(wrapped), "https://example.com/path")
    }

    func test_unwrapDDG_unwrapsRelativeRedirect() {
        let wrapped = "/l/?uddg=https%3A%2F%2Fexample.com%2F"
        XCTAssertEqual(unwrapDDG(wrapped), "https://example.com/")
    }

    func test_unwrapDDG_passesThroughBareURL() {
        XCTAssertEqual(unwrapDDG("https://example.com/"), "https://example.com/")
    }

    // MARK: providerCascade

    func test_providerCascade_explicitProviderWins() {
        let order = providerCascade(secrets: [:], requested: "tavily", vertical: .web)
        XCTAssertEqual(order, ["tavily"])
    }

    func test_providerCascade_explicitProviderIsLowercased() {
        let order = providerCascade(secrets: [:], requested: "TAVILY", vertical: .web)
        XCTAssertEqual(order, ["tavily"])
    }

    func test_providerCascade_emptySecretsFallsBackToFreeScraping() {
        let order = providerCascade(secrets: [:], requested: nil, vertical: .web)
        XCTAssertEqual(order, ["ddg", "brave_html", "bing_html"])
    }

    func test_providerCascade_promotesConfiguredAPIBackends() {
        let secrets = ["TAVILY_API_KEY": "k1", "BRAVE_SEARCH_API_KEY": "k2"]
        let order = providerCascade(secrets: secrets, requested: nil, vertical: .web)
        // Tavily should come first (highest priority), then Brave API,
        // then the free fallbacks.
        XCTAssertEqual(order.prefix(2).map { $0 }, ["tavily", "brave_api"])
        XCTAssertEqual(order.suffix(3), ["ddg", "brave_html", "bing_html"])
    }

    func test_providerCascade_googleCSERequiresBothKeys() {
        let onlyKey = ["GOOGLE_CSE_API_KEY": "k"]
        XCTAssertFalse(providerCascade(secrets: onlyKey, requested: nil, vertical: .web).contains("google_cse"))
        let both = ["GOOGLE_CSE_API_KEY": "k", "GOOGLE_CSE_CX": "cx"]
        XCTAssertTrue(providerCascade(secrets: both, requested: nil, vertical: .web).contains("google_cse"))
    }

    // MARK: augmentedQuery

    func test_augmentedQuery_addsSiteAndFiletype() {
        let p = makeParams(query: "ml papers", site: "arxiv.org", filetype: "pdf")
        XCTAssertEqual(augmentedQuery(p), "ml papers site:arxiv.org filetype:pdf")
    }

    func test_augmentedQuery_omitsEmptyOperators() {
        let p = makeParams(query: "hello", site: nil, filetype: nil)
        XCTAssertEqual(augmentedQuery(p), "hello")
    }

    func test_augmentedQuery_omitsEmptyStringOperators() {
        let p = makeParams(query: "hello", site: "", filetype: "")
        XCTAssertEqual(augmentedQuery(p), "hello")
    }

    // MARK: time-range mappings

    func test_mapTavilyTime_translatesShortcuts() {
        XCTAssertEqual(mapTavilyTime("d"), "day")
        XCTAssertEqual(mapTavilyTime("w"), "week")
        XCTAssertEqual(mapTavilyTime("m"), "month")
        XCTAssertEqual(mapTavilyTime("y"), "year")
        XCTAssertNil(mapTavilyTime(nil))
        XCTAssertNil(mapTavilyTime("nonsense"))
    }

    func test_mapBraveTime_usesPDPWPMPY() {
        XCTAssertEqual(mapBraveTime("d"), "pd")
        XCTAssertEqual(mapBraveTime("w"), "pw")
        XCTAssertEqual(mapBraveTime("m"), "pm")
        XCTAssertEqual(mapBraveTime("y"), "py")
    }

    func test_mapSerperTime_usesQDR() {
        XCTAssertEqual(mapSerperTime("d"), "qdr:d")
        XCTAssertEqual(mapSerperTime("w"), "qdr:w")
    }

    func test_mapCSETime_usesShortCodes() {
        XCTAssertEqual(mapCSETime("d"), "d1")
        XCTAssertEqual(mapCSETime("y"), "y1")
    }

    // MARK: helpers

    private func makeParams(
        query: String,
        site: String? = nil,
        filetype: String? = nil
    ) -> SearchParams {
        return SearchParams(
            query: query,
            max_results: 5,
            offset: 0,
            site: site,
            filetype: filetype,
            time_range: nil,
            region: nil,
            provider: nil,
            secrets: [:],
            vertical: .web
        )
    }
}
