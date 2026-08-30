import XCTest
import Foundation

final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["ARRAS_UI_TEST_STORAGE_DIR"] = storageDirectory.path
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    /// A tiny valid `photos.json` entry and 1x1 image are enough to exercise the Settings row
    /// without relying on a Finder picker or a user's photo library.
    private func seedPhoto(
        scheduleEnabled: Bool = true,
        scheduleStartMinutes: Int = 22 * 60,
        scheduleEndMinutes: Int = 6 * 60,
        scheduleWeekdays: Int = 0b010_0000
    ) throws -> UUID {
        let id = UUID()
        let filename = "schedule-test-image.png"
        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try pngData.write(to: storageDirectory.appendingPathComponent(filename), options: .atomic)
        let json: [String: Any] = [
            "id": id.uuidString,
            "filename": filename,
            "frameString": "{{0, 0}, {300, 200}}",
            "widgetWidth": 300,
            "isLocked": false,
            "isVisible": true,
            "scheduleEnabled": scheduleEnabled,
            "scheduleStartMinutes": scheduleStartMinutes,
            "scheduleEndMinutes": scheduleEndMinutes,
            "scheduleWeekdays": scheduleWeekdays
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: storageDirectory.appendingPathComponent("photos.json"), options: .atomic)
        return id
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func clickWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 5) {
        guard waitForHittable(element, timeout: timeout) else {
            XCTFail("Expected element to be visible and hittable")
            return
        }
        element.click()
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if waitForHittable(element, timeout: 0.2) {
                return true
            }
            if scrollView.exists && scrollView.isHittable {
                scrollView.swipeUp()
            }
        } while Date() < deadline
        return waitForHittable(element, timeout: 0.2)
    }

    func testSingleSettingsWindowNavigatesAllTabs() {
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        XCTAssertEqual(app.windows.count, 1)

        // Native macOS TabView items are exposed as radio buttons on some SDKs
        // and buttons on others. Querying by accessible label keeps this test
        // focused on the user-visible tab instead of an SDK-specific role.
        let preferences = window.descendants(matching: .any)["Preferences"]
        clickWhenHittable(preferences)
        XCTAssertTrue(window.staticTexts["GENERAL"].waitForExistence(timeout: 2))

        let privacy = window.descendants(matching: .any)["Privacy"]
        clickWhenHittable(privacy)
        XCTAssertTrue(window.staticTexts["SCREEN SHARING & RECORDING"].waitForExistence(timeout: 2))

        clickWhenHittable(window.descendants(matching: .any)["Photos"])
        XCTAssertTrue(window.buttons["Choose Photo…"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.windows.count, 1)
    }

    func testPhotoScheduleAndFrameControlsAreReachable() throws {
        let id = try seedPhoto()
        app.launch()

        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()

        let row = window.descendants(matching: .any)["photo-row-toggle-\(id.uuidString)"]
        XCTAssertTrue(waitForHittable(row))
        let rowSummary = row.value as? String ?? ""
        XCTAssertTrue(rowSummary.contains("Schedule"))
        XCTAssertTrue(rowSummary.contains("22:00–06:00 overnight"))
        row.click()

        let editor = window.descendants(matching: .any)["photo-schedule-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        let scheduleToggle = window.descendants(matching: .any)["photo-schedule-toggle"]
        clickWhenHittable(scheduleToggle)
        clickWhenHittable(scheduleToggle)

        let sunday = window.descendants(matching: .any)["photo-schedule-weekday-sun"]
        clickWhenHittable(sunday)
        clickWhenHittable(sunday)

        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-weekday-mon"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-weekday-tue"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-weekday-wed"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-weekday-thu"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-weekday-fri"].exists)
        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-weekday-sat"].exists)
        let start = window.descendants(matching: .any)["photo-schedule-start"]
        clickWhenHittable(start)
        app.typeKey(.escape, modifierFlags: [])
        let end = window.descendants(matching: .any)["photo-schedule-end"]
        clickWhenHittable(end)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window.descendants(matching: .any)["photo-schedule-overnight"].exists)

        let frameButton = window.descendants(matching: .any)["photo-frame-inspector"]
        XCTAssertTrue(reveal(frameButton, in: window.scrollViews.firstMatch))
        clickWhenHittable(frameButton)

        let inspector = app.descendants(matching: .any)["frame-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 2))
        let advanced = app.descendants(matching: .any)["frame-advanced-toggle"]
        XCTAssertTrue(advanced.exists)
        XCTAssertTrue(app.descendants(matching: .any)["frame-reset"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["frame-done"].exists)

        // Expand the real disclosure and interact with a control inside it. This exercises the
        // user-facing path rather than inspecting SwiftUI implementation details.
        clickWhenHittable(advanced)
        XCTAssertTrue(app.descendants(matching: .any)["frame-border-stroke"].waitForExistence(timeout: 2))
        let edgeFade = app.descendants(matching: .any)["frame-edge-fade"]
        clickWhenHittable(edgeFade)
        clickWhenHittable(edgeFade)
        clickWhenHittable(advanced)

        clickWhenHittable(app.descendants(matching: .any)["frame-reset"])
        let resetConfirmation = app.buttons["Reset Frame"]
        XCTAssertTrue(waitForHittable(resetConfirmation))
        clickWhenHittable(app.buttons["Cancel"])
    }

    func testRemovingPhotoRequiresAnAccessibleConfirmation() throws {
        let id = try seedPhoto(scheduleEnabled: false)
        app.launch()

        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        let row = window.descendants(matching: .any)["photo-row-toggle-\(id.uuidString)"]
        clickWhenHittable(row)

        let moreActions = window.descendants(matching: .any)["photo-more-actions"]
        clickWhenHittable(moreActions)
        let remove = app.menuItems["Remove"]
        clickWhenHittable(remove)

        let removeConfirmation = app.buttons["Remove Photo"]
        XCTAssertTrue(waitForHittable(removeConfirmation))
        clickWhenHittable(app.buttons["Cancel"])
    }
}
