import XCTest
import Foundation

final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storageDirectory: URL!

    private struct FeatureFixture {
        let photoID: UUID
        let spaceID: UUID
        let secondSlideshowID: UUID
        let liveFolderID: UUID
        let videoID: UUID
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageDirectory = uiTestStorage(prefix: "ArrasUITests")
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["ARRAS_UI_TEST_STORAGE_DIR"] = storageDirectory.path
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    #if ARRAS_APP_STORE
    func testAppStoreFooterUpdatesAndPrivacyDisclosure() throws {
        _ = try seedPhoto()
        app.launch(); app.activate()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        XCTAssertTrue(window.links["footer-star-on-github"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["Check for Updates"].exists)
        let photos = XCTAttachment(screenshot: window.screenshot())
        photos.name = "App Store Photos footer"; photos.lifetime = .keepAlways; add(photos)
        clickWhenHittable(window.descendants(matching: .any)["Preferences"])
        let updateAction = window.buttons["settings-update-action"]
        let preferencesScroll = window.scrollViews.firstMatch
        for _ in 0..<5 {
            if updateAction.exists && preferencesScroll.frame.contains(updateAction.frame) { break }
            preferencesScroll.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(updateAction.waitForExistence(timeout: 5))
        XCTAssertFalse(window.checkBoxes["Automatically install updates"].exists)
        let preferences = XCTAttachment(screenshot: window.screenshot())
        preferences.name = "App Store update preferences"; preferences.lifetime = .keepAlways; add(preferences)
        clickWhenHittable(window.descendants(matching: .any)["Privacy"])
        let disclosure = window.staticTexts["privacy-usage-statistics"]
        for _ in 0..<5 {
            if disclosure.exists { break }
            window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue((disclosure.value as? String ?? disclosure.label).contains("does not collect or send usage statistics"))
    }

    #endif

    func testToolsPanelOpensReferenceEditorAndPersistsAnEdit() throws {
        _ = try seedPhoto()
        app.launch()
        app.activate()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let tools = window.buttons["photo-tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
        tools.click()
        let reference = app.buttons["Reference Tools…"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertTrue(reference.isEnabled)
        let guide = XCTAttachment(screenshot: window.screenshot())
        guide.name = "Photo tools discovery"; guide.lifetime = .keepAlways; add(guide)
        reference.click()
        let grayscale = app.checkBoxes["Grayscale"]
        XCTAssertTrue(grayscale.waitForExistence(timeout: 5))
        grayscale.click()
        let editor = XCTAttachment(screenshot: window.screenshot())
        editor.name = "Reference tools editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["Apply"].click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let self,
                  let data = try? Data(contentsOf: self.storageDirectory.appendingPathComponent("photos.json")),
                  let photos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let reference = photos.first?["reference"] as? [String: Any] else { return false }
            return reference["grayscale"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Copy Appearance"].exists, "Applying closes the editor and returns to Tools")
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

    /// Seeds every row-driven feature directly into the isolated test store. No Photos library,
    /// Finder folder, or media picker is involved, and the fixture intentionally includes one
    /// hidden video whose poster is present while its movie is absent so the UI exercises the
    /// safe missing-media status path without requiring a real AVAsset.
    private func seedFeatureFixture() throws -> FeatureFixture {
        let photoID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let spaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let secondSlideshowID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let liveFolderID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let videoID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let filenames = [
            "ui-test-photo.png",
            "ui-test-space-a.png",
            "ui-test-space-b.png",
            "ui-test-collage-a.png",
            "ui-test-collage-b.png",
            "ui-test-collage-c.png",
            "ui-test-live.png",
            "ui-test-video-poster.png"
        ]
        for filename in filenames {
            try imageData.write(to: storageDirectory.appendingPathComponent(filename), options: .atomic)
        }

        func baseItem(
            id: UUID,
            filename: String,
            frame: String,
            width: Int,
            visible: Bool = true,
            name: String
        ) -> [String: Any] {
            [
                "id": id.uuidString,
                "filename": filename,
                "frameString": frame,
                "widgetWidth": width,
                "isLocked": false,
                "isVisible": visible,
                "customName": name,
                "stackOrder": id == photoID ? 0 : (id == spaceID ? 1 : (id == secondSlideshowID ? 2 : 3))
            ]
        }

        var photo = baseItem(
            id: photoID,
            filename: "ui-test-photo.png",
            frame: "{{100, 100}, {300, 200}}",
            width: 300,
            name: "UI Test Photo"
        )
        photo["clickAction"] = "copyPath"

        var space = baseItem(
            id: spaceID,
            filename: "",
            frame: "{{450, 100}, {320, 220}}",
            width: 320,
            name: "UI Test Space"
        )
        space["spaceImageFilenames"] = ["ui-test-space-a.png", "ui-test-space-b.png"]
        space["folderSizeMode"] = "fixed"
        space["rotationInterval"] = "click"
        space["folderImageIndex"] = 0
        space["playbackOrder"] = "newestFirst"
        space["playbackSeed"] = 42
        space["playbackStep"] = 0
        space["playbackHistory"] = []
        space["clickAction"] = "advance"
        space["focalPoint"] = ["x": 0.2, "y": 0.8]

        var collage = baseItem(
            id: secondSlideshowID,
            filename: "",
            frame: "{{100, 360}, {420, 310}}",
            width: 420,
            name: "UI Test Second Slideshow"
        )
        collage["spaceImageFilenames"] = [
            "ui-test-collage-a.png",
            "ui-test-collage-b.png",
            "ui-test-collage-c.png"
        ]
        collage["rotationInterval"] = "30s"
        collage["clickAction"] = "quickLook"
        collage["focalPoint"] = ["x": 0.65, "y": 0.35]

        var liveFolder = baseItem(
            id: liveFolderID,
            filename: "",
            frame: "{{560, 360}, {320, 220}}",
            width: 320,
            name: "UI Test Live Folder"
        )
        liveFolder["spaceImageFilenames"] = ["ui-test-live.png"]
        liveFolder["folderSizeMode"] = "dynamic"
        liveFolder["rotationInterval"] = "click"
        liveFolder["folderImageIndex"] = 0
        liveFolder["liveFolderSource"] = [
            "sourcePath": "",
            "displayName": "UI Fixture Folder",
            "status": "needsRelink"
        ]
        liveFolder["liveFolderEntries"] = [[
            "sourceIdentifier": "ui-fixture-source",
            "sourceName": "ui-test-live.png",
            "managedFilename": "ui-test-live.png"
        ]]
        liveFolder["clickAction"] = "revealStoredMedia"

        var video = baseItem(
            id: videoID,
            filename: "ui-test-video.mov",
            frame: "{{900, 100}, {300, 200}}",
            width: 300,
            visible: false,
            name: "UI Test Video"
        )
        video["media"] = [
            "kind": "video",
            "posterFilename": "ui-test-video-poster.png",
            "isMuted": true
        ]
        video["clickAction"] = "quickLook"

        let data = try JSONSerialization.data(
            withJSONObject: [photo, space, collage, liveFolder, video],
            options: [.sortedKeys]
        )
        try data.write(to: storageDirectory.appendingPathComponent("photos.json"), options: .atomic)
        return FeatureFixture(
            photoID: photoID,
            spaceID: spaceID,
            secondSlideshowID: secondSlideshowID,
            liveFolderID: liveFolderID,
            videoID: videoID
        )
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
        // AppKit reports offscreen SwiftUI rows as hittable. Scroll the actual viewport
        // first so a row's unclipped coordinates cannot send the click to the footer.
        let list = app.scrollViews["photos-scroll-view"]
        if list.exists, (element.identifier.hasPrefix("photo-row-") || element.identifier == "photo-more-actions" || element.identifier.hasPrefix("photo-more-options-")) {
            for _ in 0..<12 {
                let viewport = list.frame.insetBy(dx: 0, dy: 12)
                let target = element.frame
                if target.minY >= viewport.minY && target.maxY <= viewport.maxY { break }
                list.scroll(byDeltaX: 0, deltaY: target.maxY > viewport.maxY ? -180 : 180)
            }
        }
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

        if !expandedValue.evaluate(with: row) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
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
        XCTAssertTrue(window.staticTexts["Everyday behavior"].waitForExistence(timeout: 2))

        let privacy = window.descendants(matching: .any)["Privacy"]
        clickWhenHittable(privacy)
        XCTAssertTrue(window.staticTexts["Screen sharing & recording"].waitForExistence(timeout: 2))

        clickWhenHittable(window.descendants(matching: .tab)["Photos"])
        XCTAssertTrue(window.buttons["Add Photos or Videos…"].waitForExistence(timeout: 2))
        let choices = ["Add Photos or Videos…", "Create Slideshow…", "Create Collage"].map { window.buttons[$0] }
        for choice in choices { XCTAssertTrue(choice.isHittable) }
        for pair in zip(choices, choices.dropFirst()) {
            XCTAssertGreaterThan(pair.1.frame.minY, pair.0.frame.maxY)
        }
        let emptyState = XCTAttachment(screenshot: app.screenshot())
        emptyState.name = "Vertical empty state actions"
        emptyState.lifetime = .keepAlways
        add(emptyState)
        XCTAssertEqual(app.windows.count, 1)
    }

    func testSavedSetupCanBeNamedAndReturnedTo() throws {
        let photoID = try seedPhoto()
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        clickWhenHittable(window.buttons["Setups"])
        let name = app.textFields["Setup name"]
        clickWhenHittable(name)
        name.typeText("Work")
        let enteredName = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Work"), object: name)
        XCTAssertEqual(XCTWaiter().wait(for: [enteredName], timeout: 3), .completed,
                       "The name field must receive the complete text before saving; another app may have taken keyboard focus.")
        clickWhenHittable(app.buttons["Save Current"])
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 3))
        let data = try Data(contentsOf: storageDirectory.appendingPathComponent("setups.json"))
        let library = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let setups = try XCTUnwrap(library["setups"] as? [[String: Any]])
        XCTAssertEqual(setups.count, 1)
        XCTAssertEqual(setups.first?["name"] as? String, "Work")
        let photos = try XCTUnwrap(setups.first?["photos"] as? [[String: Any]])
        XCTAssertEqual(photos.first?["id"] as? String, photoID.uuidString)
        clickWhenHittable(app.buttons["Use Setup"])
        XCTAssertTrue(app.buttons["Restore Previous Desktop"].waitForExistence(timeout: 3))
        clickWhenHittable(app.buttons["Done"])
        XCTAssertTrue(window.descendants(matching: .any)["photo-row-toggle-\(photoID.uuidString)"].waitForExistence(timeout: 3))
    }

    func testExamplesAreOptionalAndCanBeCancelled() {
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        XCTAssertTrue(window.buttons["Add Photos or Videos…"].exists)
        clickWhenHittable(window.descendants(matching: .any)["try-starter-examples"])
        clickWhenHittable(app.buttons["Cancel"])
        XCTAssertTrue(window.buttons["Add Photos or Videos…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["starter-example-minimal"].exists)
    }

    func testEmptyLibraryCanAddAndRemoveStarterExample() {
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()

        clickWhenHittable(window.descendants(matching: .any)["try-starter-examples"])
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Starter picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        let example = app.descendants(matching: .any)["starter-example-minimal"]
        clickWhenHittable(example)
        clickWhenHittable(app.descendants(matching: .any)["add-starter-example"])
        XCTAssertTrue(window.descendants(matching: .any)["starter-next-step"].waitForExistence(timeout: 5))

        let row = window.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "photo-row-toggle-")
        ).firstMatch
        XCTAssertTrue(waitForHittable(row))
        clickWhenHittable(row)

        let moreActions = window.descendants(matching: .any)["photo-more-actions"]
        clickWhenHittable(moreActions)
        let remove = moreActions.descendants(matching: .menuItem)["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        // Removal uses the shared native modal alert, outside the Settings window.
        let confirmation = app.dialogs.buttons["Remove"]
        clickWhenHittable(confirmation)
        XCTAssertTrue(window.descendants(matching: .any)["try-starter-examples"].waitForExistence(timeout: 5))
    }

    func testContactAndSupportAndNewCreationMenuAreReachable() {
        app.launch(); app.activate()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        clickWhenHittable(window.descendants(matching: .any)["Privacy"])
        XCTAssertTrue(window.links["Contact & Support"].waitForExistence(timeout: 3))
        XCTAssertTrue(window.links["Security & Privacy"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Restored Contact & Support and telemetry disclosure"
        screenshot.lifetime = .keepAlways; add(screenshot)
        clickWhenHittable(window.descendants(matching: .tab)["Photos"])
        clickWhenHittable(window.descendants(matching: .any)["Add photo"])
        XCTAssertTrue(app.menuItems["Create Collage"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Try an Example…"].exists)
        XCTAssertFalse(app.menuItems["Combine Photos…"].exists)
        XCTAssertFalse(app.menuItems["New Composition"].exists)
        XCTAssertFalse(app.menuItems["Bubble"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }


    func testSlideshowEditorPersistsReorderAndRemoval() throws {
        let fixture = try seedFeatureFixture()
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        let row = window.descendants(matching: .any)["photo-row-toggle-\(fixture.spaceID.uuidString)"]
        expand(row, id: fixture.spaceID, in: window)
        let settings = window.descendants(matching: .any)["photo-expanded-settings-\(fixture.spaceID.uuidString)"]
        clickWhenHittable(settings.buttons["Edit Slideshow…"])
        let editor = app.descendants(matching: .any)["slideshow-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(editor.buttons["slideshow-editor-add-photos"].isEnabled)
        clickWhenHittable(editor.buttons["slideshow-move-down-0"])
        clickWhenHittable(editor.buttons["slideshow-remove-1"])
        XCTAssertFalse(editor.buttons["slideshow-remove-0"].isEnabled)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Slideshow editor"
        preview.lifetime = .keepAlways
        add(preview)
        clickWhenHittable(editor.buttons["slideshow-editor-done"])
        let data = try Data(contentsOf: storageDirectory.appendingPathComponent("photos.json"))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let slideshow = try XCTUnwrap(items.first { $0["id"] as? String == fixture.spaceID.uuidString })
        XCTAssertEqual(slideshow["spaceImageFilenames"] as? [String], ["ui-test-space-b.png"])
    }

    func testSelectedRemovalRemembersSettingsChoice() throws {
        let fixture = try seedFeatureFixture()
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        for id in [fixture.photoID, fixture.spaceID] {
            clickWhenHittable(window.descendants(matching: .any)["photo-row-selection-\(id.uuidString)"])
        }
        clickWhenHittable(window.descendants(matching: .any)["photo-selection-actions"])
        app.menuItems["Remove Selected…"].click()
        let suppress = app.checkBoxes["Don’t ask again in Settings"]
        XCTAssertTrue(suppress.waitForExistence(timeout: 3))
        suppress.click()
        app.descendants(matching: .dialog).buttons["Remove"].click()
        let firstRow = window.descendants(matching: .any)["photo-row-toggle-\(fixture.photoID.uuidString)"]
        XCTAssertTrue(firstRow.waitForNonExistence(timeout: 3))
        clickWhenHittable(window.descendants(matching: .any)["photo-row-selection-\(fixture.secondSlideshowID.uuidString)"])
        clickWhenHittable(window.descendants(matching: .any)["photo-selection-actions"])
        app.menuItems["Remove Selected…"].click()
        let collageRow = window.descendants(matching: .any)["photo-row-toggle-\(fixture.secondSlideshowID.uuidString)"]
        XCTAssertTrue(collageRow.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.checkBoxes["Don’t ask again in Settings"].exists)
        let data = try Data(contentsOf: storageDirectory.appendingPathComponent("photos.json"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.count, 2)
    }

    func testSelectionDoesNotMoveListAndRowOnlyExpands() throws {
        let id = try seedPhoto()
        app.launch()
        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()
        let row = window.descendants(matching: .any)["photo-row-toggle-\(id.uuidString)"]
        let list = window.scrollViews["photos-scroll-view"]
        let top = list.frame.minY
        expand(row, id: id, in: window)
        XCTAssertFalse(window.descendants(matching: .any)["photo-selection-toolbar"].exists)
        XCTAssertFalse(window.sliders["Opacity"].exists)
        let checkbox = window.descendants(matching: .any)["photo-row-selection-\(id.uuidString)"]
        clickWhenHittable(checkbox)
        XCTAssertTrue(window.descendants(matching: .any)["photo-selection-toolbar"].waitForExistence(timeout: 2))
        XCTAssertEqual(list.frame.minY, top, accuracy: 1)
        XCTAssertTrue((row.value as? String ?? "").contains("Expanded"))
        clickWhenHittable(row)
        XCTAssertTrue(window.descendants(matching: .any)["photo-selection-toolbar"].exists)
        clickWhenHittable(checkbox)
        XCTAssertFalse(window.descendants(matching: .any)["photo-selection-toolbar"].exists)
        XCTAssertEqual(list.frame.minY, top, accuracy: 1)
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
        clickWhenHittable(inspector.descendants(matching: .any)["Adjust"])
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
        let resetConfirmation = app.buttons["Reset Appearance"].firstMatch
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

        let removeConfirmation = app.buttons["Remove"]
        XCTAssertTrue(removeConfirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["Don’t ask again in Settings"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testFeatureSettingsAreReachableFromAnIsolatedFixture() throws {
        let fixture = try seedFeatureFixture()
        let preflightArchive = storageDirectory.appendingPathComponent("ui-test-preflight.arras")
        app.launchEnvironment["ARRAS_UI_TEST_PREFLIGHT_ARCHIVE"] = preflightArchive.path
        app.launch()

        // App startup generated this archive from the first fixture widget and routed it
        // through the real preflight UI. Cancel leaves the fixture and durable layout intact.
        let preflightTitle = app.descendants(matching: .any)["Choose Widgets to Import"]
        XCTAssertTrue(preflightTitle.waitForExistence(timeout: 5))
        let preflightCancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(preflightCancel.waitForExistence(timeout: 2))
        preflightCancel.click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: preflightArchive.path))

        let window = app.windows["Arras"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.activate()

        XCTAssertFalse(window.descendants(matching: .any)["photo-selection-toolbar"].exists)
        let firstSelection = window.descendants(matching: .any)[
            "photo-row-selection-\(fixture.photoID.uuidString)"
        ]
        clickWhenHittable(firstSelection)

        let toolbar = window.descendants(matching: .any)["photo-selection-toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 2))
        XCTAssertTrue(toolbar.buttons["Clear photo selection"].exists)
        let selectionActions = toolbar.descendants(matching: .any)["photo-selection-actions"]
        clickWhenHittable(selectionActions)
        XCTAssertTrue(app.menuItems["Align"].exists)
        XCTAssertTrue(app.menuItems["Distribute"].exists)
        XCTAssertTrue(app.menuItems["Duplicate"].exists)
        clickWhenHittable(app.menuItems["Select all photos"])
        XCTAssertTrue((selectionActions.value as? String ?? "").contains("5 selected"))

        let spaceRow = window.descendants(matching: .any)["photo-row-toggle-\(fixture.spaceID.uuidString)"]
        expand(spaceRow, id: fixture.spaceID, in: window)
        let spaceSettings = window.descendants(matching: .any)["photo-expanded-settings-\(fixture.spaceID.uuidString)"]
        clickWhenHittable(spaceSettings.buttons["More options"])
        let playbackOrder = spaceSettings.descendants(matching: .any)["space-playback-order"]
        XCTAssertTrue(playbackOrder.waitForExistence(timeout: 2))
        XCTAssertTrue((playbackOrder.value as? String ?? "").contains("Newest"))
        let clickAction = spaceSettings.descendants(matching: .any)["photo-click-action"]
        XCTAssertTrue(clickAction.exists)
        XCTAssertTrue((clickAction.value as? String ?? "").contains("Advance"))

        // Legacy focal-point data stays readable, but numeric crop-focus controls
        // are no longer part of the appearance workflow.
        let frameButton = spaceSettings.buttons.firstMatch
        clickWhenHittable(frameButton)
        let inspector = app.descendants(matching: .any)["frame-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 2))
        XCTAssertFalse(inspector.descendants(matching: .any)["Crop focus horizontal position"].exists)
        XCTAssertFalse(inspector.descendants(matching: .any)["Crop focus vertical position"].exists)
        clickWhenHittable(inspector.buttons["Done"])

        let liveRow = window.descendants(matching: .any)["photo-row-toggle-\(fixture.liveFolderID.uuidString)"]
        expand(liveRow, id: fixture.liveFolderID, in: window)
        let liveSettings = window.descendants(matching: .any)["photo-expanded-settings-\(fixture.liveFolderID.uuidString)"]
        clickWhenHittable(liveSettings.buttons["More options"])
        let liveStatus = liveSettings.descendants(matching: .any)["live-folder-status-\(fixture.liveFolderID.uuidString)"]
        XCTAssertTrue(liveStatus.waitForExistence(timeout: 2))
        XCTAssertTrue(liveSettings.staticTexts["Live folder: UI Fixture Folder"].exists)
        XCTAssertTrue(liveSettings.staticTexts["Needs relink"].exists)
        XCTAssertTrue(liveSettings.descendants(matching: .any)["Relink live folder"].exists)

        let videoRow = window.descendants(matching: .any)["photo-row-toggle-\(fixture.videoID.uuidString)"]
        expand(videoRow, id: fixture.videoID, in: window)
        let videoSettings = window.descendants(matching: .any)["photo-expanded-settings-\(fixture.videoID.uuidString)"]
        clickWhenHittable(videoSettings.buttons["More options"])
        let videoPlayback = videoSettings.descendants(matching: .any)["Video playback"]
        XCTAssertTrue(videoPlayback.waitForExistence(timeout: 2))
        XCTAssertTrue((videoPlayback.value as? String ?? "").contains("muted"))

        // Export is reachable from the per-widget menu; do not activate it because that would
        // intentionally open a Save Panel, which this fixture-based test avoids.
        let moreActions = window.descendants(matching: .any)["photo-more-actions"].firstMatch
        clickWhenHittable(moreActions)
        XCTAssertTrue(app.menuItems["Export .arras…"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }
}
