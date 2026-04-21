import Foundation

// MARK: - Response Envelope

/// Standard success envelope: `{ "ok": true, "data": { ... }, "warnings": [...] }`.
@inline(__always)
func okResponse(_ data: [String: Any], warnings: [String] = []) -> String {
    var payload: [String: Any] = ["ok": true, "data": data]
    if !warnings.isEmpty { payload["warnings"] = warnings }
    return jsonString(payload)
}

/// Standard error envelope: `{ "ok": false, "error": { code, message, hint? } }`.
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

// MARK: - Arg decoding & helpers

/// Tools throw `ToolError` to short-circuit invocation with a structured message.
/// `invoke()` wraps the throw in the standard error envelope.
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

// MARK: - Date helpers

enum DateParseError: Error {
    case unparseable(String)
}

/// Resolve a timezone identifier. Throws on unknown IDs.
/// Empty / nil identifier resolves to `TimeZone.current`.
func resolveTimezone(_ identifier: String?) throws -> TimeZone {
    guard let id = identifier, !id.isEmpty else {
        return TimeZone.current
    }
    if let tz = TimeZone(identifier: id) {
        return tz
    }
    throw ToolError(
        code: "INVALID_ARGS",
        message: "Unknown IANA timezone identifier: '\(id)'",
        hint: "Pass an IANA identifier like 'America/New_York' or call list_timezones."
    )
}

/// Try a sequence of common date string formats. Returns the first successful parse.
func parseDateString(_ s: String) throws -> Date {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

    // Numeric-only → treat as Unix seconds (or millis if too large for seconds)
    if let unix = Double(trimmed) {
        if unix > 1_000_000_000_000 {  // > year 33658 in seconds → must be millis
            return Date(timeIntervalSince1970: unix / 1000.0)
        }
        return Date(timeIntervalSince1970: unix)
    }

    // ISO8601 with fractional seconds
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: trimmed) { return d }

    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: trimmed) { return d }

    // ISO date-only (yyyy-MM-dd)
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.timeZone = TimeZone(identifier: "UTC")
    dateOnly.dateFormat = "yyyy-MM-dd"
    if let d = dateOnly.date(from: trimmed) { return d }

    // RFC 2822 (e.g. "Mon, 21 Apr 2025 14:00:00 GMT")
    let rfc = DateFormatter()
    rfc.locale = Locale(identifier: "en_US_POSIX")
    rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let d = rfc.date(from: trimmed) { return d }

    // Common ambiguous formats agents tend to emit
    for fmt in [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd",
    ] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fmt
        if let d = f.date(from: trimmed) { return d }
    }

    throw DateParseError.unparseable(s)
}

func iso8601String(_ date: Date, timeZone: TimeZone) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = timeZone
    return f.string(from: date)
}

func dateInfo(_ date: Date, timeZone: TimeZone) -> [String: Any] {
    return [
        "iso8601": iso8601String(date, timeZone: timeZone),
        "unix_timestamp": date.timeIntervalSince1970,
        "timezone": timeZone.identifier,
    ]
}

// MARK: - ISO 8601 duration parsing

/// Minimal ISO-8601 duration parser. Accepts forms like
/// `P3D`, `PT2H30M`, `P1Y2M3DT4H5M6S`, `P2W`, `-P1D`.
/// Years and months are approximated using calendar arithmetic.
func parseISODuration(_ s: String) -> DateComponents? {
    var sign = 1
    var s = s
    if s.hasPrefix("-") {
        sign = -1
        s = String(s.dropFirst())
    } else if s.hasPrefix("+") {
        s = String(s.dropFirst())
    }
    guard s.hasPrefix("P") else { return nil }
    s = String(s.dropFirst())

    var components = DateComponents()
    var dateSection = true
    var current = ""
    var consumedAny = false

    for ch in s {
        if ch == "T" {
            dateSection = false
            current = ""
            continue
        }
        if ch.isNumber || ch == "." || ch == "-" {
            current.append(ch)
            continue
        }

        guard let value = Int(current) else { return nil }
        consumedAny = true
        let signed = value * sign

        if dateSection {
            switch ch {
            case "Y": components.year = signed
            case "M": components.month = signed
            case "W":
                components.day = (components.day ?? 0) + signed * 7
            case "D": components.day = (components.day ?? 0) + signed
            default: return nil
            }
        } else {
            switch ch {
            case "H": components.hour = signed
            case "M": components.minute = signed
            case "S": components.second = signed
            default: return nil
            }
        }
        current = ""
    }

    return consumedAny ? components : nil
}

