import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public enum WebSafetyErrorCode: String, Equatable {
    case ssrfBlocked = "SSRF_BLOCKED"
    case secretInURL = "SECRET_IN_URL"
    case unsafeScheme = "UNSAFE_SCHEME"
    case downloadPathInvalid = "DOWNLOAD_PATH_INVALID"
}

public struct WebSafetyError: Error, Equatable, LocalizedError {
    public let code: WebSafetyErrorCode
    public let message: String
    public let redactedURL: String?

    public init(code: WebSafetyErrorCode, message: String, redactedURL: String? = nil) {
        self.code = code
        self.message = message
        self.redactedURL = redactedURL
    }

    public var errorDescription: String? {
        message
    }
}

public struct RedactionResult<Value> {
    public let value: Value
    public let redacted: Bool

    public init(value: Value, redacted: Bool) {
        self.value = value
        self.redacted = redacted
    }
}

public struct URLPolicyOptions: Equatable {
    public var allowPrivateNetwork: Bool
    public var allowAboutBlank: Bool
    public var resolveHostnames: Bool

    public init(
        allowPrivateNetwork: Bool = false,
        allowAboutBlank: Bool = false,
        resolveHostnames: Bool = true
    ) {
        self.allowPrivateNetwork = allowPrivateNetwork
        self.allowAboutBlank = allowAboutBlank
        self.resolveHostnames = resolveHostnames
    }
}

public struct URLPolicyDecision: Equatable {
    public let url: URL
    public let redactedURL: String
    public let host: String?
    public let resolvedAddresses: [String]
    public let isAboutBlank: Bool
    public let warnings: [String]

    public init(
        url: URL,
        redactedURL: String,
        host: String?,
        resolvedAddresses: [String],
        isAboutBlank: Bool,
        warnings: [String]
    ) {
        self.url = url
        self.redactedURL = redactedURL
        self.host = host
        self.resolvedAddresses = resolvedAddresses
        self.isAboutBlank = isAboutBlank
        self.warnings = warnings
    }
}

public struct SystemHostResolver {
    public static func resolve(_ host: String) -> [String] {
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
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &info)
        guard status == 0, let head = info else { return [] }
        defer { freeaddrinfo(head) }

        var results: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let node = cursor {
            let entry = node.pointee
            if let addr = entry.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(
                    addr,
                    socklen_t(entry.ai_addrlen),
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
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
}

public struct URLPolicy {
    public typealias Resolver = (String) -> [String]

    private let resolver: Resolver

    public init(resolver: @escaping Resolver = SystemHostResolver.resolve) {
        self.resolver = resolver
    }

    public func validate(_ rawURL: String, options: URLPolicyOptions = URLPolicyOptions()) throws -> URLPolicyDecision {
        guard let url = URL(string: rawURL) else {
            throw WebSafetyError(
                code: .unsafeScheme,
                message: "URL is invalid or missing a supported scheme.",
                redactedURL: WebSafetyRedactor.redactURL(rawURL).value
            )
        }
        return try validate(url, options: options)
    }

    public func validate(_ url: URL, options: URLPolicyOptions = URLPolicyOptions()) throws -> URLPolicyDecision {
        let redacted = WebSafetyRedactor.redactURL(url.absoluteString)
        let redactedURL = redacted.value
        let warnings = redacted.redacted ? ["credential-looking URL components were redacted"] : []

        if isAboutBlank(url) {
            if options.allowAboutBlank {
                return URLPolicyDecision(
                    url: url,
                    redactedURL: redactedURL,
                    host: nil,
                    resolvedAddresses: [],
                    isAboutBlank: true,
                    warnings: warnings
                )
            }
            throw WebSafetyError(
                code: .unsafeScheme,
                message: "about:blank is allowed only for explicitly opted-in browser flows.",
                redactedURL: redactedURL
            )
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            let got = url.scheme ?? "(missing)"
            throw WebSafetyError(
                code: .unsafeScheme,
                message: "Only http and https URLs are allowed; got '\(got)'.",
                redactedURL: redactedURL
            )
        }

        if URLPolicy.hasUserInfo(url) {
            throw WebSafetyError(
                code: .secretInURL,
                message: "URL userinfo is not allowed because it can embed credentials.",
                redactedURL: redactedURL
            )
        }

        guard let rawHost = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? url.host,
            !rawHost.isEmpty
        else {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: "URL has no host component.",
                redactedURL: redactedURL
            )
        }

        let host = HostNormalizer.normalize(rawHost)
        if MetadataEndpoint.isBlockedHostname(host) {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: "Cloud metadata endpoint host '\(host)' is blocked.",
                redactedURL: redactedURL
            )
        }

        if let ipv4 = IPv4Address.parseFlexible(host) {
            try enforceIPv4(ipv4, host: host, options: options, redactedURL: redactedURL)
            return URLPolicyDecision(
                url: url,
                redactedURL: redactedURL,
                host: host,
                resolvedAddresses: [ipv4.presentation],
                isAboutBlank: false,
                warnings: warnings
            )
        }

        if let ipv6 = IPv6Address.parse(host) {
            try enforceIPv6(ipv6, host: host, options: options, redactedURL: redactedURL)
            return URLPolicyDecision(
                url: url,
                redactedURL: redactedURL,
                host: host,
                resolvedAddresses: [ipv6.presentation],
                isAboutBlank: false,
                warnings: warnings
            )
        }

        if !options.allowPrivateNetwork && HostNormalizer.isBlockedLocalName(host) {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: "Local/private hostname '\(host)' is blocked.",
                redactedURL: redactedURL
            )
        }

