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
    private func seedPhoto() throws -> UUID {
        let id = UUID()
        let filename = "ui-test-image.png"
        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try pngData.write(to: storageDirectory.appendingPathComponent(filename), options: .atomic)
        let json: [String: Any] = [
            "id": id.uuidString,
            "filename": filename,
            "frameString": "{{0, 0}, {300, 200}}",
            "widgetWidth": 300,
            "isLocked": false,
            "isVisible": true
        ]
        // Production stores an array of PhotoItem objects. Writing the object directly made the
        // app correctly reject the fixture and left every row-based UI test looking for a widget
        // that had never loaded.
        let data = try JSONSerialization.data(withJSONObject: [json], options: [.sortedKeys])
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

    private func expand(_ row: XCUIElement, id: UUID, in window: XCUIElement) {
        let expandedValue = NSPredicate(format: "value CONTAINS %@", "Expanded")
        let expandedSettings = window.descendants(matching: .any)["photo-expanded-settings-\(id.uuidString)"]

        // A macOS Space transition can finish after XCUIApplication reports the row as hittable.
        // Retry the user action once, but only while its explicit accessibility state still says
        // Collapsed. This never double-clicks a row that has actually expanded.
        for _ in 0..<2 where !expandedValue.evaluate(with: row) {
            clickWhenHittable(row)
            let expectation = XCTNSPredicateExpectation(predicate: expandedValue, object: row)
            if XCTWaiter().wait(for: [expectation], timeout: 3) == .completed { break }
            app.activate()
        }

        XCTAssertTrue(expandedValue.evaluate(with: row))
        XCTAssertTrue(expandedSettings.waitForExistence(timeout: 2))
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

    func testFrameInspectorDisclosureAndControlsAreReachable() throws {
        let id = try seedPhoto()
        app.launch()

        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()

        let row = window.descendants(matching: .any)["photo-row-toggle-\(id.uuidString)"]
        XCTAssertTrue(waitForHittable(row))
        expand(row, id: id, in: window)

        let expandedSettings = window.descendants(matching: .any)["photo-expanded-settings-\(id.uuidString)"]
        // Frame is deliberately the first button in this contained, labelled settings group.
        // SwiftUI currently drops identifiers from controls nested in a lazy macOS scroll view,
        // while preserving their roles and ordering in the accessibility tree.
        let frameButton = expandedSettings.buttons.firstMatch
        XCTAssertTrue(waitForHittable(frameButton))
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
        XCTAssertTrue(resetConfirmation.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRemovingPhotoRequiresAnAccessibleConfirmation() throws {
        let id = try seedPhoto()
        app.launch()

        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        let row = window.descendants(matching: .any)["photo-row-toggle-\(id.uuidString)"]
        expand(row, id: id, in: window)

        let moreActions = window.descendants(matching: .any)["photo-more-actions"]
        clickWhenHittable(moreActions)
        // Scope the title to this row's open menu. The menu-bar photo submenu also contains a
        // "Remove" item, so an application-wide title query is intentionally ambiguous.
        let remove = moreActions.descendants(matching: .menuItem)["Remove"]
        // A native macOS menu item is exposed while its menu is open, but XCTest can report
        // `isHittable == false` even though a direct click succeeds. Existence is the stable
        // contract for this role; button-style hittability polling is appropriate only after
        // the confirmation becomes an ordinary control.
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()

        let removeConfirmation = app.buttons["Remove Photo"]
        XCTAssertTrue(removeConfirmation.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
}
