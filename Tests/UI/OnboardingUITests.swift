import XCTest

final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = uiTestStorage(prefix: "ArrasOnboardingUITests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-onboarding"]
        app.launchEnvironment["ARRAS_UI_TEST_STORAGE_DIR"] = directory.path
    }

    override func tearDownWithError() throws {
        app.terminate()
        UserDefaults.standard.removePersistentDomain(forName: "arras.onboarding-tests." + directory.lastPathComponent)
        try? FileManager.default.removeItem(at: directory)
    }

    func testTourPreviewsDoNotChangeLibraryAndSampleIsExplicitAndDurable() throws {
        app.launch(); app.activate()
        let tour = app.windows["Welcome to Arras"]
        XCTAssertTrue(tour.waitForExistence(timeout: 10))
        capture(tour, "Welcome")
        tour.buttons["onboarding-next"].click()
        XCTAssertTrue(tour.staticTexts["Start with one photo."].waitForExistence(timeout: 4))
        let frame = tour.descendants(matching: .any)["onboarding-print-preview"]
        XCTAssertTrue(frame.waitForExistence(timeout: 4))
        frame.click()
        capture(tour, "Photos")
        tour.buttons["onboarding-next"].click()
        XCTAssertTrue(tour.staticTexts["Together. Still individual."].waitForExistence(timeout: 4))
        capture(tour, "Collages")
        tour.buttons["onboarding-next"].click()
        XCTAssertTrue(tour.radioGroups["onboarding-depth-preview"].waitForExistence(timeout: 4))
        tour.radioButtons["Floating"].click()
        XCTAssertEqual((tour.radioButtons["Floating"].value as? NSNumber)?.intValue, 1)
        capture(tour, "Layers")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photos.json").path))
        tour.buttons["onboarding-back"].click()
        XCTAssertTrue(tour.staticTexts["Together. Still individual."].waitForExistence(timeout: 4))
        tour.buttons["onboarding-next"].click()
        tour.buttons["onboarding-next"].click()
        let sample = tour.buttons["onboarding-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 4))
        let support = tour.links["support-arras"]
        #if ARRAS_APP_STORE
        XCTAssertFalse(support.exists, "Store purchasers never receive a support purchase prompt")
        #else
        XCTAssertTrue(support.exists)
        #endif
        capture(tour, "Ready")
        sample.click()
        let settings = app.windows["Arras"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        XCTAssertFalse(tour.exists)
        let saved = try Data(contentsOf: directory.appendingPathComponent("photos.json"))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.filter { $0["desktopCollage"] != nil }.count, 1)
        app.terminate(); app.launch(); app.activate()
        XCTAssertFalse(app.windows["Welcome to Arras"].waitForExistence(timeout: 2))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), saved)
    }

    func testSkipIsRememberedAndTourCanBeReplayedWithoutDuplicatingSettings() throws {
        app.launch(); app.activate()
        let tour = app.windows["Welcome to Arras"]
        XCTAssertTrue(tour.waitForExistence(timeout: 10))
        tour.buttons["onboarding-skip"].click()
        let settings = app.windows["Arras"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        XCTAssertFalse(tour.exists)
        settings.descendants(matching: .any)["Preferences"].click()
        let replay = settings.buttons["show-onboarding"]
        for _ in 0..<8 {
            if replay.exists && replay.isHittable { break }
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(replay.waitForExistence(timeout: 5))
        #if ARRAS_APP_STORE
        XCTAssertFalse(settings.links["support-arras"].exists)
        #else
        XCTAssertTrue(settings.links["support-arras"].exists)
        #endif
        replay.click()
        XCTAssertTrue(tour.waitForExistence(timeout: 6))
        tour.buttons["onboarding-skip"].click()
        XCTAssertEqual(app.windows.matching(identifier: "Arras").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photos.json").path))
    }

    private func capture(_ window: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Onboarding \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