// MARK: - Tools

struct CurrentTimeTool {
    static let name = "current_time"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable { let timezone: String? }
        let parsed: Args = (try? decodeArgs(args)) ?? Args(timezone: nil)
        let tz = try resolveTimezone(parsed.timezone)
        return dateInfo(Date(), timeZone: tz)
    }
}

struct FormatDateTool {
    static let name = "format_date"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable {
            let timestamp: Double?
            let date: String?
            let format: String?
            let timezone: String?
            let locale: String?
        }
        let parsed: Args = try decodeArgs(args)

        let date: Date
        if let ts = parsed.timestamp {
            date = Date(timeIntervalSince1970: ts)
        } else if let s = parsed.date {
            date = try parseOrThrow(s)
        } else {
            date = Date()
        }

        let tz = try resolveTimezone(parsed.timezone)
        let format = parsed.format ?? "iso8601"
        let formatted: String

        switch format.lowercased() {
        case "iso8601":
            formatted = iso8601String(date, timeZone: tz)
        case "rfc2822":
            let f = DateFormatter()
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            formatted = f.string(from: date)
        case "unix":
            formatted = String(format: "%.6f", date.timeIntervalSince1970)
        case "date":
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            formatted = f.string(from: date)
        case "relative":
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            f.locale = Locale(identifier: parsed.locale ?? "en_US_POSIX")
            formatted = f.localizedString(for: date, relativeTo: Date())
        default:
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: parsed.locale ?? "en_US_POSIX")
            f.timeZone = tz
            formatted = f.string(from: date)
        }

        return [
            "formatted": formatted,
            "format": format,
            "timezone": tz.identifier,
            "iso8601": iso8601String(date, timeZone: tz),
            "unix_timestamp": date.timeIntervalSince1970,
        ]
    }
}

struct ParseDateTool {
    static let name = "parse_date"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable {
            let date: String
            let timezone: String?
        }
        let parsed: Args = try decodeArgs(args)
        let date = try parseOrThrow(parsed.date)
        let tz = try resolveTimezone(parsed.timezone)
        return dateInfo(date, timeZone: tz)
    }
}

struct ConvertTimezoneTool {
    static let name = "convert_timezone"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable {
            let date: String?
            let timestamp: Double?
            let to: String
            let from: String?
        }
        let parsed: Args = try decodeArgs(args)

        let date: Date
        if let ts = parsed.timestamp {
            date = Date(timeIntervalSince1970: ts)
        } else if let s = parsed.date {
            date = try parseOrThrow(s)
        } else {
            throw ToolError(
                code: "INVALID_ARGS",
                message: "Provide either 'date' or 'timestamp'."
            )
        }

        let toTz = try resolveTimezone(parsed.to)
        var data = dateInfo(date, timeZone: toTz)
        if let from = parsed.from {
            data["source_timezone"] = from
        }
        return data
    }
}

struct AddDurationTool {
    static let name = "add_duration"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable {
            let date: String?
            let timestamp: Double?
            let duration: String?
            let seconds: Double?
            let timezone: String?
        }
        let parsed: Args = try decodeArgs(args)

        let base: Date
        if let ts = parsed.timestamp {
            base = Date(timeIntervalSince1970: ts)
        } else if let s = parsed.date {
            base = try parseOrThrow(s)
        } else {
            base = Date()
        }

        let tz = try resolveTimezone(parsed.timezone)

        let result: Date
        if let secs = parsed.seconds {
            result = base.addingTimeInterval(secs)
        } else if let dur = parsed.duration {
            guard let comps = parseISODuration(dur) else {
                throw ToolError(
                    code: "INVALID_ARGS",
                    message: "Could not parse ISO 8601 duration: '\(dur)'",
                    hint: "Examples: 'P3D' (3 days), 'PT2H30M' (2h 30m), 'P1Y' (1 year), '-P1W' (-1 week)."
                )
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz
            guard let next = calendar.date(byAdding: comps, to: base) else {
                throw ToolError(
                    code: "INVALID_ARGS",
                    message: "Could not apply duration components"
                )
            }
            result = next
        } else {
            throw ToolError(
                code: "INVALID_ARGS",
                message: "Provide either 'duration' (ISO 8601) or 'seconds'.",
                hint: "Examples: duration='P1DT2H' or seconds=3600."
            )
        }

        return dateInfo(result, timeZone: tz)
    }
}