        let resolved = options.resolveHostnames ? resolver(host) : []
        if options.resolveHostnames && resolved.isEmpty {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: "Host '\(host)' did not resolve to any address for SSRF validation.",
                redactedURL: redactedURL
            )
        }
        for resolvedHost in resolved.map(HostNormalizer.normalize) {
            if let ipv4 = IPv4Address.parseFlexible(resolvedHost) {
                try enforceIPv4(ipv4, host: host, resolvedHost: resolvedHost, options: options, redactedURL: redactedURL)
                continue
            }
            if let ipv6 = IPv6Address.parse(resolvedHost) {
                try enforceIPv6(ipv6, host: host, resolvedHost: resolvedHost, options: options, redactedURL: redactedURL)
            }
        }

        return URLPolicyDecision(
            url: url,
            redactedURL: redactedURL,
            host: host,
            resolvedAddresses: resolved,
            isAboutBlank: false,
            warnings: warnings
        )
    }

    private func enforceIPv4(
        _ ipv4: IPv4Address,
        host: String,
        resolvedHost: String? = nil,
        options: URLPolicyOptions,
        redactedURL: String
    ) throws {
        if MetadataEndpoint.isBlockedIPv4(ipv4.value) {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: blockMessage(host: host, resolvedHost: resolvedHost, reason: "cloud metadata IPv4 \(ipv4.presentation)"),
                redactedURL: redactedURL
            )
        }
        if !options.allowPrivateNetwork && IPv4Address.isBlockedNetwork(ipv4.value) {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: blockMessage(host: host, resolvedHost: resolvedHost, reason: "private/reserved IPv4 \(ipv4.presentation)"),
                redactedURL: redactedURL
            )
        }
    }

    private func enforceIPv6(
        _ ipv6: IPv6Address,
        host: String,
        resolvedHost: String? = nil,
        options: URLPolicyOptions,
        redactedURL: String
    ) throws {
        if MetadataEndpoint.isBlockedIPv6(ipv6) {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: blockMessage(host: host, resolvedHost: resolvedHost, reason: "cloud metadata IPv6 \(ipv6.presentation)"),
                redactedURL: redactedURL
            )
        }
        if !options.allowPrivateNetwork && IPv6Address.isBlockedNetwork(ipv6) {
            throw WebSafetyError(
                code: .ssrfBlocked,
                message: blockMessage(host: host, resolvedHost: resolvedHost, reason: "private/reserved IPv6 \(ipv6.presentation)"),
                redactedURL: redactedURL
            )
        }
    }

    private func blockMessage(host: String, resolvedHost: String?, reason: String) -> String {
        if let resolvedHost {
            return "Host '\(host)' resolves to blocked \(reason) via \(resolvedHost)."
        }
        return "Host '\(host)' is blocked as \(reason)."
    }

    private func isAboutBlank(_ url: URL) -> Bool {
        url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "about:blank"
    }

    private static func hasUserInfo(_ url: URL) -> Bool {
        if let user = url.user, !user.isEmpty { return true }
        if let password = url.password, !password.isEmpty { return true }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let user = components.user, !user.isEmpty { return true }
            if let password = components.password, !password.isEmpty { return true }
        }
        return false
    }
}

