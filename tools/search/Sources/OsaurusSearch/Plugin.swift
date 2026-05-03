import Foundation

// MARK: - Response Envelope

@inline(__always)
private func okResponse(_ data: [String: Any], warnings: [String] = []) -> String {
    var payload: [String: Any] = ["ok": true, "data": data]
    if !warnings.isEmpty { payload["warnings"] = warnings }
    return jsonString(payload)
}

@inline(__always)
private func errorResponse(
    code: String,
    message: String,
    hint: String? = nil,
    data: [String: Any]? = nil
) -> String {
    var error: [String: Any] = ["code": code, "message": message]
    if let hint = hint { error["hint"] = hint }
    var payload: [String: Any] = ["ok": false, "error": error]
    if let data = data { payload["data"] = data }
    return jsonString(payload)
}

private func jsonString(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
        let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        let str = String(data: data, encoding: .utf8)
    else {
        return #"{"ok":false,"error":{"code":"INTERNAL","message":"Failed to serialize response"}}"#
    }
    return str
}

struct ToolError: Error {
    let code: String
    let message: String
    let hint: String?
    let data: [String: Any]?
    init(code: String, message: String, hint: String? = nil, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.data = data
    }
}

/// What every tool's `run` returns: the data payload plus any non-fatal warnings
/// (e.g. "ignored unknown provider 'auto'") that should ride along on success.
struct ToolOutcome {
    var data: [String: Any]
    var warnings: [String]
    init(_ data: [String: Any], warnings: [String] = []) {
        self.data = data
        self.warnings = warnings
    }
}

private func decodeArgs<T: Decodable>(_ raw: String) throws -> T {
    guard let data = raw.data(using: .utf8) else {
        throw ToolError(code: "INVALID_ARGS", message: "payload is not valid UTF-8")
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw ToolError(
            code: "INVALID_ARGS",
            message: "Could not decode arguments: \(error.localizedDescription)"
        )
    }
}

/// Wraps a backend error message so we can return `Result<T, BackendError>` without
/// needing to make `String: Error` (which is invasive at the module level).
struct BackendError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - HTTP

let userAgents = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
]

private func httpRequest(
    url: String,
    method: String = "GET",
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 8
) -> (status: Int, data: Data?, error: String?) {
    guard let u = URL(string: url) else { return (0, nil, "Invalid URL: \(url)") }
    var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    req.httpMethod = method
    req.httpBody = body

    var combined: [String: String] = [
        "User-Agent": userAgents.randomElement() ?? userAgents[0],
        "Accept-Language": "en-US,en;q=0.9",
    ]
    for (k, v) in headers { combined[k] = v }
    for (k, v) in combined { req.setValue(v, forHTTPHeaderField: k) }

    let semaphore = DispatchSemaphore(value: 0)
    var status = 0
    var data: Data?
    var error: String?
    let task = URLSession.shared.dataTask(with: req) { d, r, e in
        if let e = e { error = e.localizedDescription }
        data = d
        if let http = r as? HTTPURLResponse { status = http.statusCode }
        semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
        // URLSession callback may still fire later, but cancelling lets the system free the socket.
        task.cancel()
        return (0, nil, error ?? "request timed out after \(Int(timeout))s")
    }
    return (status, data, error)
}

// MARK: - HTML helpers

func urlEncode(_ s: String) -> String {
    return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}

func decodeHTMLEntities(_ s: String) -> String {
    var result = s
    let named: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/"),
        ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
        ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
    ]
    for (entity, replacement) in named {
        result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }
    if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);", options: []) {
        let nsResult = NSMutableString(string: result)
        let matches = regex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()
        for match in matches {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let raw = String(result[range])
            let scalar: UInt32?
            if raw.hasPrefix("x") || raw.hasPrefix("X") {
                scalar = UInt32(raw.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(raw)
            }
            if let s = scalar, let u = UnicodeScalar(s) {
                nsResult.replaceCharacters(in: match.range, with: String(u))
            }
        }
        result = nsResult as String
    }
    return result
}

func stripHTML(_ html: String) -> String {
    var t = html
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
    }
    return decodeHTMLEntities(t)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func sourceDomain(of urlStr: String) -> String? {
    guard let u = URL(string: urlStr), let host = u.host else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// DDG often wraps result URLs with `?uddg=<encoded-url>`. Unwrap to the real target.
func unwrapDDG(_ url: String) -> String {
    guard url.contains("uddg="),
        let comp = URLComponents(string: url.hasPrefix("/") ? "https://duckduckgo.com\(url)" : url),
        let item = comp.queryItems?.first(where: { $0.name == "uddg" }),
        let value = item.value,
        let decoded = value.removingPercentEncoding
    else { return url }
    return decoded
}

// MARK: - Result types

struct SearchHit {
    var title: String
    var url: String
    var snippet: String
    var published_date: String?
    var source_domain: String?
    var engine: String

    func toDict(rank: Int) -> [String: Any] {
        var d: [String: Any] = [
            "rank": rank,
            "title": title,
            "url": url,
            "snippet": snippet,
            "engine": engine,
        ]
        if let date = published_date { d["published_date"] = date }
        if let dom = source_domain ?? sourceDomain(of: url) { d["source_domain"] = dom }
        return d
    }
}

struct ImageHit {
    var title: String
    var url: String
    var image_url: String
    var thumbnail_url: String?
    var width: Int?
    var height: Int?
    var source_domain: String?
    var engine: String

    func toDict(rank: Int) -> [String: Any] {
        var d: [String: Any] = [
            "rank": rank,
            "title": title,
            "url": url,
            "image_url": image_url,
            "engine": engine,
        ]
        if let t = thumbnail_url { d["thumbnail_url"] = t }
        if let w = width { d["width"] = w }
        if let h = height { d["height"] = h }
        if let dom = source_domain ?? sourceDomain(of: url) { d["source_domain"] = dom }
        return d
    }
}

enum Vertical: String {
    case web, news
}

// MARK: - Backend selection

struct SearchParams {
    let query: String
    let max_results: Int
    let offset: Int
    let site: String?
    let filetype: String?
    let time_range: String?  // "d" | "w" | "m" | "y" | nil
    let region: String?
    let provider: String?
    let secrets: [String: String]
    let vertical: Vertical
}

func augmentedQuery(_ p: SearchParams) -> String {
    var q = p.query
    if let site = p.site, !site.isEmpty { q += " site:\(site)" }
    if let ft = p.filetype, !ft.isEmpty { q += " filetype:\(ft)" }
    return q
}

// MARK: - Backend implementations (web/news)

private func runBackend(_ provider: String, params: SearchParams) -> Result<[SearchHit], BackendError> {
    switch provider {
    case "tavily": return tavilySearch(params)
    case "brave_api": return braveAPISearch(params)
    case "serper": return serperSearch(params)
    case "google_cse": return googleCSESearch(params)
    case "kagi": return kagiSearch(params)
    case "you": return youSearch(params)
    case "ddg": return ddgScrape(params)
    case "brave_html": return braveScrape(params)
    case "bing_html": return bingScrape(params)
    default: return .failure(BackendError("Unknown provider: \(provider)"))
    }
}

// --- API backends ---

private func tavilySearch(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    guard let key = p.secrets["TAVILY_API_KEY"] else { return .failure(BackendError("TAVILY_API_KEY not configured")) }
    var body: [String: Any] = [
        "api_key": key,
        "query": augmentedQuery(p),
        "max_results": p.max_results,
        "search_depth": "basic",
        "topic": p.vertical == .news ? "news" : "general",
    ]
    if let tr = mapTavilyTime(p.time_range) { body["time_range"] = tr }
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
        return .failure(BackendError("Failed to encode Tavily request"))
    }
    let res = httpRequest(
        url: "https://api.tavily.com/search",
        method: "POST",
        headers: ["Content-Type": "application/json"],
        body: bodyData,
        timeout: 15
    )
    if let err = res.error { return .failure(BackendError("Tavily: \(err)")) }
    guard res.status == 200, let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = json["results"] as? [[String: Any]]
    else { return .failure(BackendError("Tavily returned status \(res.status)")) }

    let hits = arr.prefix(p.max_results).map { item -> SearchHit in
        SearchHit(
            title: (item["title"] as? String) ?? "",
            url: (item["url"] as? String) ?? "",
            snippet: (item["content"] as? String) ?? "",
            published_date: item["published_date"] as? String,
            source_domain: nil,
            engine: "tavily"
        )
    }
    return .success(Array(hits))
}

