import XCTest

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
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    func testSingleSettingsWindowNavigatesAllTabs() {
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)

        // Native macOS TabView items are exposed as radio buttons on some SDKs
        // and buttons on others. Querying by accessible label keeps this test
        // focused on the user-visible tab instead of an SDK-specific role.
        let preferences = window.descendants(matching: .any)["Preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 2))
        preferences.click()
        XCTAssertTrue(window.staticTexts["GENERAL"].waitForExistence(timeout: 2))

        let privacy = window.descendants(matching: .any)["Privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 2))
        privacy.click()
        XCTAssertTrue(window.staticTexts["SCREEN SHARING & RECORDING"].waitForExistence(timeout: 2))

        window.descendants(matching: .any)["Photos"].click()
        XCTAssertTrue(window.buttons["Choose Photo…"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.windows.count, 1)
    }
}