public struct RedirectDecision: Equatable {
    public let target: URLPolicyDecision
    public let headers: [String: String]
    public let strippedSensitiveHeaders: Bool

    public init(target: URLPolicyDecision, headers: [String: String], strippedSensitiveHeaders: Bool) {
        self.target = target
        self.headers = headers
        self.strippedSensitiveHeaders = strippedSensitiveHeaders
    }
}

public struct RedirectPolicy {
    private let urlPolicy: URLPolicy

    public init(urlPolicy: URLPolicy = URLPolicy()) {
        self.urlPolicy = urlPolicy
    }

    public func evaluate(
        from currentURL: URL,
        to targetURL: URL,
        headers: [String: String],
        options: URLPolicyOptions = URLPolicyOptions()
    ) throws -> RedirectDecision {
        let target = try urlPolicy.validate(targetURL, options: options)
        let shouldStrip = !sameOrigin(currentURL, targetURL) || isDowngrade(from: currentURL, to: targetURL)
        guard shouldStrip else {
            return RedirectDecision(target: target, headers: headers, strippedSensitiveHeaders: false)
        }

        var stripped: [String: String] = [:]
        var didStrip = false
        for (name, value) in headers {
            if WebSafetyRedactor.isSensitiveHeaderName(name) {
                didStrip = true
            } else {
                stripped[name] = value
            }
        }
        return RedirectDecision(target: target, headers: stripped, strippedSensitiveHeaders: didStrip)
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftScheme = lhs.scheme?.lowercased()
        let rightScheme = rhs.scheme?.lowercased()
        guard leftScheme == rightScheme else { return false }
        let leftHost = (URLComponents(url: lhs, resolvingAgainstBaseURL: false)?.host ?? lhs.host ?? "").lowercased()
        let rightHost = (URLComponents(url: rhs, resolvingAgainstBaseURL: false)?.host ?? rhs.host ?? "").lowercased()
        return leftHost == rightHost && effectivePort(lhs) == effectivePort(rhs)
    }