struct DiffDatesTool {
    static let name = "diff_dates"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable {
            let from: String
            let to: String
            let unit: String?
        }
        let parsed: Args = try decodeArgs(args)
        let fromDate = try parseOrThrow(parsed.from)
        let toDate = try parseOrThrow(parsed.to)

        let totalSeconds = toDate.timeIntervalSince(fromDate)
        let absSec = abs(Int(totalSeconds.rounded(.towardZero)))
        let days = absSec / 86_400
        let hours = (absSec % 86_400) / 3600
        let minutes = (absSec % 3600) / 60
        let seconds = absSec % 60

        var iso = totalSeconds < 0 ? "-P" : "P"
        if days > 0 { iso += "\(days)D" }
        if hours > 0 || minutes > 0 || seconds > 0 {
            iso += "T"
            if hours > 0 { iso += "\(hours)H" }
            if minutes > 0 { iso += "\(minutes)M" }
            if seconds > 0 { iso += "\(seconds)S" }
        }
        if iso == "P" || iso == "-P" { iso = "PT0S" }

        let summary =
            "\(days)d \(hours)h \(minutes)m \(seconds)s"
            + (totalSeconds < 0 ? " (negative)" : "")
        let utc = TimeZone(identifier: "UTC")!

        return [
            "seconds": totalSeconds,
            "iso_duration": iso,
            "summary": summary,
            "from": [
                "iso8601": iso8601String(fromDate, timeZone: utc),
                "unix_timestamp": fromDate.timeIntervalSince1970,
            ],
            "to": [
                "iso8601": iso8601String(toDate, timeZone: utc),
                "unix_timestamp": toDate.timeIntervalSince1970,
            ],
        ]
    }
}

struct ListTimezonesTool {
    static let name = "list_timezones"

    func run(args: String) throws -> [String: Any] {
        struct Args: Decodable { let prefix: String? }
        let parsed: Args = (try? decodeArgs(args)) ?? Args(prefix: nil)
        let prefix = (parsed.prefix ?? "").lowercased()
        let identifiers: [String] =
            prefix.isEmpty
            ? TimeZone.knownTimeZoneIdentifiers.sorted()
            : TimeZone.knownTimeZoneIdentifiers.filter { $0.lowercased().hasPrefix(prefix) }.sorted()
        return [
            "count": identifiers.count,
            "identifiers": identifiers,
        ]
    }
}

/// Parse a date string and rethrow as a `ToolError` with a useful hint.
func parseOrThrow(_ s: String) throws -> Date {
    do {
        return try parseDateString(s)
    } catch {
        throw ToolError(
            code: "INVALID_ARGS",
            message: "Could not parse date string: '\(s)'",
            hint: "Accepts ISO 8601, RFC 2822, 'yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss', or a numeric Unix timestamp."
        )
    }
}

// MARK: - Plugin Context