func mapTavilyTime(_ tr: String?) -> String? {
    switch tr?.lowercased() {
    case "d", "day": return "day"
    case "w", "week": return "week"
    case "m", "month": return "month"
    case "y", "year": return "year"
    default: return nil
    }
}

private func braveAPISearch(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    guard let key = p.secrets["BRAVE_SEARCH_API_KEY"] else {
        return .failure(BackendError("BRAVE_SEARCH_API_KEY not configured"))
    }
    var url =
        (p.vertical == .news
            ? "https://api.search.brave.com/res/v1/news/search"
            : "https://api.search.brave.com/res/v1/web/search")
    var qs = "q=\(urlEncode(augmentedQuery(p)))&count=\(p.max_results)&offset=\(p.offset)"
    if let tr = mapBraveTime(p.time_range) { qs += "&freshness=\(tr)" }
    url += "?" + qs
    let res = httpRequest(
        url: url,
        headers: ["X-Subscription-Token": key, "Accept": "application/json"],
        timeout: 15
    )
    if let err = res.error { return .failure(BackendError("Brave API: \(err)")) }
    guard res.status == 200, let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .failure(BackendError("Brave API returned status \(res.status)")) }

    let resultsKey = p.vertical == .news ? "results" : "web"
    let items: [[String: Any]]
    if p.vertical == .news, let arr = json[resultsKey] as? [[String: Any]] {
        items = arr
    } else if let web = json["web"] as? [String: Any], let arr = web["results"] as? [[String: Any]] {
        items = arr
    } else {
        return .success([])
    }
    let hits = items.prefix(p.max_results).map { item -> SearchHit in
        SearchHit(
            title: (item["title"] as? String) ?? "",
            url: (item["url"] as? String) ?? "",
            snippet: (item["description"] as? String) ?? "",
            published_date: item["page_age"] as? String ?? item["age"] as? String,
            source_domain: nil,
            engine: "brave_api"
        )
    }
    return .success(Array(hits))
}

func mapBraveTime(_ tr: String?) -> String? {
    switch tr?.lowercased() {
    case "d", "day": return "pd"
    case "w", "week": return "pw"
    case "m", "month": return "pm"
    case "y", "year": return "py"
    default: return nil
    }
}

private func serperSearch(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    guard let key = p.secrets["SERPER_API_KEY"] else { return .failure(BackendError("SERPER_API_KEY not configured")) }
    var body: [String: Any] = [
        "q": augmentedQuery(p),
        "num": p.max_results,
        "page": (p.offset / max(1, p.max_results)) + 1,
    ]
    if let tr = mapSerperTime(p.time_range) { body["tbs"] = tr }
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
        return .failure(BackendError("Failed to encode Serper request"))
    }
    let endpoint = p.vertical == .news ? "https://google.serper.dev/news" : "https://google.serper.dev/search"
    let res = httpRequest(
        url: endpoint,
        method: "POST",
        headers: ["Content-Type": "application/json", "X-API-KEY": key],
        body: bodyData,
        timeout: 15
    )
    if let err = res.error { return .failure(BackendError("Serper: \(err)")) }
    guard res.status == 200, let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .failure(BackendError("Serper returned status \(res.status)")) }

    let key2 = p.vertical == .news ? "news" : "organic"
    guard let arr = json[key2] as? [[String: Any]] else { return .success([]) }
    let hits = arr.prefix(p.max_results).map { item -> SearchHit in
        SearchHit(
            title: (item["title"] as? String) ?? "",
            url: (item["link"] as? String) ?? "",
            snippet: (item["snippet"] as? String) ?? "",
            published_date: item["date"] as? String,
            source_domain: item["source"] as? String,
            engine: "serper"
        )
    }
    return .success(Array(hits))
}

func mapSerperTime(_ tr: String?) -> String? {
    switch tr?.lowercased() {
    case "d", "day": return "qdr:d"
    case "w", "week": return "qdr:w"
    case "m", "month": return "qdr:m"
    case "y", "year": return "qdr:y"
    default: return nil
    }
}

private func googleCSESearch(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    guard let key = p.secrets["GOOGLE_CSE_API_KEY"], let cx = p.secrets["GOOGLE_CSE_CX"] else {
        return .failure(BackendError("GOOGLE_CSE_API_KEY and GOOGLE_CSE_CX must both be configured"))
    }
    let start = p.offset + 1
    var url = "https://www.googleapis.com/customsearch/v1?key=\(urlEncode(key))&cx=\(urlEncode(cx))"
    url += "&q=\(urlEncode(augmentedQuery(p)))&num=\(min(p.max_results, 10))&start=\(start)"
    if let tr = mapCSETime(p.time_range) { url += "&dateRestrict=\(tr)" }
    if p.vertical == .news { url += "&searchType=&tbm=nws" }
    let res = httpRequest(url: url, headers: ["Accept": "application/json"], timeout: 15)
    if let err = res.error { return .failure(BackendError("Google CSE: \(err)")) }
    guard res.status == 200, let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let items = json["items"] as? [[String: Any]]
    else { return .failure(BackendError("Google CSE returned status \(res.status)")) }

    let hits = items.prefix(p.max_results).map { item -> SearchHit in
        SearchHit(
            title: (item["title"] as? String) ?? "",
            url: (item["link"] as? String) ?? "",
            snippet: (item["snippet"] as? String) ?? "",
            published_date: nil,
            source_domain: item["displayLink"] as? String,
            engine: "google_cse"
        )
    }
    return .success(Array(hits))
}

func mapCSETime(_ tr: String?) -> String? {
    switch tr?.lowercased() {
    case "d", "day": return "d1"
    case "w", "week": return "w1"
    case "m", "month": return "m1"
    case "y", "year": return "y1"
    default: return nil
    }
}