    private func isDowngrade(from currentURL: URL, to targetURL: URL) -> Bool {
        currentURL.scheme?.lowercased() == "https" && targetURL.scheme?.lowercased() == "http"
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

public enum WebSafetyRedactor {
    private static let redacted = "<redacted>"
    private static let urlQueryRedacted = "REDACTED"

    public static func containsCredentials(inURL rawURL: String) -> Bool {
        redactURL(rawURL).redacted
    }

    public static func redactURL(_ rawURL: String) -> RedactionResult<String> {
        guard var components = URLComponents(string: rawURL) else {
            let redactedText = redactCredentialPairs(in: rawURL)
            return RedactionResult(value: redactedText.value, redacted: redactedText.redacted)
        }

        var didRedact = false
        if components.user != nil || components.password != nil {
            components.user = nil
            components.password = nil
            didRedact = true
        }

        if let items = components.queryItems, !items.isEmpty {
            let rewritten = items.map { item -> URLQueryItem in
                if isCredentialQueryName(item.name) || looksLikeSecretValue(item.value) {
                    didRedact = true
                    return URLQueryItem(name: item.name, value: urlQueryRedacted)
                }
                return item
            }
            components.queryItems = rewritten
        } else if let percentEncodedQuery = components.percentEncodedQuery, !percentEncodedQuery.isEmpty {
            let redactedQuery = redactCredentialPairs(in: percentEncodedQuery)
            if redactedQuery.redacted {
                components.percentEncodedQuery = redactedQuery.value
                didRedact = true
            }
        }

        if let percentEncodedFragment = components.percentEncodedFragment, !percentEncodedFragment.isEmpty {
            let redactedFragment = redactCredentialPairs(in: percentEncodedFragment)
            if redactedFragment.redacted {
                components.percentEncodedFragment = redactedFragment.value
                didRedact = true
            }
        }

        return RedactionResult(value: components.string ?? rawURL, redacted: didRedact)
    }

    public static func redactHeaders(_ headers: [String: String]) -> RedactionResult<[String: String]> {
        var output: [String: String] = [:]
        var didRedact = false
        for (name, value) in headers {
            if isSensitiveHeaderName(name) {
                output[name] = redacted
                didRedact = true
            } else {
                let text = redactText(value)
                output[name] = text.value
                didRedact = didRedact || text.redacted
            }
        }
        return RedactionResult(value: output, redacted: didRedact)
    }

    public static func redactCookieHeader(_ cookie: String) -> RedactionResult<String> {
        let parts = cookie.split(separator: ";", omittingEmptySubsequences: false)
        var didRedact = false
        let rewritten = parts.map { part -> String in
            let piece = String(part)
            let leading = piece.prefix { $0 == " " || $0 == "\t" }
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else {
                return piece
            }
            let name = String(trimmed[..<equals])
            let lower = name.lowercased()
            if setCookieAttributeNames.contains(lower) {
                return piece
            }
            didRedact = true
            return "\(leading)\(name)=\(redacted)"
        }.joined(separator: ";")
        return RedactionResult(value: rewritten, redacted: didRedact)
    }

    public static func redactText(_ text: String) -> RedactionResult<String> {
        var output = text
        var didRedact = false

        let urlPattern = #"https?://[^\s<>"']+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let candidate = String(output[range])
                let redactedURL = redactURL(candidate)
                if redactedURL.redacted {
                    output.replaceSubrange(range, with: redactedURL.value)
                    didRedact = true
                }
            }
        }

        let headerPatterns = [
            #"(?i)\b(authorization|proxy-authorization|x-api-key|api-key|x-auth-token|x-csrf-token)\s*:\s*([^\r\n]+)"#,
            #"(?i)\b(bearer|basic)\s+([A-Za-z0-9._~+/=-]{8,})"#,
        ]
        for pattern in headerPatterns {
            let result = replaceRegex(pattern, in: output) { match in
                if match.count == 3 {
                    didRedact = true
                    return "\(match[1]) \(pattern.contains(":") ? ":" : "") \(redacted)"
                        .replacingOccurrences(of: "  ", with: " ")
                        .replacingOccurrences(of: " : ", with: ": ")
                }
                return match[0]
            }
            output = result
        }

        let pairs = redactCredentialPairs(in: output)
        if pairs.redacted {
            output = pairs.value
            didRedact = true
        }

        return RedactionResult(value: output, redacted: didRedact)
    }

