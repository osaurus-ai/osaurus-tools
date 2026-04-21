import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Response Envelope

@inline(__always)
func okResponse(_ data: [String: Any], warnings: [String] = []) -> String {
    var payload: [String: Any] = ["ok": true, "data": data]
    if !warnings.isEmpty { payload["warnings"] = warnings }
    return jsonString(payload)
}

@inline(__always)
func errorResponse(code: String, message: String, hint: String? = nil) -> String {
    var error: [String: Any] = ["code": code, "message": message]
    if let hint = hint { error["hint"] = hint }
    return jsonString(["ok": false, "error": error])
}

func jsonString(_ obj: Any) -> String {
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
    init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

func decodeArgs<T: Decodable>(_ raw: String) throws -> T {
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

// MARK: - SSRF guard

let kReservedIPv4Cidrs: [(UInt32, UInt32)] = [
    (0x00_00_00_00, 0xFF_00_00_00),  // 0.0.0.0/8
    (0x0A_00_00_00, 0xFF_00_00_00),  // 10/8
    (0x7F_00_00_00, 0xFF_00_00_00),  // 127/8 loopback
    (0xA9_FE_00_00, 0xFF_FF_00_00),  // 169.254/16 link-local
    (0xAC_10_00_00, 0xFF_F0_00_00),  // 172.16/12
    (0xC0_A8_00_00, 0xFF_FF_00_00),  // 192.168/16
    (0xC0_00_00_00, 0xFF_FF_FF_F8),  // 192.0.0/29 reserved
    (0xC6_12_00_00, 0xFF_FF_00_00),  // 198.18/15 benchmarks
    (0xE0_00_00_00, 0xF0_00_00_00),  // 224/4 multicast
    (0xF0_00_00_00, 0xF0_00_00_00),  // 240/4 reserved
    (0xFF_FF_FF_FF, 0xFF_FF_FF_FF),  // 255.255.255.255 broadcast
]

let kReservedIPv6Prefixes: [String] = [
    "::1",  // loopback
    "fe80",  // link-local
    "fc",  // ULA fc00::/7
    "fd",  // ULA fc00::/7
    "ff",  // multicast
    "::",  // unspecified
]

let kBlockedHostnames: Set<String> = [
    "localhost",
    "ip6-localhost",
    "ip6-loopback",
    "broadcasthost",
    "metadata.google.internal",
    "metadata.amazonaws.com",
    "instance-data.ec2.internal",
]

struct SSRFCheck {
    let host: String
    let allowed: Bool
    let reason: String?
}

func isPrivateIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return false }
    let addr = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    for (network, mask) in kReservedIPv4Cidrs where (addr & mask) == (network & mask) {
        return true
    }
    return false
}

func isReservedIPv6(_ ip: String) -> Bool {
    let lower = ip.lowercased()
    if lower == "::" || lower == "::1" { return true }
    for prefix in kReservedIPv6Prefixes where lower.hasPrefix(prefix) {
        return true
    }
    return false
}

func resolveHostnames(_ host: String) -> [String] {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var info: UnsafeMutablePointer<addrinfo>? = nil
    let status = getaddrinfo(host, nil, &hints, &info)
    guard status == 0, let head = info else { return [] }
    defer { freeaddrinfo(head) }

    var results: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = head
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    while let node = cursor {
        let entry = node.pointee
        if let addr = entry.ai_addr {
            let rc = getnameinfo(
                addr,
                socklen_t(entry.ai_addrlen),
                &buffer,
                socklen_t(buffer.count),
                nil, 0,
                NI_NUMERICHOST
            )
            if rc == 0 {
                let name = String(cString: buffer)
                if !name.isEmpty && !results.contains(name) {
                    results.append(name)
                }
            }
        }
        cursor = entry.ai_next
    }
    return results
}