private func kagiSearch(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    guard let key = p.secrets["KAGI_API_KEY"] else { return .failure(BackendError("KAGI_API_KEY not configured")) }
    var url = "https://kagi.com/api/v0/search?q=\(urlEncode(augmentedQuery(p)))&limit=\(p.max_results)"
    if p.offset > 0 { url += "&offset=\(p.offset)" }
    let res = httpRequest(url: url, headers: ["Authorization": "Bot \(key)"], timeout: 15)
    if let err = res.error { return .failure(BackendError("Kagi: \(err)")) }
    guard res.status == 200, let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = json["data"] as? [[String: Any]]
    else { return .failure(BackendError("Kagi returned status \(res.status)")) }

    let hits = arr.compactMap { item -> SearchHit? in
        // Kagi returns mixed types; only include normal results (t==0).
        guard let t = item["t"] as? Int, t == 0 else { return nil }
        return SearchHit(
            title: (item["title"] as? String) ?? "",
            url: (item["url"] as? String) ?? "",
            snippet: (item["snippet"] as? String) ?? "",
            published_date: item["published"] as? String,
            source_domain: nil,
            engine: "kagi"
        )
    }
    return .success(Array(hits.prefix(p.max_results)))
}

private func youSearch(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    guard let key = p.secrets["YOU_API_KEY"] else { return .failure(BackendError("YOU_API_KEY not configured")) }
    let endpoint =
        p.vertical == .news
        ? "https://api.ydc-index.io/news"
        : "https://api.ydc-index.io/search"
    var url = "\(endpoint)?query=\(urlEncode(augmentedQuery(p)))&num_web_results=\(p.max_results)"
    if let tr = mapYouTime(p.time_range) { url += "&recency=\(tr)" }
    let res = httpRequest(url: url, headers: ["X-API-Key": key, "Accept": "application/json"], timeout: 15)
    if let err = res.error { return .failure(BackendError("You.com: \(err)")) }
    guard res.status == 200, let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .failure(BackendError("You.com returned status \(res.status)")) }

    let arr: [[String: Any]]
    if p.vertical == .news, let news = json["news"] as? [String: Any], let r = news["results"] as? [[String: Any]] {
        arr = r
    } else if let hits = json["hits"] as? [[String: Any]] {
        arr = hits
    } else {
        arr = []
    }
    let hits = arr.prefix(p.max_results).map { item -> SearchHit in
        SearchHit(
            title: (item["title"] as? String) ?? "",
            url: (item["url"] as? String) ?? "",
            snippet: (item["description"] as? String) ?? (item["snippet"] as? String) ?? "",
            published_date: item["date_published"] as? String ?? item["age"] as? String,
            source_domain: nil,
            engine: "you"
        )
    }
    return .success(Array(hits))
}

func mapYouTime(_ tr: String?) -> String? {
    switch tr?.lowercased() {
    case "d", "day": return "day"
    case "w", "week": return "week"
    case "m", "month": return "month"
    case "y", "year": return "year"
    default: return nil
    }
}

// --- Free scraping backends ---

private func ddgScrape(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    var url = "https://html.duckduckgo.com/html/?q=\(urlEncode(augmentedQuery(p)))"
    if let region = p.region { url += "&kl=\(urlEncode(region))" } else { url += "&kl=wt-wt" }
    if p.vertical == .news { url += "&iar=news" }
    if let df = mapDDGTime(p.time_range) { url += "&df=\(df)" }
    let res = httpRequest(url: url)
    if let err = res.error { return .failure(BackendError("DDG: \(err)")) }
    guard let data = res.data, let html = String(data: data, encoding: .utf8) else {
        return .failure(BackendError("DDG: empty response"))
    }
    return .success(parseDDGHTML(html, max: p.max_results))
}

func mapDDGTime(_ tr: String?) -> String? {
    switch tr?.lowercased() {
    case "d", "day": return "d"
    case "w", "week": return "w"
    case "m", "month": return "m"
    case "y", "year": return "y"
    default: return nil
    }
}

func parseDDGHTML(_ html: String, max: Int) -> [SearchHit] {
    var results: [SearchHit] = []

    let resultPattern =
        "<div\\s+class=\"result[^\"]*\"[\\s\\S]*?<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>(?:[\\s\\S]*?<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>([\\s\\S]*?)</a>)?"
    if let regex = try? NSRegularExpression(pattern: resultPattern, options: .caseInsensitive) {
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches.prefix(max) {
            guard let urlR = Range(m.range(at: 1), in: html),
                let titleR = Range(m.range(at: 2), in: html)
            else { continue }
            let url = unwrapDDG(decodeHTMLEntities(String(html[urlR])))
            let title = stripHTML(String(html[titleR]))
            var snippet = ""
            if m.numberOfRanges > 3, let r = Range(m.range(at: 3), in: html) {
                snippet = stripHTML(String(html[r]))
            }
            results.append(SearchHit(title: title, url: url, snippet: snippet, engine: "ddg"))
        }
    }

    // Lite fallback
    if results.isEmpty {
        let lite = "<a[^>]*class=\"result-link\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
        if let regex = try? NSRegularExpression(pattern: lite, options: .caseInsensitive) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for m in matches.prefix(max) {
                guard let urlR = Range(m.range(at: 1), in: html),
                    let titleR = Range(m.range(at: 2), in: html)
                else { continue }
                let url = unwrapDDG(decodeHTMLEntities(String(html[urlR])))
                results.append(
                    SearchHit(
                        title: stripHTML(String(html[titleR])),
                        url: url,
                        snippet: "",
                        engine: "ddg"
                    ))
            }
        }
    }

    return results
}

private func braveScrape(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    let endpoint =
        p.vertical == .news
        ? "https://search.brave.com/news?q=\(urlEncode(augmentedQuery(p)))"
        : "https://search.brave.com/search?q=\(urlEncode(augmentedQuery(p)))&source=web"
    let res = httpRequest(url: endpoint)
    if let err = res.error { return .failure(BackendError("Brave HTML: \(err)")) }
    guard let data = res.data, let html = String(data: data, encoding: .utf8) else {
        return .failure(BackendError("Brave HTML: empty response"))
    }
    if isLikelyChallengePage(html) {
        return .failure(BackendError("Brave HTML: challenge_page"))
    }
    return .success(parseBraveHTML(html, max: p.max_results))
}

/// Detects anti-bot interstitials and other useless responses (e.g. very small bodies that
/// only contain a captcha shell). Cheap pre-filter before regex parsing.
func isLikelyChallengePage(_ html: String) -> Bool {
    if html.count < 2048 { return true }
    let lc = html.lowercased()
    if lc.contains("captcha") || lc.contains("just a moment") || lc.contains("checking your browser") {
        return true
    }
    return false
}