    public static func isSensitiveHeaderName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if sensitiveHeaderNames.contains(normalized) { return true }
        return normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("api-key")
            || normalized.contains("apikey")
            || normalized.contains("credential")
    }

    private static func redactCredentialPairs(in text: String) -> RedactionResult<String> {
        let pattern = #"(?i)\b(access_token|refresh_token|id_token|api_key|apikey|x-api-key|key|token|secret|signature|sig|password|passwd|pwd|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|x-goog-credential|x-goog-security-token)=([^&;\s]+)"#
        var didRedact = false
        let output = replaceRegex(pattern, in: text) { match in
            guard match.count == 3 else { return match[0] }
            didRedact = true
            return "\(match[1])=\(urlQueryRedacted)"
        }
        return RedactionResult(value: output, redacted: didRedact)
    }

    private static func isCredentialQueryName(_ name: String) -> Bool {
        let decoded = percentDecodeRepeated(name).lowercased()
        let normalized = decoded.replacingOccurrences(of: "_", with: "-")
        if credentialQueryNames.contains(decoded) || credentialQueryNames.contains(normalized) {
            return true
        }
        return normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("api-key")
            || normalized.contains("apikey")
            || normalized.contains("credential")
            || normalized == "key"
            || normalized == "signature"
            || normalized == "sig"
            || normalized == "password"
    }

    private static func looksLikeSecretValue(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let decoded = percentDecodeRepeated(value)
        let lower = decoded.lowercased()
        if secretPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }
        if decoded.hasPrefix("AKIA") || decoded.hasPrefix("ASIA") {
            return decoded.count >= 16
        }
        return false
    }

    private static func percentDecodeRepeated(_ value: String) -> String {
        var current = value
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else { break }
            current = decoded
        }
        return current
    }

    private static func replaceRegex(
        _ pattern: String,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        var output = text
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                if range.location == NSNotFound {
                    groups.append("")
                } else if let swiftRange = Range(range, in: output) {
                    groups.append(String(output[swiftRange]))
                } else {
                    groups.append("")
                }
            }
            guard let range = Range(match.range(at: 0), in: output) else { continue }
            output.replaceSubrange(range, with: transform(groups))
        }
        return output
    }

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "x-csrf-token",
        "x-amz-security-token",
        "x-goog-security-token",
    ]

    private static let setCookieAttributeNames: Set<String> = [
        "domain",
        "expires",
        "max-age",
        "path",
        "priority",
        "samesite",
        "version",
    ]

    private static let credentialQueryNames: Set<String> = [
        "access_token",
        "access-token",
        "refresh_token",
        "refresh-token",
        "id_token",
        "id-token",
        "api_key",
        "api-key",
        "apikey",
        "key",
        "token",
        "secret",
        "signature",
        "sig",
        "password",
        "passwd",
        "pwd",
        "x-amz-signature",
        "x-amz-credential",
        "x-amz-security-token",
        "x-goog-signature",
        "x-goog-credential",
        "x-goog-security-token",
        "awsaccesskeyid",
    ]

    private static let secretPrefixes: [String] = [
        "sk-",
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "github_pat_",
        "xoxb-",
        "xoxp-",
        "ya29.",
        "bearer ",
        "basic ",
    ]
}

public struct DownloadPathValidator {
    private let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func resolve(
        requestedFilename: String?,
        sourceURL: URL? = nil,
        defaultFilename: String = "download"
    ) throws -> URL {
        let rawCandidate: String
        if let requestedFilename {
            rawCandidate = requestedFilename
        } else {
            rawCandidate = sourceURL?.lastPathComponent.nilIfEmpty ?? defaultFilename
        }
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateFilename(candidate)

        let base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(candidate, isDirectory: false).standardizedFileURL
        let resolvedTarget: URL
        if let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            resolvedTarget = URL(
                fileURLWithPath: symlinkDestination,
                relativeTo: target.deletingLastPathComponent()
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()
        } else {
            resolvedTarget = target.resolvingSymlinksInPath()
        }
        let basePath = base.path
        let targetPath = resolvedTarget.path
        guard targetPath.hasPrefix(basePath + "/") else {
            throw WebSafetyError(
                code: .downloadPathInvalid,
                message: "Download target escapes the configured directory."
            )
        }
        return target
    }

    private static func validateFilename(_ filename: String) throws {
        let invalid = filename.isEmpty
            || filename.hasPrefix(".")
            || filename.hasPrefix("~")
            || filename.contains("/")
            || filename.contains("\\")
            || filename.contains("..")
            || filename.contains("\u{0}")
            || URL(fileURLWithPath: filename).isFileURL && filename.hasPrefix("/")
        if invalid {
            throw WebSafetyError(
                code: .downloadPathInvalid,
                message: "Download filename must be a plain non-hidden filename inside the configured directory."
            )
        }
    }
}