/// Returns `.allowed=true` if the URL's host is OK to fetch, else a structured
/// reason. `allowPrivate` skips all checks (use sparingly).
func checkSSRF(url: URL, allowPrivate: Bool) -> SSRFCheck {
    guard let host = url.host?.lowercased(), !host.isEmpty else {
        return SSRFCheck(host: "", allowed: false, reason: "URL has no host component")
    }
    if allowPrivate {
        return SSRFCheck(host: host, allowed: true, reason: nil)
    }

    if let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" {
        return SSRFCheck(host: host, allowed: false, reason: "Only http/https schemes are allowed (got '\(scheme)')")
    }

    if kBlockedHostnames.contains(host) || host.hasSuffix(".local") || host.hasSuffix(".internal") {
        return SSRFCheck(host: host, allowed: false, reason: "Hostname '\(host)' is in the SSRF blocklist")
    }

    // Literal IPv4
    if isPrivateIPv4(host) {
        return SSRFCheck(host: host, allowed: false, reason: "Host \(host) is in a private/reserved IPv4 range")
    }
    // Literal IPv6 (strip brackets if URL form)
    let v6 =
        host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host
    if v6.contains(":") && isReservedIPv6(v6) {
        return SSRFCheck(host: host, allowed: false, reason: "Host \(host) is in a reserved IPv6 range")
    }

    // Resolve and check each address
    let addresses = resolveHostnames(host)
    for addr in addresses {
        if addr.contains(":") {
            if isReservedIPv6(addr) {
                return SSRFCheck(host: host, allowed: false, reason: "Host '\(host)' resolves to reserved IPv6 \(addr)")
            }
        } else if isPrivateIPv4(addr) {
            return SSRFCheck(host: host, allowed: false, reason: "Host '\(host)' resolves to private IPv4 \(addr)")
        }
    }
    return SSRFCheck(host: host, allowed: true, reason: nil)
}

// MARK: - Body shaping

enum RequestBody {
    case none
    case rawString(String, contentType: String?)
    case rawBytes(Data, contentType: String?)
    case form([String: String])
    case json(Any)
    case multipart([MultipartField])
}

struct MultipartField: Decodable {
    let name: String
    let value: String?
    let filename: String?
    let content_base64: String?
    let content_type: String?
}

// MARK: - HTTP delegate (redirect tracking, byte cap, protocol detection)

final class FetchDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    var redirectChain: [String] = []
    var collected = Data()
    var truncated = false
    let maxBytes: Int
    let followRedirects: Bool
    var protocolName: String?
    private let semaphore = DispatchSemaphore(value: 0)
    var taskError: Error?
    var response: HTTPURLResponse?

    init(maxBytes: Int, followRedirects: Bool = true) {
        self.maxBytes = maxBytes
        self.followRedirects = followRedirects
    }

    func wait(timeout: TimeInterval) {
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let oldURL = response.url?.absoluteString {
            redirectChain.append(oldURL)
        }
        // Honor `follow_redirects: false`. Returning nil to the completion
        // handler stops the redirect; the original 3xx response is delivered
        // and `taskError` stays nil.
        completionHandler(followRedirects ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if collected.count >= maxBytes {
            truncated = true
            dataTask.cancel()
            return
        }
        let remaining = maxBytes - collected.count
        if data.count > remaining {
            collected.append(data.prefix(remaining))
            truncated = true
            dataTask.cancel()
        } else {
            collected.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // .cancelled errors from our own truncation are not real errors.
        if let err = error as NSError?,
            !(err.domain == NSURLErrorDomain && err.code == NSURLErrorCancelled && truncated)
        {
            taskError = error
        }
        // protocolName is filled in via didFinishCollecting, which fires before this.
        semaphore.signal()
    }

    @available(macOS 10.12, *)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        if let last = metrics.transactionMetrics.last {
            protocolName = last.networkProtocolName
        }
    }
}

// MARK: - Request execution

struct HTTPResult {
    let status: Int
    let headers: [String: String]
    let body: Data
    let finalURL: String
    let redirectChain: [String]
    let protocolVersion: String?
    let truncated: Bool
}