/// Brave's modern (2026) markup wraps each result in `<div class="snippet ...">` with the
/// title link as `<a class="title ...">` and the snippet text as `<div class="description ...">`.
/// Ads come through the same wrapper but with `data-type="ad"` and `/a/redirect` hrefs;
/// we filter them out so they don't pollute organic results.
///
/// Sub-result ("deep link") shape:
///   <div class="snippet ...">
///     <a class="title ..." href="https://...">Title</a>
///     <div class="description ...">Snippet</div>
///   </div>
///
/// Main organic shape (with thumbnail / favicon scaffolding):
///   <div class="snippet ..." data-type="web" ...>
///     <div class="result-wrapper ...">
///       <a class="...l1" href="https://..."> ... favicon, site-name ... </a>
///       <a class="title search-snippet-title ..." href="https://...">Title</a>
///       <div class="description ...">Snippet</div>
///     </div>
///   </div>
func parseBraveHTML(_ html: String, max: Int) -> [SearchHit] {
    let chunks = sliceByClass(html, className: "snippet")
    if chunks.isEmpty { return parseBraveHTMLLegacy(html, max: max) }

    var hits: [SearchHit] = []
    for chunk in chunks {
        // Skip ad blocks: Brave routes ad URLs through `/a/redirect?...` and tags the wrapper.
        if chunk.contains("data-type=\"ad\"") || chunk.contains("/a/redirect?") {
            continue
        }
        // URL: prefer the title anchor's href; fall back to the headline (.l1) anchor;
        // last resort, any http(s) link inside the chunk.
        var url = firstAttr(in: chunk, tag: "a", className: "title", attr: "href")
        if url == nil { url = firstAttr(in: chunk, tag: "a", className: "l1", attr: "href") }
        if url == nil { url = firstHrefStartingWithHttp(in: chunk) }
        guard let rawURL = url, rawURL.hasPrefix("http") else { continue }

        let title = firstInnerByClass(in: chunk, className: "title") ?? ""
        let snippet = firstInnerByClass(in: chunk, className: "description") ?? ""
        let cleanedTitle = stripHTML(title)
        if cleanedTitle.isEmpty { continue }

        hits.append(
            SearchHit(
                title: cleanedTitle,
                url: decodeHTMLEntities(rawURL),
                snippet: stripHTML(snippet),
                engine: "brave_html"
            )
        )
        if hits.count >= max { break }
    }
    return hits
}

/// Fallback to the older selectors in case Brave switches markup back. Kept narrow on purpose.
private func parseBraveHTMLLegacy(_ html: String, max: Int) -> [SearchHit] {
    var hits: [SearchHit] = []
    let pattern =
        "<div[^>]*class=\"[^\"]*snippet[^\"]*\"[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>[\\s\\S]*?<div[^>]*class=\"[^\"]*title[^\"]*\"[^>]*>([\\s\\S]*?)</div>[\\s\\S]*?<div[^>]*class=\"[^\"]*snippet-description[^\"]*\"[^>]*>([\\s\\S]*?)</div>"
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches.prefix(max) {
            guard let urlR = Range(m.range(at: 1), in: html),
                let titleR = Range(m.range(at: 2), in: html),
                let snipR = Range(m.range(at: 3), in: html)
            else { continue }
            let url = decodeHTMLEntities(String(html[urlR]))
            guard url.hasPrefix("http") else { continue }
            hits.append(
                SearchHit(
                    title: stripHTML(String(html[titleR])),
                    url: url,
                    snippet: stripHTML(String(html[snipR])),
                    engine: "brave_html"
                ))
        }
    }
    return hits
}

// MARK: - Generic class-based HTML helpers (used by Brave parser)

/// Slice HTML on the *opening* tag of any element whose class list contains `className`
/// as a whitespace-delimited token (CSS-class semantics, so `"snippet"` matches
/// `class="snippet svelte-abc"` but NOT `class="snippet-description"`).
/// Each returned chunk runs from one such opening tag up to (but not including) the next one,
/// which is good enough for shallow search-result blocks.
func sliceByClass(_ html: String, className: String) -> [String] {
    let pattern = "<[a-zA-Z][a-zA-Z0-9]*\\s[^>]*class=\"([^\"]*)\""
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
    let nsr = NSRange(html.startIndex..., in: html)
    let matches = regex.matches(in: html, range: nsr)
    if matches.isEmpty { return [] }

    let nsHtml = html as NSString
    var validStarts: [Int] = []
    for m in matches {
        let classAttrRange = m.range(at: 1)
        if classAttrRange.location == NSNotFound { continue }
        let classes = nsHtml.substring(with: classAttrRange)
            .split(whereSeparator: { $0.isWhitespace })
        if classes.contains(where: { $0 == Substring(className) }) {
            validStarts.append(m.range.location)
        }
    }
    if validStarts.isEmpty { return [] }
    var chunks: [String] = []
    for (i, start) in validStarts.enumerated() {
        let end = i + 1 < validStarts.count ? validStarts[i + 1] : nsHtml.length
        let len = end - start
        if len <= 0 { continue }
        chunks.append(nsHtml.substring(with: NSRange(location: start, length: len)))
    }
    return chunks
}

/// Returns the first `attr` value of a `tag` whose class list contains `className`.
func firstAttr(in html: String, tag: String, className: String, attr: String) -> String? {
    let cls = NSRegularExpression.escapedPattern(for: className)
    let attrEsc = NSRegularExpression.escapedPattern(for: attr)
    // Match either order: class=...href=... or href=...class=...
    let order1 =
        "<\(tag)\\b[^>]*class=\"[^\"]*\\b\(cls)\\b[^\"]*\"[^>]*\\b\(attrEsc)=\"([^\"]+)\""
    let order2 =
        "<\(tag)\\b[^>]*\\b\(attrEsc)=\"([^\"]+)\"[^>]*class=\"[^\"]*\\b\(cls)\\b"
    for pattern in [order1, order2] {
        if let v = firstGroup(in: html, pattern: pattern) { return v }
    }
    return nil
}

/// Returns the inner-HTML of the first element whose class list contains `className`.
/// Tag-agnostic; handles `<div>`, `<span>`, etc.
func firstInnerByClass(in html: String, className: String) -> String? {
    let cls = NSRegularExpression.escapedPattern(for: className)
    let pattern =
        "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*class=\"[^\"]*\\b\(cls)\\b[^\"]*\"[^>]*>([\\s\\S]*?)</\\1>"
    return firstGroup(in: html, pattern: pattern, group: 2)
}

/// First http/https `href` value found anywhere in `html`.
func firstHrefStartingWithHttp(in html: String) -> String? {
    return firstGroup(in: html, pattern: "href=\"(https?://[^\"]+)\"")
}

private func bingScrape(_ p: SearchParams) -> Result<[SearchHit], BackendError> {
    let endpoint =
        p.vertical == .news
        ? "https://www.bing.com/news/search?q=\(urlEncode(augmentedQuery(p)))&count=\(p.max_results)"
        : "https://www.bing.com/search?q=\(urlEncode(augmentedQuery(p)))&count=\(p.max_results)"
    let res = httpRequest(url: endpoint)
    if let err = res.error { return .failure(BackendError("Bing HTML: \(err)")) }
    guard let data = res.data, let html = String(data: data, encoding: .utf8) else {
        return .failure(BackendError("Bing HTML: empty response"))
    }
    return .success(parseBingHTML(html, max: p.max_results))
}