private enum HostNormalizer {
    static func normalize(_ host: String) -> String {
        var normalized = decodePercentRepeated(host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if let zoneIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<zoneIndex])
        }
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    static func isBlockedLocalName(_ host: String) -> Bool {
        host == "localhost"
            || host == "ip6-localhost"
            || host == "ip6-loopback"
            || host == "broadcasthost"
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
    }

    private static func decodePercentRepeated(_ value: String) -> String {
        var current = value
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else { break }
            current = decoded
        }
        return current
    }
}

private struct IPv4Address: Equatable {
    let value: UInt32

    var presentation: String {
        [
            (value >> 24) & 0xff,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff,
        ].map(String.init).joined(separator: ".")
    }

    static func parseFlexible(_ host: String) -> IPv4Address? {
        guard !host.contains(":") else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), !parts.contains(where: { $0.isEmpty }) else {
            return nil
        }
        let numbers = parts.compactMap { parseIPv4Component(String($0)) }
        guard numbers.count == parts.count else { return nil }

        let value: UInt64
        switch numbers.count {
        case 1:
            guard numbers[0] <= 0xffff_ffff else { return nil }
            value = numbers[0]
        case 2:
            guard numbers[0] <= 0xff, numbers[1] <= 0x00ff_ffff else { return nil }
            value = (numbers[0] << 24) | numbers[1]
        case 3:
            guard numbers[0] <= 0xff, numbers[1] <= 0xff, numbers[2] <= 0xffff else { return nil }
            value = (numbers[0] << 24) | (numbers[1] << 16) | numbers[2]
        case 4:
            guard numbers.allSatisfy({ $0 <= 0xff }) else { return nil }
            value = (numbers[0] << 24) | (numbers[1] << 16) | (numbers[2] << 8) | numbers[3]
        default:
            return nil
        }
        return IPv4Address(value: UInt32(value))
    }

    static func isBlockedNetwork(_ value: UInt32) -> Bool {
        blockedRanges.contains { range in
            (value & range.mask) == (range.network & range.mask)
        }
    }

    private static func parseIPv4Component(_ component: String) -> UInt64? {
        let lower = component.lowercased()
        let base: Int
        let digits: String
        if lower.hasPrefix("0x") {
            base = 16
            digits = String(lower.dropFirst(2))
        } else if lower.count > 1 && lower.hasPrefix("0") {
            base = 8
            digits = String(lower.dropFirst())
        } else {
            base = 10
            digits = lower
        }
        guard !digits.isEmpty else { return nil }
        return UInt64(digits, radix: base)
    }

    private static let blockedRanges: [(network: UInt32, mask: UInt32)] = [
        (0x0000_0000, 0xff00_0000),  // 0.0.0.0/8
        (0x0a00_0000, 0xff00_0000),  // 10.0.0.0/8
        (0x6440_0000, 0xffc0_0000),  // 100.64.0.0/10
        (0x7f00_0000, 0xff00_0000),  // 127.0.0.0/8
        (0xa9fe_0000, 0xffff_0000),  // 169.254.0.0/16
        (0xac10_0000, 0xfff0_0000),  // 172.16.0.0/12
        (0xc000_0000, 0xffff_ff00),  // 192.0.0.0/24
        (0xc000_0200, 0xffff_ff00),  // 192.0.2.0/24
        (0xc0a8_0000, 0xffff_0000),  // 192.168.0.0/16
        (0xc612_0000, 0xfffe_0000),  // 198.18.0.0/15
        (0xc633_6400, 0xffff_ff00),  // 198.51.100.0/24
        (0xcb00_7100, 0xffff_ff00),  // 203.0.113.0/24
        (0xe000_0000, 0xf000_0000),  // 224.0.0.0/4
        (0xf000_0000, 0xf000_0000),  // 240.0.0.0/4
        (0xffff_ffff, 0xffff_ffff),  // 255.255.255.255/32
    ]
}

private struct IPv6Address: Equatable {
    let bytes: [UInt8]
    let presentation: String

    static func parse(_ host: String) -> IPv6Address? {
        guard host.contains(":") else { return nil }
        var addr = in6_addr()
        let rc = host.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard rc == 1 else { return nil }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return IPv6Address(bytes: bytes, presentation: host)
    }

