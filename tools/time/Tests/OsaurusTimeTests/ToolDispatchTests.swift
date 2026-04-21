import XCTest

@testable import OsaurusTime

/// End-to-end exercises of each tool's `run(args:)` method, using the in-process
/// implementations (not the C ABI). Verifies the standard envelope and the
/// data shape every tool returns.
final class ToolDispatchTests: XCTestCase {

    // MARK: current_time

    func test_currentTime_returnsISOAndUnixAndTimezone() throws {
        let tool = CurrentTimeTool()
        let data = try tool.run(args: #"{"timezone": "UTC"}"#)
        // Foundation normalizes the UTC identifier to "GMT" on macOS;
        // accept either form.
        let tz = data["timezone"] as? String
        XCTAssertTrue(tz == "UTC" || tz == "GMT", "unexpected timezone: \(tz ?? "nil")")
        XCTAssertNotNil(data["iso8601"] as? String)
        let unix = data["unix_timestamp"] as? Double ?? 0
        XCTAssertGreaterThan(unix, 1_700_000_000)  // sanity: after ~2023
    }

    func test_currentTime_unknownTimezoneThrows() {
        let tool = CurrentTimeTool()
        XCTAssertThrowsError(try tool.run(args: #"{"timezone": "Atlantis/Lost"}"#)) { error in
            XCTAssertEqual((error as? ToolError)?.code, "INVALID_ARGS")
        }
    }

    func test_currentTime_emptyArgsUsesSystemTimezone() throws {
        let tool = CurrentTimeTool()
        let data = try tool.run(args: "{}")
        XCTAssertEqual(data["timezone"] as? String, TimeZone.current.identifier)
    }

    // MARK: format_date

    func test_formatDate_iso8601FromTimestamp() throws {
        let tool = FormatDateTool()
        let data = try tool.run(args: #"{"timestamp": 1745244000, "timezone": "UTC"}"#)
        XCTAssertEqual(data["formatted"] as? String, "2025-04-21T14:00:00.000Z")
    }

    func test_formatDate_acceptsDateString() throws {
        let tool = FormatDateTool()
        let data = try tool.run(args: #"{"date": "2025-04-21T14:00:00Z", "format": "date", "timezone": "UTC"}"#)
        XCTAssertEqual(data["formatted"] as? String, "2025-04-21")
    }

    func test_formatDate_unknownTimezoneThrows() {
        let tool = FormatDateTool()
        XCTAssertThrowsError(try tool.run(args: #"{"timestamp": 0, "timezone": "Atlantis/Lost"}"#))
    }

    // MARK: parse_date

    func test_parseDate_returnsTimestampAndIso() throws {
        let tool = ParseDateTool()
        let data = try tool.run(args: #"{"date": "2025-04-21T14:00:00Z", "timezone": "UTC"}"#)
        XCTAssertEqual(data["unix_timestamp"] as? Double, 1745244000.0)
        let tz = data["timezone"] as? String
        XCTAssertTrue(tz == "UTC" || tz == "GMT", "unexpected timezone: \(tz ?? "nil")")
    }

    func test_parseDate_throwsOnGarbage() {
        let tool = ParseDateTool()
        XCTAssertThrowsError(try tool.run(args: #"{"date": "not a date"}"#)) { error in
            XCTAssertEqual((error as? ToolError)?.code, "INVALID_ARGS")
        }
    }

    // MARK: convert_timezone

    func test_convertTimezone_recordsSourceZone() throws {
        let tool = ConvertTimezoneTool()
        let data = try tool.run(args: #"{"timestamp": 0, "to": "America/New_York", "from": "UTC"}"#)
        XCTAssertEqual(data["timezone"] as? String, "America/New_York")
        XCTAssertEqual(data["source_timezone"] as? String, "UTC")
    }

    func test_convertTimezone_requiresDateOrTimestamp() {
        let tool = ConvertTimezoneTool()
        XCTAssertThrowsError(try tool.run(args: #"{"to": "UTC"}"#))
    }

    // MARK: add_duration

    func test_addDuration_secondsOffsetWorks() throws {
        let tool = AddDurationTool()
        let data = try tool.run(args: #"{"timestamp": 1000, "seconds": 3600, "timezone": "UTC"}"#)
        XCTAssertEqual(data["unix_timestamp"] as? Double, 4600.0)
    }

    func test_addDuration_isoDurationWorks() throws {
        let tool = AddDurationTool()
        let data = try tool.run(args: #"{"timestamp": 0, "duration": "P1D", "timezone": "UTC"}"#)
        // 1 day = 86400 seconds
        XCTAssertEqual(data["unix_timestamp"] as? Double, 86400.0)
    }

    func test_addDuration_negativeIsoWorks() throws {
        let tool = AddDurationTool()
        let data = try tool.run(args: #"{"timestamp": 86400, "duration": "-P1D", "timezone": "UTC"}"#)
        XCTAssertEqual(data["unix_timestamp"] as? Double, 0.0)
    }

    func test_addDuration_invalidIsoThrows() {
        let tool = AddDurationTool()
        XCTAssertThrowsError(try tool.run(args: #"{"timestamp": 0, "duration": "invalid"}"#))
    }

    func test_addDuration_requiresOne() {
        let tool = AddDurationTool()
        XCTAssertThrowsError(try tool.run(args: #"{"timestamp": 0}"#))
    }

    // MARK: diff_dates

    func test_diffDates_returnsSecondsAndIso() throws {
        let tool = DiffDatesTool()
        let data = try tool.run(args: #"{"from": "2025-04-21T00:00:00Z", "to": "2025-04-22T01:30:15Z"}"#)
        XCTAssertEqual(data["seconds"] as? Double, 86400 + 5400 + 15)
        XCTAssertEqual(data["iso_duration"] as? String, "P1DT1H30M15S")
    }

    func test_diffDates_negativeIsSigned() throws {
        let tool = DiffDatesTool()
        let data = try tool.run(args: #"{"from": "2025-04-22T00:00:00Z", "to": "2025-04-21T00:00:00Z"}"#)
        let iso = data["iso_duration"] as? String
        XCTAssertNotNil(iso)
        XCTAssertTrue(iso!.hasPrefix("-P"), "expected negative ISO duration, got \(iso!)")
    }

    func test_diffDates_zeroDifferenceUsesPT0S() throws {
        let tool = DiffDatesTool()
        let data = try tool.run(args: #"{"from": "2025-04-21T00:00:00Z", "to": "2025-04-21T00:00:00Z"}"#)
        XCTAssertEqual(data["iso_duration"] as? String, "PT0S")
    }

    // MARK: list_timezones

    func test_listTimezones_returnsAll() throws {
        let tool = ListTimezonesTool()
        let data = try tool.run(args: "{}")
        let count = data["count"] as? Int ?? 0
        XCTAssertGreaterThan(count, 100, "should return many IANA identifiers")
    }

    func test_listTimezones_filtersByPrefixCaseInsensitive() throws {
        let tool = ListTimezonesTool()
        let data = try tool.run(args: #"{"prefix": "AMERICA/"}"#)
        let ids = data["identifiers"] as? [String] ?? []
        XCTAssertTrue(!ids.isEmpty, "America/ prefix should match many zones")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("America/") })
    }
}