func parseBingHTML(_ html: String, max: Int) -> [SearchHit] {
    var hits: [SearchHit] = []
    let pattern =
        "<li[^>]*class=\"b_algo\"[^>]*>[\\s\\S]*?<h2>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>[\\s\\S]*?</h2>(?:[\\s\\S]*?<p[^>]*>([\\s\\S]*?)</p>)?"
    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches.prefix(max) {
            guard let urlR = Range(m.range(at: 1), in: html),
                let titleR = Range(m.range(at: 2), in: html)
            else { continue }
            var snippet = ""
            if m.numberOfRanges > 3, let r = Range(m.range(at: 3), in: html) {
                snippet = stripHTML(String(html[r]))
            }
            hits.append(
                SearchHit(
                    title: stripHTML(String(html[titleR])),
                    url: decodeHTMLEntities(String(html[urlR])),
                    snippet: snippet,
                    engine: "bing_html"
                ))
        }
    }
    return hits
}

// MARK: - Image search (DDG only for free; APIs as fallback)

private func runImageSearch(_ params: SearchParams) -> Result<[ImageHit], BackendError> {
    // Free DDG image search via VQD token
    let q = urlEncode(params.query)
    let bootstrap = httpRequest(url: "https://duckduckgo.com/?q=\(q)&iax=images&ia=images")
    guard let bootData = bootstrap.data, let bootHtml = String(data: bootData, encoding: .utf8) else {
        return .failure(BackendError("DDG image bootstrap failed"))
    }
    let vqdRegex = try? NSRegularExpression(pattern: "vqd=([\"'])([^\"']+)\\1", options: [])
    var vqd: String?
    if let regex = vqdRegex,
        let m = regex.firstMatch(in: bootHtml, range: NSRange(bootHtml.startIndex..., in: bootHtml)),
        let r = Range(m.range(at: 2), in: bootHtml)
    {
        vqd = String(bootHtml[r])
    }
    guard let vqd = vqd else { return .failure(BackendError("Could not obtain DDG VQD token")) }

    let url = "https://duckduckgo.com/i.js?l=wt-wt&o=json&q=\(q)&vqd=\(vqd)&p=1"
    let res = httpRequest(url: url, headers: ["Referer": "https://duckduckgo.com/"])
    guard let data = res.data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = json["results"] as? [[String: Any]]
    else { return .failure(BackendError("DDG image API failed (status \(res.status))")) }

    let hits = arr.prefix(params.max_results).map { item -> ImageHit in
        ImageHit(
            title: (item["title"] as? String) ?? "",
            url: (item["url"] as? String) ?? "",
            image_url: (item["image"] as? String) ?? "",
            thumbnail_url: item["thumbnail"] as? String,
            width: item["width"] as? Int,
            height: item["height"] as? Int,
            source_domain: item["source"] as? String,
            engine: "ddg"
        )
    }
    return .success(Array(hits))
}

// MARK: - Cascade + dedupe

/// Backends that go over the network for free (no API key). Raced in parallel with a wall-clock budget.
let freeProviderIds: [String] = ["ddg", "brave_html", "bing_html"]

/// Paid backends, in descending priority order. Tried sequentially because each call costs quota.
let paidProviderPriority: [String] = ["tavily", "brave_api", "serper", "google_cse", "kagi", "you"]

let validProviderIds: Set<String> = Set(freeProviderIds + paidProviderPriority)

func providerHasSecrets(_ id: String, secrets: [String: String]) -> Bool {
    switch id {
    case "tavily": return secrets["TAVILY_API_KEY"] != nil
    case "brave_api": return secrets["BRAVE_SEARCH_API_KEY"] != nil
    case "serper": return secrets["SERPER_API_KEY"] != nil
    case "google_cse": return secrets["GOOGLE_CSE_API_KEY"] != nil && secrets["GOOGLE_CSE_CX"] != nil
    case "kagi": return secrets["KAGI_API_KEY"] != nil
    case "you": return secrets["YOU_API_KEY"] != nil
    default: return false
    }
}

/// Builds the user-visible hint for a `NO_RESULTS` failure. The advice differs depending
/// on whether any paid API keys are configured, since "configure an API key" is useless
/// advice when the user already has one and it's the one that just failed.
func noResultsHint(secrets: [String: String]) -> String {
    let configured = paidProviderPriority.filter { providerHasSecrets($0, secrets: secrets) }
    if configured.isEmpty {
        return
            "Try a broader query or drop site:/filetype:/time_range. For better recall, configure an API key (e.g. TAVILY_API_KEY) in plugin settings."
    }
    return
        "Tried configured backends [\(configured.joined(separator: ", "))] and free fallbacks. Try a broader query or check that your API key is still valid."
}

/// Drops invalid `provider` and `region` values into nil, recording a warning instead of erroring.
/// Agents routinely invent values like `"auto"` or `"bing"`; better to silently fall back to
/// auto-cascade than to fail the whole search.
func sanitizeProvider(_ raw: String?, warnings: inout [String]) -> String? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    let lc = raw.lowercased()
    if validProviderIds.contains(lc) { return lc }
    let valid = validProviderIds.sorted().joined(separator: ", ")
    warnings.append("Ignored unknown provider '\(raw)'; used auto-cascade. Valid: \(valid).")
    return nil
}

func sanitizeRegion(_ raw: String?, warnings: inout [String]) -> String? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    if raw.range(of: "^[A-Za-z]{2}-[A-Za-z]{2}$", options: .regularExpression) != nil {
        return raw.lowercased()
    }
    warnings.append("Ignored invalid region '\(raw)'; expected format 'xx-yy' (e.g. 'us-en').")
    return nil
}

/// Race the free scrapers in parallel under a wall-clock budget.
/// Early-exits as soon as any provider returns >= 3 hits to keep p50 latency low.
private func runFreeCascadeParallel(
    _ params: SearchParams,
    budgetSeconds: TimeInterval
) -> (hits: [SearchHit], attempts: [[String: Any]], usedProvider: String?) {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = freeProviderIds.count

    let lock = NSLock()
    var done: [(String, Result<[SearchHit], BackendError>)] = []
    let signal = DispatchSemaphore(value: 0)
    var earlyExitFired = false

    let providers = freeProviderIds
    for provider in providers {
        queue.addOperation {
            let r = runBackend(provider, params: params)
            lock.lock()
            done.append((provider, r))
            var shouldSignal = false
            if case .success(let h) = r, h.count >= 3, !earlyExitFired {
                earlyExitFired = true
                shouldSignal = true
            } else if done.count == providers.count {
                shouldSignal = true
            }
            lock.unlock()
            if shouldSignal { signal.signal() }
        }
    }

    _ = signal.wait(timeout: .now() + .milliseconds(Int(budgetSeconds * 1000)))

    lock.lock()
    let snapshot = done
    lock.unlock()

    var attempts: [[String: Any]] = []
    var hits: [SearchHit] = []
    var seen = Set<String>()
    var bestProvider: String?

    let completed = Set(snapshot.map { $0.0 })
    for p in providers where !completed.contains(p) {
        attempts.append(["provider": p, "ok": false, "error": "timeout"])
    }
    for (provider, result) in snapshot {
        switch result {
        case .success(let h):
            attempts.append(["provider": provider, "ok": true, "count": h.count])
            for hit in h {
                let key = hit.url.lowercased()
                if key.isEmpty || seen.contains(key) { continue }
                seen.insert(key)
                hits.append(hit)
                if bestProvider == nil { bestProvider = provider }
            }
        case .failure(let err):
            attempts.append(["provider": provider, "ok": false, "error": err.message])
        }
    }
    return (hits, attempts, bestProvider)
}