func executeRequest(
    url: URL,
    method: String,
    headers: [String: String],
    body: RequestBody,
    timeout: TimeInterval,
    maxBytes: Int,
    followRedirects: Bool
) throws -> HTTPResult {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method.uppercased()
    request.timeoutInterval = timeout

    var mergedHeaders = headers
    switch body {
    case .none:
        request.httpBody = nil
    case .rawString(let s, let contentType):
        request.httpBody = s.data(using: .utf8)
        if let ct = contentType, mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = ct
        }
    case .rawBytes(let bytes, let contentType):
        request.httpBody = bytes
        if let ct = contentType, mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = ct
        }
    case .form(let fields):
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        }
    case .json(let obj):
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw ToolError(
                code: "INVALID_ARGS",
                message: "json_body is not a valid JSON object/array"
            )
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: obj)
        if mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/json"
        }
    case .multipart(let fields):
        let boundary = "----osaurus-fetch-" + UUID().uuidString
        var bodyData = Data()
        for field in fields {
            bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
            if let filename = field.filename {
                let ct = field.content_type ?? "application/octet-stream"
                bodyData.append(
                    "Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(filename)\"\r\n"
                        .data(using: .utf8)!
                )
                bodyData.append("Content-Type: \(ct)\r\n\r\n".data(using: .utf8)!)
                if let b64 = field.content_base64, let raw = Data(base64Encoded: b64) {
                    bodyData.append(raw)
                } else if let v = field.value {
                    bodyData.append(v.data(using: .utf8) ?? Data())
                }
                bodyData.append("\r\n".data(using: .utf8)!)
            } else {
                bodyData.append(
                    "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
                        .data(using: .utf8)!
                )
                bodyData.append((field.value ?? "").data(using: .utf8) ?? Data())
                bodyData.append("\r\n".data(using: .utf8)!)
            }
        }
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = bodyData
        mergedHeaders["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
    }

    for (k, v) in mergedHeaders {
        request.setValue(v, forHTTPHeaderField: k)
    }

    let delegate = FetchDelegate(maxBytes: maxBytes, followRedirects: followRedirects)
    let config = URLSessionConfiguration.ephemeral
    config.httpMaximumConnectionsPerHost = 4
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    task.resume()
    delegate.wait(timeout: timeout + 5)
    session.invalidateAndCancel()

    if let err = delegate.taskError {
        let nserr = err as NSError
        let code: String
        switch nserr.code {
        case NSURLErrorTimedOut: code = "TIMEOUT"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: code = "NETWORK"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: code = "DNS"
        default: code = "HTTP_ERROR"
        }
        throw ToolError(code: code, message: nserr.localizedDescription)
    }

    guard let response = delegate.response else {
        throw ToolError(code: "HTTP_ERROR", message: "No response received")
    }

    var headerDict: [String: String] = [:]
    for (k, v) in response.allHeaderFields {
        headerDict[String(describing: k)] = String(describing: v)
    }

    return HTTPResult(
        status: response.statusCode,
        headers: headerDict,
        body: delegate.collected,
        finalURL: response.url?.absoluteString ?? url.absoluteString,
        redirectChain: delegate.redirectChain,
        protocolVersion: delegate.protocolName,
        truncated: delegate.truncated
    )
}

// MARK: - Common arg shapes

struct AuthHelper: Decodable {
    let type: String
    let token: String?
    let username: String?
    let password: String?
}

func headersFromAuth(_ auth: AuthHelper?) throws -> [String: String] {
    guard let auth = auth else { return [:] }
    switch auth.type.lowercased() {
    case "bearer":
        guard let token = auth.token, !token.isEmpty else {
            throw ToolError(
                code: "INVALID_ARGS",
                message: "auth.type='bearer' requires 'token'"
            )
        }
        return ["Authorization": "Bearer \(token)"]
    case "basic":
        guard let user = auth.username, let pass = auth.password else {
            throw ToolError(
                code: "INVALID_ARGS",
                message: "auth.type='basic' requires 'username' and 'password'"
            )
        }
        let raw = "\(user):\(pass)".data(using: .utf8) ?? Data()
        return ["Authorization": "Basic \(raw.base64EncodedString())"]
    default:
        throw ToolError(
            code: "INVALID_ARGS",
            message: "Unknown auth.type '\(auth.type)'. Supported: 'bearer', 'basic'."
        )
    }
}

func parseURL(_ s: String) throws -> URL {
    guard let url = URL(string: s) else {
        throw ToolError(code: "INVALID_ARGS", message: "Invalid URL: '\(s)'")
    }
    return url
}

func enforceSSRF(_ url: URL, allowPrivate: Bool) throws {
    let check = checkSSRF(url: url, allowPrivate: allowPrivate)
    if !check.allowed {
        throw ToolError(
            code: "SSRF_BLOCKED",
            message: check.reason ?? "Request blocked by SSRF guard",
            hint: "Set 'allow_private': true to bypass (use only for trusted local URLs)."
        )
    }
}

/// Pick a safe download target under ~/Downloads.
///
/// Throws `DOWNLOAD_PATH_INVALID` if the requested filename contains path
/// separators, parent traversals (`..`), or starts with `.` / `~`. Also
/// re-checks the canonicalized path is still under `~/Downloads`.
///
/// Exposed (non-throwing of any non-ToolError) so tests can drive it without
/// performing an HTTP request.
func resolveDownloadTarget(requestedFilename: String?, url: URL) throws -> URL {
    let candidate: String = {
        if let user = requestedFilename, !user.isEmpty { return user }
        if let last = url.pathComponents.last, !last.isEmpty, last != "/" { return last }
        return "download_\(Int(Date().timeIntervalSince1970))"
    }()

    if candidate.contains("/") || candidate.contains("\\") || candidate.contains("..")
        || candidate.hasPrefix(".") || candidate.hasPrefix("~")
    {
        throw ToolError(
            code: "DOWNLOAD_PATH_INVALID",
            message: "Filename contains path separators, '..', or starts with '.': '\(candidate)'",
            hint: "Pass a plain filename without directories — it will always land in ~/Downloads."
        )
    }

    let downloadsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
        .standardizedFileURL
    let target = downloadsDir.appendingPathComponent(candidate).standardizedFileURL

    if !target.path.hasPrefix(downloadsDir.path + "/") {
        throw ToolError(
            code: "DOWNLOAD_PATH_INVALID",
            message: "Resolved path '\(target.path)' is outside ~/Downloads",
            hint: "Pass a plain filename only."
        )
    }
    return target
}