private final class PluginContext {
    let currentTime = CurrentTimeTool()
    let formatDate = FormatDateTool()
    let parseDate = ParseDateTool()
    let convertTimezone = ConvertTimezoneTool()
    let addDuration = AddDurationTool()
    let diffDates = DiffDatesTool()
    let listTimezones = ListTimezonesTool()
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
              "plugin_id": "osaurus.time",
              "name": "Time",
              "description": "Date and time arithmetic across timezones — current time, parsing, formatting, conversions, durations, diffs.",
              "license": "MIT",
              "authors": ["Osaurus Team"],
              "min_macos": "13.0",
              "min_osaurus": "0.5.0",
              "capabilities": {
                "tools": [
                  {
                    "id": "current_time",
                    "description": "Get the current date and time, optionally in a specific IANA timezone.",
                    "parameters": {"type":"object","properties":{"timezone":{"type":"string","description":"IANA timezone identifier (e.g. 'America/New_York', 'UTC'). Defaults to system timezone."}},"required":[]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "format_date",
                    "description": "Format a Unix timestamp or date string into a chosen format.",
                    "parameters": {"type":"object","properties":{"timestamp":{"type":"number","description":"Unix timestamp in seconds. Mutually exclusive with 'date'."},"date":{"type":"string","description":"Date string to format. Accepts ISO 8601, RFC 2822, 'yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss', or a numeric Unix timestamp string."},"format":{"type":"string","description":"Output format: 'iso8601' (default), 'rfc2822', 'unix', 'date', 'relative', or a custom LDML pattern (e.g. 'EEE, MMM d').","default":"iso8601"},"timezone":{"type":"string","description":"IANA timezone identifier for output. Defaults to system timezone."},"locale":{"type":"string","description":"BCP 47 locale used for 'relative' or custom LDML output. Defaults to 'en_US_POSIX'."}},"required":[]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "parse_date",
                    "description": "Parse a date string into a Unix timestamp + ISO 8601 in the given timezone. Use this before any date arithmetic.",
                    "parameters": {"type":"object","properties":{"date":{"type":"string","description":"Date string to parse. Accepts ISO 8601, RFC 2822, 'yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss', or a numeric Unix timestamp."},"timezone":{"type":"string","description":"IANA timezone identifier for the returned representation. Defaults to system timezone."}},"required":["date"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "convert_timezone",
                    "description": "Re-express an instant in a different timezone. Returns the same wall instant projected into the target zone.",
                    "parameters": {"type":"object","properties":{"date":{"type":"string","description":"Date string to convert. Mutually exclusive with 'timestamp'."},"timestamp":{"type":"number","description":"Unix timestamp in seconds. Mutually exclusive with 'date'."},"to":{"type":"string","description":"Target IANA timezone identifier."},"from":{"type":"string","description":"Optional: original timezone of a naive date string. Recorded in the response but does not shift the instant."}},"required":["to"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "add_duration",
                    "description": "Add (or subtract) a duration from a date. Pass either an ISO 8601 duration like 'P1DT2H' or a raw 'seconds' value.",
                    "parameters": {"type":"object","properties":{"date":{"type":"string","description":"Base date string. Defaults to now."},"timestamp":{"type":"number","description":"Base Unix timestamp in seconds. Defaults to now."},"duration":{"type":"string","description":"ISO 8601 duration, e.g. 'P3D' (3 days), 'PT2H30M' (2h30m), 'P1Y' (1 year), 'P2W' (2 weeks). Prefix with '-' to subtract."},"seconds":{"type":"number","description":"Raw seconds offset (positive or negative). Mutually exclusive with 'duration'."},"timezone":{"type":"string","description":"IANA timezone identifier used for calendar arithmetic (year/month boundaries) and the response. Defaults to system timezone."}},"required":[]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "diff_dates",
                    "description": "Compute the difference between two dates. Returns total seconds, an ISO 8601 duration, and a human summary.",
                    "parameters": {"type":"object","properties":{"from":{"type":"string","description":"Earlier date string or numeric Unix timestamp."},"to":{"type":"string","description":"Later date string or numeric Unix timestamp."},"unit":{"type":"string","description":"Optional hint for the response summary granularity. Currently unused; reserved."}},"required":["from","to"]},
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "list_timezones",
                    "description": "List all known IANA timezone identifiers, optionally filtered by prefix. Use this to validate user-supplied zones.",
                    "parameters": {"type":"object","properties":{"prefix":{"type":"string","description":"Case-insensitive prefix filter (e.g. 'america/' or 'asia/tok'). Empty returns all."}},"required":[]},
                    "requirements": [],
                    "permission_policy": "allow"
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
            case CurrentTimeTool.name: data = try ctx.currentTime.run(args: payload)
            case FormatDateTool.name: data = try ctx.formatDate.run(args: payload)
            case ParseDateTool.name: data = try ctx.parseDate.run(args: payload)
            case ConvertTimezoneTool.name: data = try ctx.convertTimezone.run(args: payload)
            case AddDurationTool.name: data = try ctx.addDuration.run(args: payload)
            case DiffDatesTool.name: data = try ctx.diffDates.run(args: payload)
            case ListTimezonesTool.name: data = try ctx.listTimezones.run(args: payload)
            default:
                return makeCString(
                    errorResponse(
                        code: "UNKNOWN_TOOL",
                        message: "Unknown tool: '\(id)'.",
                        hint:
                            "Available tools: current_time, format_date, parse_date, convert_timezone, add_duration, diff_dates, list_timezones."
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
