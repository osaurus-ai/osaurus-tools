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

    // MARK: provider tables

    func test_paidProviderPriority_matchesDocumentedOrder() {
        // The order doubles as the auto-cascade priority — Tavily's snippets are best
        // for agents, Brave/Serper next, you/Kagi last. Don't reshuffle without
        // updating the SKILL too.
        XCTAssertEqual(
            paidProviderPriority,
            ["tavily", "brave_api", "serper", "google_cse", "kagi", "you"]
        )
    }

    func test_freeProviderIds_areTheThreeScrapers() {
        XCTAssertEqual(freeProviderIds, ["ddg", "brave_html", "bing_html"])
    }

    func test_validProviderIds_isUnionOfFreeAndPaid() {
        XCTAssertEqual(
            validProviderIds,
            Set(freeProviderIds + paidProviderPriority)
        )
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

    // MARK: sanitizeProvider

    func test_sanitizeProvider_passesThroughKnownIDs() {
        var warnings: [String] = []
        XCTAssertEqual(sanitizeProvider("tavily", warnings: &warnings), "tavily")
        XCTAssertEqual(sanitizeProvider("brave_html", warnings: &warnings), "brave_html")
        XCTAssertTrue(warnings.isEmpty)
    }

    func test_sanitizeProvider_lowercasesKnownIDs() {
        var warnings: [String] = []
        XCTAssertEqual(sanitizeProvider("TAVILY", warnings: &warnings), "tavily")
        XCTAssertTrue(warnings.isEmpty)
    }

    func test_sanitizeProvider_dropsAutoSentinelWithWarning() {
        // The single most common agent failure mode in the wild: agent sends
        // `provider: "auto"` thinking that's how to opt in to the cascade.
        // Should be silently treated as nil + a warning, not an error.
        var warnings: [String] = []
        XCTAssertNil(sanitizeProvider("auto", warnings: &warnings))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("auto"))
    }

    func test_sanitizeProvider_dropsBingShorthandWithWarning() {
        var warnings: [String] = []
        XCTAssertNil(sanitizeProvider("bing", warnings: &warnings))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].lowercased().contains("bing"))
    }

    func test_sanitizeProvider_nilAndEmptyAreNotWarnings() {
        var warnings: [String] = []
        XCTAssertNil(sanitizeProvider(nil, warnings: &warnings))
        XCTAssertNil(sanitizeProvider("", warnings: &warnings))
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: sanitizeRegion

    func test_sanitizeRegion_acceptsXxYy() {
        var warnings: [String] = []
        XCTAssertEqual(sanitizeRegion("us-en", warnings: &warnings), "us-en")
        XCTAssertEqual(sanitizeRegion("DE-DE", warnings: &warnings), "de-de")
        XCTAssertTrue(warnings.isEmpty)
    }

    func test_sanitizeRegion_rejectsTwoLetterShorthand() {
        var warnings: [String] = []
        XCTAssertNil(sanitizeRegion("us", warnings: &warnings))
        XCTAssertEqual(warnings.count, 1)
    }

    // MARK: providerHasSecrets

    func test_providerHasSecrets_googleCSERequiresBoth() {
        XCTAssertFalse(providerHasSecrets("google_cse", secrets: ["GOOGLE_CSE_API_KEY": "k"]))
        XCTAssertTrue(
            providerHasSecrets("google_cse", secrets: ["GOOGLE_CSE_API_KEY": "k", "GOOGLE_CSE_CX": "cx"])
        )
    }

    // MARK: WebArgs decoding

    func test_WebArgs_decodesPayloadWithoutProvider() throws {
        // Agents no longer see `provider` in the JSON schema — they're expected to omit it.
        // Verify the decoder still accepts the trimmed payload and leaves `provider` nil so
        // `runWebOrNews` falls through to the auto-cascade.
        let payload = #"""
            {"query":"hello","max_results":5,"time_range":"w","site":"","filetype":"","offset":0,"region":""}
            """#
        let data = payload.data(using: .utf8)!
        let args = try JSONDecoder().decode(WebArgs.self, from: data)
        XCTAssertEqual(args.query, "hello")
        XCTAssertNil(args.provider)
    }

    func test_WebArgs_stillAcceptsProviderForDirectCallers() throws {
        // Removing `provider` from the agent schema doesn't remove it from the runtime.
        // Direct dylib callers (CLI, Swift apps, regression tests) can still pin a backend.
        let payload = #"""
            {"query":"hello","provider":"ddg"}
            """#
        let data = payload.data(using: .utf8)!
        let args = try JSONDecoder().decode(WebArgs.self, from: data)
        XCTAssertEqual(args.provider, "ddg")
    }

    // MARK: noResultsHint

    func test_noResultsHint_suggestsConfiguringKeyWhenNoneSet() {
        let hint = noResultsHint(secrets: [:])
        XCTAssertTrue(
            hint.contains("configure an API key"),
            "Expected hint to suggest configuring an API key, got: \(hint)"
        )
        XCTAssertTrue(hint.contains("TAVILY_API_KEY"))
    }

    func test_noResultsHint_listsConfiguredBackendsWhenSet() {
        // Power user has Tavily configured; their key was tried and failed.
        // Hint should NOT redundantly tell them to configure a key — it should name what
        // was tried so they know where to look.
        let hint = noResultsHint(secrets: ["TAVILY_API_KEY": "k"])
        XCTAssertTrue(hint.contains("tavily"), "Expected hint to name configured backend, got: \(hint)")
        XCTAssertTrue(
            hint.contains("API key is still valid"),
            "Expected hint to point at the key, got: \(hint)"
        )
        XCTAssertFalse(
            hint.contains("configure an API key"),
            "Should not redundantly tell user to configure a key when one is already set: \(hint)"
        )
    }

    // MARK: runWebOrNews — NO_RESULTS envelope

    func test_runWebOrNews_pinnedPaidWithoutKeyThrowsNoResults() {
        // Pinning Tavily without TAVILY_API_KEY fails synchronously inside the backend
        // (no network) and the cascade has nowhere else to go because the user explicitly
        // pinned a single provider. The new envelope must surface this as ok:false NO_RESULTS
        // — the old behavior of ok:true count:0 was the root cause of agents thinking the
        // search "succeeded".
        let params = SearchParams(
            query: "anything",
            max_results: 5,
            offset: 0,
            site: nil, filetype: nil, time_range: nil, region: nil,
            provider: "tavily",
            secrets: [:],
            vertical: .web
        )
        XCTAssertThrowsError(try runWebOrNews(params)) { err in
            guard let toolErr = err as? ToolError else {
                XCTFail("Expected ToolError, got \(err)")
                return
            }
            XCTAssertEqual(toolErr.code, "NO_RESULTS")
            // The error envelope must carry the attempts log so the agent / user can see
            // *why* the search returned nothing.
            let attempts = toolErr.data?["attempts"] as? [[String: Any]]
            XCTAssertNotNil(attempts)
            XCTAssertEqual(attempts?.count, 1)
            XCTAssertEqual(attempts?[0]["provider"] as? String, "tavily")
            XCTAssertEqual(attempts?[0]["ok"] as? Bool, false)
        }
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