struct CommonRequestArgs: Decodable {
    let url: String
    let method: String?
    let headers: [String: String]?
    let body: String?
    let body_base64: String?
    let json_body: AnyCodable?
    let form: [String: String]?
    let multipart: [MultipartField]?
    let auth: AuthHelper?
    let timeout: Double?
    let max_bytes: Int?
    let allow_private: Bool?
    let follow_redirects: Bool?
}

/// Wraps any JSON value so Codable can carry an arbitrary object/array through.
struct AnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let v = try? container.decode(Bool.self) {
            value = v
        } else if let v = try? container.decode(Int.self) {
            value = v
        } else if let v = try? container.decode(Double.self) {
            value = v
        } else if let v = try? container.decode(String.self) {
            value = v
        } else if let v = try? container.decode([AnyCodable].self) {
            value = v.map { $0.value }
        } else if let v = try? container.decode([String: AnyCodable].self) {
            value = v.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? Bool {
            try container.encode(v)
        } else if let v = value as? Int {
            try container.encode(v)
        } else if let v = value as? Double {
            try container.encode(v)
        } else if let v = value as? String {
            try container.encode(v)
        } else if value is NSNull {
            try container.encodeNil()
        } else {
            try container.encodeNil()
        }
    }
}

func bodyFromArgs(_ args: CommonRequestArgs) throws -> RequestBody {
    let provided = [
        args.body != nil,
        args.body_base64 != nil,
        args.json_body != nil,
        args.form != nil,
        args.multipart != nil,
    ].filter { $0 }.count
    if provided > 1 {
        throw ToolError(
            code: "INVALID_ARGS",
            message: "Provide at most one of: body, body_base64, json_body, form, multipart"
        )
    }
    if let s = args.body { return .rawString(s, contentType: nil) }
    if let b64 = args.body_base64 {
        guard let data = Data(base64Encoded: b64) else {
            throw ToolError(code: "INVALID_ARGS", message: "body_base64 is not valid base64")
        }
        return .rawBytes(data, contentType: nil)
    }
    if let json = args.json_body { return .json(json.value) }
    if let form = args.form { return .form(form) }
    if let multipart = args.multipart { return .multipart(multipart) }
    return .none
}

// MARK: - Tools

struct FetchTool {
    static let name = "fetch"

    func run(args: String) throws -> [String: Any] {
        let parsed: CommonRequestArgs = try decodeArgs(args)
        let url = try parseURL(parsed.url)
        try enforceSSRF(url, allowPrivate: parsed.allow_private ?? false)

        var headers = parsed.headers ?? [:]
        for (k, v) in try headersFromAuth(parsed.auth) {
            headers[k] = v
        }

        let result = try executeRequest(
            url: url,
            method: parsed.method ?? "GET",
            headers: headers,
            body: try bodyFromArgs(parsed),
            timeout: parsed.timeout ?? 30,
            maxBytes: parsed.max_bytes ?? 10 * 1024 * 1024,
            followRedirects: parsed.follow_redirects ?? true
        )

        return [
            "status": result.status,
            "final_url": result.finalURL,
            "redirect_chain": result.redirectChain,
            "protocol_version": result.protocolVersion ?? NSNull(),
            "headers": result.headers,
            "body": String(data: result.body, encoding: .utf8) ?? "",
            "body_base64": result.body.base64EncodedString(),
            "byte_count": result.body.count,
            "truncated": result.truncated,
        ]
    }
}

struct FetchJSONTool {
    static let name = "fetch_json"

    func run(args: String) throws -> [String: Any] {
        let parsed: CommonRequestArgs = try decodeArgs(args)
        let url = try parseURL(parsed.url)
        try enforceSSRF(url, allowPrivate: parsed.allow_private ?? false)

        var headers = parsed.headers ?? [:]
        if headers["Accept"] == nil { headers["Accept"] = "application/json" }
        for (k, v) in try headersFromAuth(parsed.auth) {
            headers[k] = v
        }

        let result = try executeRequest(
            url: url,
            method: parsed.method ?? "GET",
            headers: headers,
            body: try bodyFromArgs(parsed),
            timeout: parsed.timeout ?? 30,
            maxBytes: parsed.max_bytes ?? 10 * 1024 * 1024,
            followRedirects: parsed.follow_redirects ?? true
        )

        var data: [String: Any] = [
            "status": result.status,
            "final_url": result.finalURL,
            "redirect_chain": result.redirectChain,
            "protocol_version": result.protocolVersion ?? NSNull(),
            "headers": result.headers,
            "truncated": result.truncated,
        ]
        if let parsed = try? JSONSerialization.jsonObject(with: result.body) {
            data["json"] = parsed
        } else {
            data["json"] = NSNull()
            data["body"] = String(data: result.body, encoding: .utf8) ?? ""
            return data  // fall through with warning via caller? simpler: include both
        }
        return data
    }
}

