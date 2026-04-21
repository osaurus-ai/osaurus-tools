import XCTest

@testable import OsaurusTime

final class DateParsingTests: XCTestCase {

    // MARK: parseDateString

    func test_parseDateString_acceptsISO8601WithFractionalSeconds() throws {
        let date = try parseDateString("2025-04-21T14:00:00.500Z")
        XCTAssertEqual(date.timeIntervalSince1970, 1745244000.5, accuracy: 0.001)
    }

    func test_parseDateString_acceptsISO8601WithoutFractionalSeconds() throws {
        let date = try parseDateString("2025-04-21T14:00:00Z")
        XCTAssertEqual(date.timeIntervalSince1970, 1745244000.0, accuracy: 0.001)
    }

    func test_parseDateString_acceptsDateOnlyAsUTC() throws {
        let date = try parseDateString("2025-04-21")
        // 2025-04-21T00:00:00Z = 1745193600
        XCTAssertEqual(date.timeIntervalSince1970, 1745193600.0, accuracy: 0.001)
    }

    func test_parseDateString_acceptsRFC2822() throws {
        let date = try parseDateString("Mon, 21 Apr 2025 14:00:00 GMT")
        XCTAssertEqual(date.timeIntervalSince1970, 1745244000.0, accuracy: 0.001)
    }

    func test_parseDateString_acceptsUnixSecondsAsString() throws {
        let date = try parseDateString("1745244000")
        XCTAssertEqual(date.timeIntervalSince1970, 1745244000.0, accuracy: 0.001)
    }

    func test_parseDateString_treatsLargeNumbersAsMillis() throws {
        let date = try parseDateString("1745244000000")
        XCTAssertEqual(date.timeIntervalSince1970, 1745244000.0, accuracy: 0.001)
    }

    func test_parseDateString_throwsOnGarbage() {
        XCTAssertThrowsError(try parseDateString("not a date")) { error in
            guard case DateParseError.unparseable = error else {
                XCTFail("expected DateParseError.unparseable, got \(error)")
                return
            }
        }
    }

    // MARK: parseISODuration

    func test_parseISODuration_days() {
        let comps = parseISODuration("P3D")
        XCTAssertEqual(comps?.day, 3)
        XCTAssertNil(comps?.year)
    }

    func test_parseISODuration_weeksMapToDays() {
        let comps = parseISODuration("P2W")
        XCTAssertEqual(comps?.day, 14)
    }

    func test_parseISODuration_hoursAndMinutes() {
        let comps = parseISODuration("PT2H30M")
        XCTAssertEqual(comps?.hour, 2)
        XCTAssertEqual(comps?.minute, 30)
    }

    func test_parseISODuration_combined() {
        let comps = parseISODuration("P1Y2M3DT4H5M6S")
        XCTAssertEqual(comps?.year, 1)
        XCTAssertEqual(comps?.month, 2)
        XCTAssertEqual(comps?.day, 3)
        XCTAssertEqual(comps?.hour, 4)
        XCTAssertEqual(comps?.minute, 5)
        XCTAssertEqual(comps?.second, 6)
    }

    func test_parseISODuration_negativeFlipsAllComponents() {
        let comps = parseISODuration("-P1DT2H")
        XCTAssertEqual(comps?.day, -1)
        XCTAssertEqual(comps?.hour, -2)
    }

    func test_parseISODuration_emptyReturnsNil() {
        XCTAssertNil(parseISODuration("P"))
        XCTAssertNil(parseISODuration("PT"))
    }

    func test_parseISODuration_rejectsMissingP() {
        XCTAssertNil(parseISODuration("3D"))
        XCTAssertNil(parseISODuration(""))
    }

    func test_parseISODuration_rejectsInvalidUnits() {
        XCTAssertNil(parseISODuration("P3X"))
    }

    // MARK: resolveTimezone

    func test_resolveTimezone_nilReturnsCurrent() throws {
        let tz = try resolveTimezone(nil)
        XCTAssertEqual(tz.identifier, TimeZone.current.identifier)
    }

    func test_resolveTimezone_emptyStringReturnsCurrent() throws {
        let tz = try resolveTimezone("")
        XCTAssertEqual(tz.identifier, TimeZone.current.identifier)
    }

    func test_resolveTimezone_validIANAIdentifier() throws {
        let tz = try resolveTimezone("America/New_York")
        XCTAssertEqual(tz.identifier, "America/New_York")
    }

    func test_resolveTimezone_throwsOnUnknownIdentifier() {
        XCTAssertThrowsError(try resolveTimezone("Mars/Olympus_Mons")) { error in
            guard let toolError = error as? ToolError else {
                XCTFail("expected ToolError, got \(error)")
                return
            }
            XCTAssertEqual(toolError.code, "INVALID_ARGS")
        }
    }
}