    static func isBlockedNetwork(_ address: IPv6Address) -> Bool {
        let bytes = address.bytes
        guard bytes.count == 16 else { return true }

        if bytes.allSatisfy({ $0 == 0 }) { return true }  // ::/128
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }  // ::1/128
        if bytes[0] == 0xff { return true }  // ff00::/8 multicast
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
        if (bytes[0] & 0xfe) == 0xfc { return true }  // fc00::/7 unique-local
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return true }  // fec0::/10 site-local
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return true  // 2001:db8::/32 documentation
        }

        for embedded in embeddedIPv4Addresses(address) {
            if IPv4Address.isBlockedNetwork(embedded) {
                return true
            }
        }

        return false
    }

    static func embeddedIPv4(_ address: IPv6Address) -> UInt32? {
        embeddedIPv4Addresses(address).first
    }

    static func embeddedIPv4Addresses(_ address: IPv6Address) -> [UInt32] {
        let bytes = address.bytes
        guard bytes.count == 16 else { return [] }

        if isIPv4Mapped(address) || isIPv4Compatible(address) || isWellKnownNAT64(address) {
            return [uint32(bytes[12], bytes[13], bytes[14], bytes[15])]
        }

        if is6to4(address) {
            return [uint32(bytes[2], bytes[3], bytes[4], bytes[5])]
        }

        if isTeredo(address) {
            let server = uint32(bytes[4], bytes[5], bytes[6], bytes[7])
            let client = uint32(~bytes[12], ~bytes[13], ~bytes[14], ~bytes[15])
            return [server, client]
        }

        return []
    }

    private static func isIPv4Mapped(_ address: IPv6Address) -> Bool {
        let bytes = address.bytes
        return bytes.count == 16
            && bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
    }

    private static func isIPv4Compatible(_ address: IPv6Address) -> Bool {
        let bytes = address.bytes
        return bytes.count == 16
            && bytes[0..<12].allSatisfy { $0 == 0 }
            && !bytes[12..<16].allSatisfy { $0 == 0 }
    }

    private static func isWellKnownNAT64(_ address: IPv6Address) -> Bool {
        let bytes = address.bytes
        return bytes.count == 16
            && bytes[0] == 0x00
            && bytes[1] == 0x64
            && bytes[2] == 0xff
            && bytes[3] == 0x9b
            && bytes[4..<12].allSatisfy { $0 == 0 }
    }

    private static func is6to4(_ address: IPv6Address) -> Bool {
        let bytes = address.bytes
        return bytes.count == 16 && bytes[0] == 0x20 && bytes[1] == 0x02
    }

    private static func isTeredo(_ address: IPv6Address) -> Bool {
        let bytes = address.bytes
        return bytes.count == 16 && bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0
    }

    private static func uint32(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        (UInt32(b0) << 24)
            | (UInt32(b1) << 16)
            | (UInt32(b2) << 8)
            | UInt32(b3)
    }
}

private enum MetadataEndpoint {
    static func isBlockedHostname(_ host: String) -> Bool {
        metadataHostnames.contains(host)
    }

    static func isBlockedIPv4(_ value: UInt32) -> Bool {
        metadataIPv4.contains(value)
    }

    static func isBlockedIPv6(_ address: IPv6Address) -> Bool {
        if address.bytes == awsIPv6Metadata { return true }
        for embedded in IPv6Address.embeddedIPv4Addresses(address) where isBlockedIPv4(embedded) {
            return true
        }
        return false
    }

    private static let metadataHostnames: Set<String> = [
        "metadata",
        "metadata.google.internal",
        "metadata.amazonaws.com",
        "instance-data.ec2.internal",
    ]

    private static let metadataIPv4: Set<UInt32> = [
        0xa9fe_a9fe,  // 169.254.169.254
        0xa9fe_aa02,  // 169.254.170.2
        0x6464_64c8,  // 100.100.100.200
    ]

    private static let awsIPv6Metadata: [UInt8] = {
        IPv6Address.parse("fd00:ec2::254")?.bytes ?? []
    }()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