struct FetchHTMLTool {
    static let name = "fetch_html"

    func run(args: String) throws -> [String: Any] {
        struct ExtractArgs: Decodable {
            let url: String
            let selector: String?
            let extract: String?  // "readability" (default) | "raw" | "text"
            let auth: AuthHelper?
            let timeout: Double?
            let max_bytes: Int?
            let allow_private: Bool?
            let follow_redirects: Bool?
            let user_agent: String?
        }
        let parsed: ExtractArgs = try decodeArgs(args)
        let url = try parseURL(parsed.url)
        try enforceSSRF(url, allowPrivate: parsed.allow_private ?? false)

        var headers: [String: String] = [
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let ua = parsed.user_agent { headers["User-Agent"] = ua }
        for (k, v) in try headersFromAuth(parsed.auth) {
            headers[k] = v
        }

        let result = try executeRequest(
            url: url,
            method: "GET",
            headers: headers,
            body: .none,
            timeout: parsed.timeout ?? 30,
            maxBytes: parsed.max_bytes ?? 10 * 1024 * 1024,
            followRedirects: parsed.follow_redirects ?? true
        )

        guard let html = String(data: result.body, encoding: .utf8) else {
            throw ToolError(
                code: "EXTRACTION_FAILED",
                message: "Response body is not UTF-8 text"
            )
        }

        let mode = (parsed.extract ?? "readability").lowercased()
        var data: [String: Any] = [
            "status": result.status,
            "final_url": result.finalURL,
            "redirect_chain": result.redirectChain,
            "protocol_version": result.protocolVersion ?? NSNull(),
            "headers": result.headers,
            "truncated": result.truncated,
            "byte_count": result.body.count,
        ]

        switch mode {
        case "raw":
            data["html"] = html
        case "text":
            data["text"] = htmlToPlainText(html)
        default:  // readability
            let extracted = readabilityExtract(html: html, selector: parsed.selector)
            data["title"] = extracted.title ?? NSNull()
            data["byline"] = extracted.byline ?? NSNull()
            data["excerpt"] = extracted.excerpt ?? NSNull()
            data["lang"] = extracted.lang ?? NSNull()
            data["markdown"] = extracted.markdown
            data["word_count"] = extracted.wordCount
        }
        return data
    }
}

struct DownloadTool {
    static let name = "download"

    func run(args: String) throws -> [String: Any] {
        struct DownloadArgs: Decodable {
            let url: String
            let filename: String?
            let auth: AuthHelper?
            let timeout: Double?
            let max_bytes: Int?
            let allow_private: Bool?
        }
        let parsed: DownloadArgs = try decodeArgs(args)
        let url = try parseURL(parsed.url)
        try enforceSSRF(url, allowPrivate: parsed.allow_private ?? false)

        var headers: [String: String] = [:]
        for (k, v) in try headersFromAuth(parsed.auth) {
            headers[k] = v
        }

        let result = try executeRequest(
            url: url,
            method: "GET",
            headers: headers,
            body: .none,
            timeout: parsed.timeout ?? 60,
            maxBytes: parsed.max_bytes ?? 100 * 1024 * 1024,
            followRedirects: true
        )

        let target = try resolveDownloadTarget(
            requestedFilename: parsed.filename,
            url: url
        )

        do {
            try result.body.write(to: target)
        } catch {
            throw ToolError(
                code: "WRITE_FAILED",
                message: "Could not write file: \(error.localizedDescription)"
            )
        }

        return [
            "path": target.path,
            "size": result.body.count,
            "status": result.status,
            "final_url": result.finalURL,
            "truncated": result.truncated,
        ]
    }
}

// MARK: - HTML helpers (text + Readability-lite)

/// Decode common HTML entities. Numeric (`&#NN;` / `&#xHH;`) handled too.
func decodeHTMLEntities(_ s: String) -> String {
    var result = s
    let named: [(String, String)] = [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&#39;", "'"),
        ("&nbsp;", " "),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
        ("&ldquo;", "\u{201C}"),
        ("&rdquo;", "\u{201D}"),
        ("&lsquo;", "\u{2018}"),
        ("&rsquo;", "\u{2019}"),
    ]
    for (entity, replacement) in named {
        result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
    }

    // Numeric entities — preserve the codepoint instead of stripping.
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
            if let s = scalar, let unicode = UnicodeScalar(s) {
                let replacement = String(unicode)
                nsResult.replaceCharacters(in: match.range, with: replacement)
            }
        }
        result = nsResult as String
    }
    return result
}