func runWebOrNews(_ params: SearchParams) throws -> [String: Any] {
    var attempts: [[String: Any]] = []
    var deduped: [SearchHit] = []
    var seen = Set<String>()
    var usedProvider: String?

    func ingest(_ hits: [SearchHit]) {
        for h in hits {
            let key = h.url.lowercased()
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            deduped.append(h)
        }
    }

    if let pinned = params.provider {
        // Single-provider mode. Reachable only from direct dylib callers (CLI, tests,
        // power-user Swift apps): the agent JSON schema no longer exposes `provider`,
        // so agent-driven calls always fall through to the auto-cascade below.
        // Caller already validated it against `validProviderIds`.
        let result = runBackend(pinned, params: params)
        switch result {
        case .success(let h):
            attempts.append(["provider": pinned, "ok": true, "count": h.count])
            if !h.isEmpty {
                ingest(h)
                usedProvider = pinned
            }
        case .failure(let err):
            attempts.append(["provider": pinned, "ok": false, "error": err.message])
        }
    } else {
        // Auto-cascade: paid (one at a time, in priority order) → free (in parallel).
        for provider in paidProviderPriority where providerHasSecrets(provider, secrets: params.secrets) {
            let result = runBackend(provider, params: params)
            switch result {
            case .success(let h):
                attempts.append(["provider": provider, "ok": true, "count": h.count])
                if !h.isEmpty {
                    ingest(h)
                    usedProvider = provider
                }
            case .failure(let err):
                attempts.append(["provider": provider, "ok": false, "error": err.message])
            }
            if !deduped.isEmpty { break }
        }
        if deduped.isEmpty {
            let parallel = runFreeCascadeParallel(params, budgetSeconds: 12)
            attempts.append(contentsOf: parallel.attempts)
            ingest(parallel.hits)
            if usedProvider == nil { usedProvider = parallel.usedProvider }
        }
    }

    if deduped.isEmpty {
        // `attempts[]` already records every provider that was tried and what it returned,
        // so we don't need a top-level "provider" key in the failure payload.
        let payload: [String: Any] = [
            "query": params.query,
            "results": [],
            "count": 0,
            "attempts": attempts,
        ]
        throw ToolError(
            code: "NO_RESULTS",
            message: "No results from any backend.",
            hint: noResultsHint(secrets: params.secrets),
            data: payload
        )
    }

    var out: [String: Any] = [
        "query": params.query,
        "provider": usedProvider ?? "",
        "results": deduped.enumerated().map { $0.element.toDict(rank: $0.offset + 1) },
        "count": deduped.count,
        "attempts": attempts,
    ]
    if deduped.count == params.max_results {
        out["next_offset"] = params.offset + params.max_results
    }
    return out
}

// MARK: - Args & secrets

struct SecretsBlock: Decodable { let _secrets: [String: String]? }

func extractSecrets(_ raw: String) -> [String: String] {
    if let data = raw.data(using: .utf8),
        let block = try? JSONDecoder().decode(SecretsBlock.self, from: data),
        let s = block._secrets
    {
        return s
    }
    return [:]
}

struct WebArgs: Decodable {
    let query: String
    let max_results: Int?
    let offset: Int?
    let site: String?
    let filetype: String?
    let time_range: String?
    let region: String?
    let provider: String?
}

struct ImageArgs: Decodable {
    let query: String
    let max_results: Int?
}

// MARK: - Tools

/// Runs `runWebOrNews` while attaching `warnings` to a NO_RESULTS error envelope so
/// the agent can see why we returned nothing (e.g. "ignored unknown provider").
private func runWebOrNewsAttachingWarnings(_ params: SearchParams, warnings: [String]) throws -> [String: Any] {
    do {
        return try runWebOrNews(params)
    } catch let err as ToolError where err.code == "NO_RESULTS" {
        var data = err.data ?? [:]
        if !warnings.isEmpty { data["warnings"] = warnings }
        throw ToolError(code: err.code, message: err.message, hint: err.hint, data: data)
    }
}

/// Builds `SearchParams` from a decoded `WebArgs`, sanitizing user-supplied `provider`
/// and `region` and applying caller-specific defaults (e.g. news defaults `time_range="w"`).
/// Throws `INVALID_ARGS` when the query is empty so each tool doesn't have to repeat the check.
private func buildWebSearchParams(
    from args: WebArgs,
    rawPayload: String,
    vertical: Vertical,
    defaultTimeRange: String? = nil
) throws -> (params: SearchParams, warnings: [String]) {
    guard !args.query.isEmpty else {
        throw ToolError(code: "INVALID_ARGS", message: "Required: 'query' (string).")
    }
    var warnings: [String] = []
    let provider = sanitizeProvider(args.provider, warnings: &warnings)
    let region = sanitizeRegion(args.region, warnings: &warnings)
    let params = SearchParams(
        query: args.query,
        max_results: max(1, min(args.max_results ?? 10, 50)),
        offset: max(0, args.offset ?? 0),
        site: args.site,
        filetype: args.filetype,
        time_range: args.time_range ?? defaultTimeRange,
        region: region,
        provider: provider,
        secrets: extractSecrets(rawPayload),
        vertical: vertical
    )
    return (params, warnings)
}

private struct SearchTool {
    static let name = "search"

    func run(args: String) throws -> ToolOutcome {
        let parsed: WebArgs = try decodeArgs(args)
        let (params, warnings) = try buildWebSearchParams(from: parsed, rawPayload: args, vertical: .web)
        let data = try runWebOrNewsAttachingWarnings(params, warnings: warnings)
        return ToolOutcome(data, warnings: warnings)
    }
}

private struct SearchNewsTool {
    static let name = "search_news"

    func run(args: String) throws -> ToolOutcome {
        let parsed: WebArgs = try decodeArgs(args)
        let (params, warnings) = try buildWebSearchParams(
            from: parsed,
            rawPayload: args,
            vertical: .news,
            defaultTimeRange: "w"
        )
        let data = try runWebOrNewsAttachingWarnings(params, warnings: warnings)
        return ToolOutcome(data, warnings: warnings)
    }
}

private struct SearchImagesTool {
    static let name = "search_images"

    func run(args: String) throws -> ToolOutcome {
        let parsed: ImageArgs = try decodeArgs(args)
        guard !parsed.query.isEmpty else {
            throw ToolError(code: "INVALID_ARGS", message: "Required: 'query' (string).")
        }
        let params = SearchParams(
            query: parsed.query,
            max_results: max(1, min(parsed.max_results ?? 20, 100)),
            offset: 0,
            site: nil, filetype: nil, time_range: nil, region: nil, provider: nil,
            secrets: extractSecrets(args),
            vertical: .web
        )
        switch runImageSearch(params) {
        case .success(let imgs):
            let data: [String: Any] = [
                "query": parsed.query,
                "provider": "ddg",
                "results": imgs.enumerated().map { $0.element.toDict(rank: $0.offset + 1) },
                "count": imgs.count,
            ]
            return ToolOutcome(data)
        case .failure(let err):
            throw ToolError(
                code: "PROVIDER_UNAVAILABLE",
                message: err.message,
                hint: "DDG image search is brittle; try again or use a different query."
            )
        }
    }
}

