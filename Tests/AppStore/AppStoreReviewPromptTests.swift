import XCTest
@testable import Arras

@MainActor
final class AppStoreReviewPromptTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        suiteName = "com.yashashwi.arras.reviewPromptTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testRequiresThreeDistinctActiveDaysAndWidgets() {
        let prompt = AppStoreReviewPrompt(defaults: defaults, calendar: calendar)
        var requested = 0

        XCTAssertFalse(prompt.evaluate(photoCount: 3, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 1)) { requested += 1 })
        XCTAssertFalse(prompt.evaluate(photoCount: 3, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 1)) { requested += 1 })
        XCTAssertFalse(prompt.evaluate(photoCount: 3, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 2)) { requested += 1 })
        // Third day, but not enough widgets yet.
        XCTAssertFalse(prompt.evaluate(photoCount: 1, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 3)) { requested += 1 })
        XCTAssertEqual(requested, 0)

        // Third day with a collage triggers once.
        XCTAssertTrue(prompt.evaluate(photoCount: 1, collageCount: 1, currentVersion: "2.5.3", now: date(2026, 11, 3)) { requested += 1 })
        XCTAssertEqual(requested, 1)

        // Same version never prompts again.
        XCTAssertFalse(prompt.evaluate(photoCount: 4, collageCount: 1, currentVersion: "2.5.3", now: date(2027, 4, 1)) { requested += 1 })
        XCTAssertEqual(requested, 1)
    }

    func testRespectsNinetyDayCooldownAcrossVersions() {
        let prompt = AppStoreReviewPrompt(defaults: defaults, calendar: calendar)
        var requested = 0

        _ = prompt.evaluate(photoCount: 2, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 1)) { requested += 1 }
        _ = prompt.evaluate(photoCount: 2, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 2)) { requested += 1 }
        XCTAssertTrue(prompt.evaluate(photoCount: 2, collageCount: 0, currentVersion: "2.5.3", now: date(2026, 11, 3)) { requested += 1 })
        XCTAssertEqual(requested, 1)

        // New version within 90 days does not re-prompt.
        XCTAssertFalse(prompt.evaluate(photoCount: 2, collageCount: 0, currentVersion: "2.6.0", now: date(2026, 12, 15)) { requested += 1 })
        XCTAssertEqual(requested, 1)

        // New version after 90 days prompts once more.
        XCTAssertTrue(prompt.evaluate(photoCount: 2, collageCount: 0, currentVersion: "2.6.0", now: date(2027, 2, 5)) { requested += 1 })
        XCTAssertEqual(requested, 2)
    }
}