func stripTags(_ html: String, removeBlocks: [String]) -> String {
    var out = html
    for tag in removeBlocks {
        if let regex = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
            options: .caseInsensitive
        ) {
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: " "
            )
        }
    }
    return out
}

func htmlToPlainText(_ html: String) -> String {
    let cleaned = stripTags(
        html,
        removeBlocks: ["script", "style", "noscript", "template", "svg"]
    )
    var text = cleaned
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        text = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }
    text = decodeHTMLEntities(text)
    if let regex = try? NSRegularExpression(pattern: "\\s+", options: []) {
        text = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ReadabilityResult {
    let title: String?
    let byline: String?
    let excerpt: String?
    let lang: String?
    let markdown: String
    let wordCount: Int
}

/// Lightweight Readability-style extraction. Not a full Mozilla port — picks
/// `<article>`/`<main>` if present, strips noise, then converts to Markdown.
func readabilityExtract(html: String, selector: String?) -> ReadabilityResult {
    let title = firstGroup(in: html, pattern: "<title[^>]*>([\\s\\S]*?)</title>")
        .map { decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }

    let byline =
        metaContent(in: html, name: "author")
        ?? metaContent(in: html, name: "article:author")
        ?? metaContent(in: html, property: "article:author")

    let excerpt =
        metaContent(in: html, name: "description")
        ?? metaContent(in: html, property: "og:description")

    let lang = firstGroup(in: html, pattern: "<html[^>]*\\blang=[\"']([^\"']+)[\"']")

    var content = stripTags(
        html,
        removeBlocks: [
            "script", "style", "noscript", "template", "svg", "iframe",
            "header", "footer", "nav", "aside", "form", "button",
        ]
    )

    if let sel = selector, !sel.isEmpty {
        content = applySelector(content, selector: sel) ?? content
    } else if let main = pickMainContainer(content) {
        content = main
    }

    let markdown = htmlToMarkdown(content)
    let wordCount = markdown.split(whereSeparator: { $0.isWhitespace }).count

    return ReadabilityResult(
        title: title,
        byline: byline?.trimmingCharacters(in: .whitespacesAndNewlines),
        excerpt: excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
        lang: lang,
        markdown: markdown,
        wordCount: wordCount
    )
}

func firstGroup(in s: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
        let range = Range(match.range(at: 1), in: s)
    else { return nil }
    return String(s[range])
}

func metaContent(in s: String, name: String? = nil, property: String? = nil) -> String? {
    if let name = name {
        let pattern = "<meta[^>]*\\bname=[\"']\(name)[\"'][^>]*\\bcontent=[\"']([^\"']*)[\"']"
        if let v = firstGroup(in: s, pattern: pattern) {
            return decodeHTMLEntities(v)
        }
        let altPattern = "<meta[^>]*\\bcontent=[\"']([^\"']*)[\"'][^>]*\\bname=[\"']\(name)[\"']"
        if let v = firstGroup(in: s, pattern: altPattern) {
            return decodeHTMLEntities(v)
        }
    }
    if let property = property {
        let pattern = "<meta[^>]*\\bproperty=[\"']\(property)[\"'][^>]*\\bcontent=[\"']([^\"']*)[\"']"
        if let v = firstGroup(in: s, pattern: pattern) {
            return decodeHTMLEntities(v)
        }
    }
    return nil
}

func pickMainContainer(_ html: String) -> String? {
    for tag in ["article", "main"] {
        let pattern = "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"
        if let body = firstGroup(in: html, pattern: pattern), !body.isEmpty {
            return body
        }
    }
    if let body = firstGroup(in: html, pattern: "<body[^>]*>([\\s\\S]*?)</body>") {
        return body
    }
    return nil
}

func applySelector(_ html: String, selector: String) -> String? {
    if selector.hasPrefix("#") {
        let id = String(selector.dropFirst())
        return firstGroup(
            in: html,
            pattern:
                "<[a-zA-Z]+[^>]*\\bid=[\"']\(NSRegularExpression.escapedPattern(for: id))[\"'][^>]*>([\\s\\S]*?)</[a-zA-Z]+>"
        )
    }
    if selector.hasPrefix(".") {
        let cls = String(selector.dropFirst())
        return firstGroup(
            in: html,
            pattern:
                "<[a-zA-Z]+[^>]*\\bclass=[\"'][^\"']*\\b\(NSRegularExpression.escapedPattern(for: cls))\\b[^\"']*[\"'][^>]*>([\\s\\S]*?)</[a-zA-Z]+>"
        )
    }
    // bare tag name
    let safe = NSRegularExpression.escapedPattern(for: selector)
    return firstGroup(in: html, pattern: "<\(safe)\\b[^>]*>([\\s\\S]*?)</\(safe)>")
}

/// Very small HTML → Markdown converter. Handles the common subset:
/// h1-h6, p, br, hr, strong/b, em/i, a, code, pre, ul/ol/li, blockquote, img.
func htmlToMarkdown(_ html: String) -> String {
    var s = html

    // Normalize self-closing / void tags
    s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<hr[^>]*>", with: "\n\n---\n\n", options: .regularExpression)

    let blockMappings: [(String, String, String)] = [
        ("h1", "\n\n# ", "\n\n"),
        ("h2", "\n\n## ", "\n\n"),
        ("h3", "\n\n### ", "\n\n"),
        ("h4", "\n\n#### ", "\n\n"),
        ("h5", "\n\n##### ", "\n\n"),
        ("h6", "\n\n###### ", "\n\n"),
        ("blockquote", "\n\n> ", "\n\n"),
        ("p", "\n\n", "\n\n"),
        ("li", "\n- ", ""),
    ]
    for (tag, prefix, suffix) in blockMappings {
        s = s.replacingOccurrences(
            of: "<\(tag)\\b[^>]*>",
            with: prefix,
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "</\(tag)>",
            with: suffix,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    let inlineMappings: [(String, String)] = [
        ("strong", "**"),
        ("b", "**"),
        ("em", "*"),
        ("i", "*"),
        ("code", "`"),
    ]
    for (tag, marker) in inlineMappings {
        s = s.replacingOccurrences(
            of: "<\(tag)\\b[^>]*>",
            with: marker,
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "</\(tag)>",
            with: marker,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // <pre> as fenced code block
    s = s.replacingOccurrences(
        of: "<pre\\b[^>]*>",
        with: "\n\n```\n",
        options: [.regularExpression, .caseInsensitive]
    )
    s = s.replacingOccurrences(
        of: "</pre>",
        with: "\n```\n\n",
        options: [.regularExpression, .caseInsensitive]
    )

    // Anchors: <a href="X">Y</a> → [Y](X)
    if let regex = try? NSRegularExpression(
        pattern: "<a\\s+[^>]*\\bhref=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
        options: .caseInsensitive
    ) {
        let nsResult = NSMutableString(string: s)
        let matches = regex.matches(
            in: s,
            range: NSRange(s.startIndex..., in: s)
        ).reversed()
        for match in matches {
            let href = (s as NSString).substring(with: match.range(at: 1))
            let text = (s as NSString).substring(with: match.range(at: 2))
            let cleanText = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            nsResult.replaceCharacters(in: match.range, with: "[\(cleanText)](\(href))")
        }
        s = nsResult as String
    }

    // Images: <img src="X" alt="Y"> → ![Y](X)
    if let regex = try? NSRegularExpression(
        pattern: "<img\\b[^>]*\\bsrc=[\"']([^\"']+)[\"'][^>]*>",
        options: .caseInsensitive
    ) {
        let nsResult = NSMutableString(string: s)
        let matches = regex.matches(
            in: s,
            range: NSRange(s.startIndex..., in: s)
        ).reversed()
        for match in matches {
            let src = (s as NSString).substring(with: match.range(at: 1))
            let altRange = match.range
            let openTag = (s as NSString).substring(with: altRange)
            var alt = ""
            if let altRegex = try? NSRegularExpression(pattern: "alt=[\"']([^\"']*)[\"']", options: .caseInsensitive),
                let altMatch = altRegex.firstMatch(in: openTag, range: NSRange(openTag.startIndex..., in: openTag)),
                let r = Range(altMatch.range(at: 1), in: openTag)
            {
                alt = String(openTag[r])
            }
            nsResult.replaceCharacters(in: altRange, with: "![\(alt)](\(src))")
        }
        s = nsResult as String
    }

    // Strip remaining tags
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    s = decodeHTMLEntities(s)

    // Collapse 3+ newlines to 2
    s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    // Trim trailing whitespace per line
    s = s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression) }
        .joined(separator: "\n")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Plugin Context

private final class PluginContext {
    let fetchTool = FetchTool()
    let fetchJSONTool = FetchJSONTool()
    let fetchHTMLTool = FetchHTMLTool()
    let downloadTool = DownloadTool()
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
              "plugin_id": "osaurus.fetch",
              "name": "Fetch",
              "description": "HTTP client with SSRF protection, response size limits, and Readability-style HTML extraction.",
              "license": "MIT",
              "authors": ["Osaurus Team"],
              "min_macos": "13.0",
              "min_osaurus": "0.5.0",
              "capabilities": {
                "tools": [
                  {
                    "id": "fetch",
                    "description": "Send any HTTP request and return status, headers, body, final URL, redirect chain, and protocol version. SSRF guard blocks private/loopback/link-local/metadata IPs by default.",
                    "parameters": {"type":"object","properties":{"url":{"type":"string","description":"Target URL (http or https)."},"method":{"type":"string","description":"HTTP method. Default 'GET'."},"headers":{"type":"object","additionalProperties":{"type":"string"},"description":"Request headers."},"body":{"type":"string","description":"UTF-8 string body. Mutually exclusive with body_base64/json_body/form/multipart."},"body_base64":{"type":"string","description":"Base64-encoded raw bytes body."},"json_body":{"description":"Object/array to JSON-encode and send as the body. Sets Content-Type to application/json."},"form":{"type":"object","additionalProperties":{"type":"string"},"description":"application/x-www-form-urlencoded body."},"multipart":{"type":"array","items":{"type":"object"},"description":"multipart/form-data fields. Each: {name, value?, filename?, content_base64?, content_type?}."},"auth":{"type":"object","description":"Auth helper. {type:'bearer',token} or {type:'basic',username,password}."},"timeout":{"type":"number","description":"Seconds. Default 30."},"max_bytes":{"type":"integer","description":"Cap on response body size. Default 10485760 (10 MB). Sets data.truncated=true on overflow."},"allow_private":{"type":"boolean","description":"Bypass SSRF guard. Default false."},"follow_redirects":{"type":"boolean","description":"Default true."}},"required":["url"]},
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "fetch_json",
                    "description": "GET/POST a URL and return parsed JSON. Sets Accept: application/json automatically. If the body isn't valid JSON, data.json is null and data.body holds the raw text.",
                    "parameters": {"type":"object","properties":{"url":{"type":"string"},"method":{"type":"string"},"headers":{"type":"object","additionalProperties":{"type":"string"}},"body":{"type":"string"},"body_base64":{"type":"string"},"json_body":{},"form":{"type":"object","additionalProperties":{"type":"string"}},"multipart":{"type":"array","items":{"type":"object"}},"auth":{"type":"object"},"timeout":{"type":"number"},"max_bytes":{"type":"integer"},"allow_private":{"type":"boolean"},"follow_redirects":{"type":"boolean"}},"required":["url"]},
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "fetch_html",
                    "description": "Fetch an HTML page and extract its main content as Markdown. Returns title, byline, excerpt, lang, markdown, word_count. Set extract='raw' to return the full HTML, or extract='text' for plain text.",
                    "parameters": {"type":"object","properties":{"url":{"type":"string"},"selector":{"type":"string","description":"Optional CSS-style hint (#id, .class, or tag) to scope extraction. Falls back to <article>/<main>/<body>."},"extract":{"type":"string","enum":["readability","raw","text"],"default":"readability","description":"Output mode."},"auth":{"type":"object"},"timeout":{"type":"number"},"max_bytes":{"type":"integer"},"allow_private":{"type":"boolean"},"follow_redirects":{"type":"boolean"},"user_agent":{"type":"string","description":"Override the User-Agent header."}},"required":["url"]},
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "download",
                    "description": "Download a file into ~/Downloads. Filename must be a plain name (no path separators, no '..', no leading '.' or '~'). Resolved path is verified to stay under ~/Downloads.",
                    "parameters": {"type":"object","properties":{"url":{"type":"string"},"filename":{"type":"string","description":"Plain filename. Defaults to the URL's last path component."},"auth":{"type":"object"},"timeout":{"type":"number","description":"Seconds. Default 60."},"max_bytes":{"type":"integer","description":"Cap on file size. Default 104857600 (100 MB)."},"allow_private":{"type":"boolean"}},"required":["url"]},
                    "requirements": [],
                    "permission_policy": "ask"
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
            let data: [String: Any]
            switch id {
            case FetchTool.name: data = try ctx.fetchTool.run(args: payload)
            case FetchJSONTool.name: data = try ctx.fetchJSONTool.run(args: payload)
            case FetchHTMLTool.name: data = try ctx.fetchHTMLTool.run(args: payload)
            case DownloadTool.name: data = try ctx.downloadTool.run(args: payload)
            default:
                return makeCString(
                    errorResponse(
                        code: "UNKNOWN_TOOL",
                        message: "Unknown tool: '\(id)'.",
                        hint: "Available tools: fetch, fetch_json, fetch_html, download."
                    )
                )
            }
            result = okResponse(data)
        } catch let err as ToolError {
            result = errorResponse(code: err.code, message: err.message, hint: err.hint)
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