private struct SearchAndExtractTool {
    static let name = "search_and_extract"

    func run(args: String) throws -> ToolOutcome {
        struct Args: Decodable {
            let query: String
            let max_results: Int?
            let extract_count: Int?
            let provider: String?
            let time_range: String?
            let site: String?
            let filetype: String?
            let timeout: Double?
        }
        let parsed: Args = try decodeArgs(args)
        guard !parsed.query.isEmpty else {
            throw ToolError(code: "INVALID_ARGS", message: "Required: 'query' (string).")
        }
        let maxResults = max(1, min(parsed.max_results ?? 5, 20))
        let extractCount = max(1, min(parsed.extract_count ?? 3, maxResults))

        var warnings: [String] = []
        let provider = sanitizeProvider(parsed.provider, warnings: &warnings)

        let webParams = SearchParams(
            query: parsed.query,
            max_results: maxResults,
            offset: 0,
            site: parsed.site,
            filetype: parsed.filetype,
            time_range: parsed.time_range,
            region: nil,
            provider: provider,
            secrets: extractSecrets(args),
            vertical: .web
        )
        let webOut = try runWebOrNewsAttachingWarnings(webParams, warnings: warnings)
        guard let results = webOut["results"] as? [[String: Any]] else {
            return ToolOutcome(webOut, warnings: warnings)
        }

        var enriched: [[String: Any]] = []
        let timeout = parsed.timeout ?? 25
        for (i, hit) in results.enumerated() {
            var entry = hit
            if i < extractCount, let url = hit["url"] as? String {
                if let extracted = extractReadability(url: url, timeout: timeout) {
                    entry["title"] = extracted["title"] ?? entry["title"] ?? NSNull()
                    entry["markdown"] = extracted["markdown"] ?? ""
                    entry["word_count"] = extracted["word_count"] ?? 0
                    entry["byline"] = extracted["byline"] ?? NSNull()
                    entry["lang"] = extracted["lang"] ?? NSNull()
                    entry["extracted"] = true
                } else {
                    entry["extracted"] = false
                }
            } else {
                entry["extracted"] = false
            }
            enriched.append(entry)
        }

        var out = webOut
        out["results"] = enriched
        return ToolOutcome(out, warnings: warnings)
    }
}

