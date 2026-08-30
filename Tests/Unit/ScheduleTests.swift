import XCTest
@testable import Arras

final class ScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    func testDaytimeWindowUsesCurrentWeekday() {
        let monday = 1 << 1
        XCTAssertTrue(Schedule.isActive(
            startMinutes: 9 * 60,
            endMinutes: 17 * 60,
            weekdayMask: monday,
            at: date(2026, 8, 31, 12, 0),
            calendar: calendar
        ))
        XCTAssertFalse(Schedule.isActive(
            startMinutes: 9 * 60,
            endMinutes: 17 * 60,
            weekdayMask: monday,
            at: date(2026, 9, 1, 12, 0),
            calendar: calendar
        ))
    }

    func testOvernightWindowAfterMidnightBelongsToPreviousDay() {
        let friday = 1 << 5
        XCTAssertTrue(Schedule.isActive(
            startMinutes: 22 * 60,
            endMinutes: 6 * 60,
            weekdayMask: friday,
            at: date(2026, 9, 5, 1, 0),
            calendar: calendar
        ))
        XCTAssertFalse(Schedule.isActive(
            startMinutes: 22 * 60,
            endMinutes: 6 * 60,
            weekdayMask: friday,
            at: date(2026, 9, 6, 1, 0),
            calendar: calendar
        ))
    }

    func testZeroLengthWindowIsNeverActive() {
        XCTAssertFalse(Schedule.isActive(
            startMinutes: 600,
            endMinutes: 600,
            weekdayMask: 0b111_1111,
            at: date(2026, 8, 31, 10, 0),
            calendar: calendar
        ))
    }

    func testNextBoundaryChoosesSoonestStartOrEnd() {
        let now = date(2026, 8, 31, 9, 30)
        XCTAssertEqual(
            Schedule.secondsUntilNextBoundary(
                startMinutes: 10 * 60,
                endMinutes: 11 * 60,
                from: now,
                calendar: calendar
            ),
            30 * 60,
            accuracy: 0.1
        )
    }
}