// Lightweight Readability extraction used only by search_and_extract.
private func extractReadability(url: String, timeout: TimeInterval) -> [String: Any]? {
    let res = httpRequest(
        url: url,
        headers: [
            "Accept": "text/html,application/xhtml+xml"
        ],
        timeout: timeout
    )
    guard let data = res.data, let html = String(data: data, encoding: .utf8) else {
        return nil
    }

    let title = firstGroup(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>")
        .map { decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    let byline =
        metaContent(in: html, name: "author")
        ?? metaContent(in: html, property: "article:author")
    let lang = firstGroup(in: html, pattern: "<html[^>]*\\blang=[\"']([^\"']+)[\"']")

    var content = stripBlocks(
        html,
        tags: [
            "script", "style", "noscript", "template", "svg", "iframe", "header", "footer", "nav", "aside", "form",
            "button",
        ])
    if let main = pickMainContainer(content) { content = main }
    let markdown = htmlToMarkdown(content)
    let wordCount = markdown.split(whereSeparator: { $0.isWhitespace }).count

    var d: [String: Any] = ["markdown": markdown, "word_count": wordCount]
    if let t = title { d["title"] = t }
    if let b = byline { d["byline"] = b }
    if let l = lang { d["lang"] = l }
    return d
}

func firstGroup(in s: String, pattern: String, group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
        match.numberOfRanges > group,
        let range = Range(match.range(at: group), in: s)
    else { return nil }
    return String(s[range])
}

func metaContent(in s: String, name: String? = nil, property: String? = nil) -> String? {
    if let name = name {
        let pattern = "<meta[^>]*\\bname=[\"']\(name)[\"'][^>]*\\bcontent=[\"']([^\"']*)[\"']"
        if let v = firstGroup(in: s, pattern: pattern) { return decodeHTMLEntities(v) }
    }
    if let property = property {
        let pattern = "<meta[^>]*\\bproperty=[\"']\(property)[\"'][^>]*\\bcontent=[\"']([^\"']*)[\"']"
        if let v = firstGroup(in: s, pattern: pattern) { return decodeHTMLEntities(v) }
    }
    return nil
}

func stripBlocks(_ html: String, tags: [String]) -> String {
    var out = html
    for tag in tags {
        if let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
            options: .caseInsensitive
        ) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
    }
    return out
}

func pickMainContainer(_ html: String) -> String? {
    for tag in ["article", "main"] {
        if let body = firstGroup(in: html, pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"), !body.isEmpty {
            return body
        }
    }
    return firstGroup(in: html, pattern: "<body[^>]*>([\\s\\S]*?)</body>")
}

func htmlToMarkdown(_ html: String) -> String {
    var s = html
    s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<hr[^>]*>", with: "\n\n---\n\n", options: .regularExpression)
    let blocks: [(String, String, String)] = [
        ("h1", "\n\n# ", "\n\n"), ("h2", "\n\n## ", "\n\n"),
        ("h3", "\n\n### ", "\n\n"), ("h4", "\n\n#### ", "\n\n"),
        ("h5", "\n\n##### ", "\n\n"), ("h6", "\n\n###### ", "\n\n"),
        ("blockquote", "\n\n> ", "\n\n"),
        ("p", "\n\n", "\n\n"),
        ("li", "\n- ", ""),
    ]
    for (tag, prefix, suffix) in blocks {
        s = s.replacingOccurrences(
            of: "<\(tag)\\b[^>]*>", with: prefix, options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</\(tag)>", with: suffix, options: [.regularExpression, .caseInsensitive])
    }
    let inlines: [(String, String)] = [
        ("strong", "**"), ("b", "**"),
        ("em", "*"), ("i", "*"),
        ("code", "`"),
    ]
    for (tag, marker) in inlines {
        s = s.replacingOccurrences(
            of: "<\(tag)\\b[^>]*>", with: marker, options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</\(tag)>", with: marker, options: [.regularExpression, .caseInsensitive])
    }
    s = s.replacingOccurrences(of: "<pre\\b[^>]*>", with: "\n\n```\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "</pre>", with: "\n```\n\n", options: [.regularExpression, .caseInsensitive])
    if let regex = try? NSRegularExpression(
        pattern: "<a\\s+[^>]*\\bhref=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
        options: .caseInsensitive
    ) {
        let nsResult = NSMutableString(string: s)
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for match in matches {
            let href = (s as NSString).substring(with: match.range(at: 1))
            let text = (s as NSString).substring(with: match.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            nsResult.replaceCharacters(in: match.range, with: "[\(text)](\(href))")
        }
        s = nsResult as String
    }
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    s = decodeHTMLEntities(s)
    s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Plugin Context

private final class PluginContext {
    let searchTool = SearchTool()
    let searchNewsTool = SearchNewsTool()
    let searchImagesTool = SearchImagesTool()
    let searchAndExtractTool = SearchAndExtractTool()
}

// MARK: - C ABI

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
}

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
    guard let ptr = strdup(s) else { return nil }
    return UnsafePointer(ptr)
}

private var api: osr_plugin_api = {
    var api = osr_plugin_api()

    api.free_string = { ptr in
        if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
    }

    api.`init` = {
        let ctx = PluginContext()
        return Unmanaged.passRetained(ctx).toOpaque()
    }

    api.destroy = { ctxPtr in
        guard let ctxPtr = ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    }

    api.get_manifest = { _ in
        let manifest = """
            {
              "plugin_id": "osaurus.search",
              "name": "Search",
              "description": "Web search for grounding. Just call search(query=...). Auto-picks the best available backend and returns deduplicated results.",
              "license": "MIT",
              "authors": ["Osaurus Team"],
              "min_macos": "13.0",
              "min_osaurus": "0.5.0",
              "secrets": [
                {"id":"TAVILY_API_KEY","label":"Tavily API key","description":"Get one at https://tavily.com (best free agent search; 1000 free queries/month).","required":false,"url":"https://tavily.com"},
                {"id":"BRAVE_SEARCH_API_KEY","label":"Brave Search API key","description":"Get one at https://api.search.brave.com.","required":false,"url":"https://api.search.brave.com"},
                {"id":"SERPER_API_KEY","label":"Serper API key","description":"Google SERP scraping at https://serper.dev.","required":false,"url":"https://serper.dev"},
                {"id":"GOOGLE_CSE_API_KEY","label":"Google CSE API key","description":"Google Custom Search Engine API key.","required":false,"url":"https://developers.google.com/custom-search/v1/introduction"},
                {"id":"GOOGLE_CSE_CX","label":"Google CSE engine ID (cx)","description":"Custom Search Engine ID. Required if GOOGLE_CSE_API_KEY is set.","required":false,"url":"https://programmablesearchengine.google.com/"},
                {"id":"KAGI_API_KEY","label":"Kagi Search API key","description":"Kagi paid search API.","required":false,"url":"https://help.kagi.com/kagi/api/search.html"},
                {"id":"YOU_API_KEY","label":"You.com API key","description":"You.com Search API key.","required":false,"url":"https://api.you.com"}
              ],
              "capabilities": {
                "tools": [
                  {
                    "id": "search",
                    "description": "Web search. Just pass `query` — the plugin auto-selects the best available backend and races free fallback scrapers in parallel. Returns deduplicated results with title, url, snippet, and (where available) published_date and source_domain.",
                    "parameters": {"type":"object","properties":{"query":{"type":"string","description":"Plain-language search query. Don't add site:/filetype: operators here; use the dedicated params below instead."},"max_results":{"type":"integer","description":"How many results to return (1-50). Default 10."},"time_range":{"type":"string","enum":["d","w","m","y"],"description":"Recency filter: d=day, w=week, m=month, y=year. Omit for any time."},"site":{"type":"string","description":"Restrict to a domain (e.g. 'arxiv.org'). Leave unset for any domain."},"filetype":{"type":"string","description":"Restrict to a file type (e.g. 'pdf'). Leave unset for any type."},"offset":{"type":"integer","description":"Pagination offset for fetching more results. Default 0."},"region":{"type":"string","description":"DDG region code in 'xx-yy' form (e.g. 'us-en'). Leave unset for global."}},"required":["query"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "search_news",
                    "description": "News-vertical search. Just pass `query`; defaults to last week. Same backend selection as `search`.",
                    "parameters": {"type":"object","properties":{"query":{"type":"string","description":"Plain-language query. Don't embed site:/filetype: operators."},"max_results":{"type":"integer","description":"1-50. Default 10."},"time_range":{"type":"string","enum":["d","w","m","y"],"description":"Recency filter. Default 'w' (last week)."},"site":{"type":"string","description":"Restrict to one outlet (e.g. 'reuters.com')."},"filetype":{"type":"string","description":"Restrict to a file type (e.g. 'pdf')."},"offset":{"type":"integer","description":"Pagination offset. Default 0."},"region":{"type":"string","description":"Region code 'xx-yy'."}},"required":["query"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "search_images",
                    "description": "Image search via DuckDuckGo. Returns image_url, thumbnail_url, dimensions, source_domain.",
                    "parameters": {"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"1-100. Default 20."}},"required":["query"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "search_and_extract",
                    "description": "One-shot: run a search and Readability-extract the top N URLs. Each enriched result includes 'markdown', 'title', 'byline', 'lang', 'word_count', and 'extracted'. Use this when you want a grounded answer without a separate fetch_html step.",
                    "parameters": {"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer","description":"1-20. Default 5."},"extract_count":{"type":"integer","description":"How many of the top results to extract. Default 3."},"time_range":{"type":"string","enum":["d","w","m","y"],"description":"Recency filter."},"site":{"type":"string","description":"Restrict to a domain."},"filetype":{"type":"string","description":"Restrict to a file type."},"timeout":{"type":"number","description":"Per-extract timeout in seconds. Default 25."}},"required":["query"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  }
                ],
                "skills": [
                  {
                    "name": "osaurus-search",
                    "description": "How to use the web search tools. Default to `search(query=...)` — the plugin auto-picks the best backend and races free fallbacks in parallel. Only override defaults when you have a specific reason."
                  }
                ]
              }
            }
            """
        return makeCString(manifest)
    }

    api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr = ctxPtr,
            let typePtr = typePtr,
            let idPtr = idPtr,
            let payloadPtr = payloadPtr
        else { return nil }

        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)

        guard type == "tool" else {
            return makeCString(
                errorResponse(
                    code: "UNKNOWN_CAPABILITY",
                    message: "This plugin only handles 'tool' invocations, got '\(type)'."
                )
            )
        }

        let result: String
        do {
            let outcome: ToolOutcome
            switch id {
            case SearchTool.name: outcome = try ctx.searchTool.run(args: payload)
            case SearchNewsTool.name: outcome = try ctx.searchNewsTool.run(args: payload)
            case SearchImagesTool.name: outcome = try ctx.searchImagesTool.run(args: payload)
            case SearchAndExtractTool.name: outcome = try ctx.searchAndExtractTool.run(args: payload)
            default:
                return makeCString(
                    errorResponse(
                        code: "UNKNOWN_TOOL",
                        message: "Unknown tool: '\(id)'.",
                        hint: "Available tools: search, search_news, search_images, search_and_extract."
                    )
                )
            }
            result = okResponse(outcome.data, warnings: outcome.warnings)
        } catch let err as ToolError {
            result = errorResponse(code: err.code, message: err.message, hint: err.hint, data: err.data)
        } catch {
            result = errorResponse(code: "INTERNAL", message: error.localizedDescription)
        }
        return makeCString(result)
    }

    return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    return UnsafeRawPointer(&api)
}
