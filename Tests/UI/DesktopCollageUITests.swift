import AppKit
import XCTest

final class DesktopCollageUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storage: URL!
    private let portrait = UUID(uuidString: "C1111111-1111-1111-1111-111111111111")!
    private let square = UUID(uuidString: "C2222222-2222-2222-2222-222222222222")!
    private let collage = UUID(uuidString: "C3333333-3333-3333-3333-333333333333")!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storage = uiTestStorage(prefix: "ArrasNativeDesktop")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["ARRAS_UI_TEST_STORAGE_DIR"] = storage.path
        app.launchEnvironment["ARRAS_COLLAGE_POINTER_TRACE"] = "1"
    }
    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storage)
    }

    private func seed(floating: Bool = false) throws {
        var items: [[String: Any]] = []
        for (id, frame, color) in [(portrait, CGRect(x: 60, y: 300, width: 180, height: 240), NSColor.systemTeal),
                                   (square, CGRect(x: 60, y: 100, width: 120, height: 120), NSColor.systemOrange)] {
            let filename = id.uuidString + ".tiff"
            let image = NSImage(size: frame.size, flipped: false) { r in color.setFill(); r.fill(); return true }
            try XCTUnwrap(image.tiffRepresentation).write(to: storage.appendingPathComponent(filename))
            items.append(["id": id.uuidString, "filename": filename, "frameString": NSStringFromRect(frame), "widgetWidth": frame.width,
                          "isLocked": false, "isVisible": true, "depth": floating ? "floating" : "onDesktop", "shadowEnabled": false, "customName": id == portrait ? "Portrait" : "Square"])
        }
        items.append(["id": collage.uuidString, "filename": "", "frameString": "{{360,320},{160,160}}", "widgetWidth": 160,
                      "isLocked": false, "isVisible": true, "depth": floating ? "floating" : "onDesktop", "customName": "Collage",
                      "desktopCollage": ["skin": "glass", "gap": 20, "padding": 28, "cornerRadius": 24, "tintHex": "#F5EFE3", "caption": ""]])
        try JSONSerialization.data(withJSONObject: items).write(to: storage.appendingPathComponent("photos.json"))
    }
    private func items() throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.appendingPathComponent("photos.json"))) as? [[String: Any]])
    }
    private func item(_ id: UUID) throws -> [String: Any] { try XCTUnwrap(try items().first { $0["id"] as? String == id.uuidString }) }
    private func frame(_ id: UUID) throws -> CGRect { NSRectFromString(try XCTUnwrap(try item(id)["frameString"] as? String)) }
    private func waitForParent(_ id: UUID, parent: UUID?) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let data = try? self?.item(id) else { return false }
            return data["collageParentID"] as? String == parent?.uuidString
        }, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: 5)
        if result != .completed {
            evidence("Failed native membership")
            let trace = XCTAttachment(string: (try? String(contentsOf: storage.appendingPathComponent("pointer-trace.txt"), encoding: .utf8)) ?? "No mouse events reached the photo view")
            trace.name = "Native pointer trace"; trace.lifetime = .keepAlways; add(trace)
        }
        XCTAssertEqual(result, .completed)
    }
    private func evidence(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let snapshot = XCTAttachment(string: (try? String(contentsOf: storage.appendingPathComponent("photos.json"), encoding: .utf8)) ?? "Missing layout")
        snapshot.name = name + " saved layout"; snapshot.lifetime = .keepAlways; add(snapshot)
    }

    func testFloatingNativeDragAttachEqualGapGroupMoveAndDetachWithSettingsOpen() throws {
        try seed(floating: true)
        app.launch(); app.activate()
        let settings = app.windows["Arras"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        // Floating widgets must accept mouse input above Settings. Use XCTest's
        // mouse click-and-drag API; a press gesture did not deliver mouse events
        // to these nonactivating panels on the native CI desktop.
        XCTAssertTrue(settings.isHittable)
        let first = app.descendants(matching: .any)["desktop-photo-" + portrait.uuidString]
        let second = app.descendants(matching: .any)["desktop-photo-" + square.uuidString]
        let container = app.descendants(matching: .any)["desktop-collage-" + collage.uuidString]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        let firstStart = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        firstStart.click(forDuration: 0.15, thenDragTo: container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        waitForParent(portrait, parent: collage)
        let firstFrame = try frame(portrait)
        XCTAssertEqual(firstFrame.size, CGSize(width: 180, height: 240))
        let squareStart = second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let squareTarget = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 170, dy: -60))
        squareStart.click(forDuration: 0.15, thenDragTo: squareTarget)
        waitForParent(square, parent: collage)
        let squareFrame = try frame(square)
        XCTAssertEqual(squareFrame.minX - firstFrame.maxX, 20, accuracy: 1)
        XCTAssertEqual(squareFrame.maxY, firstFrame.maxY, accuracy: 1)
        XCTAssertEqual(squareFrame.size, CGSize(width: 120, height: 120))
        evidence("Glass collage, mixed photos and equal gap")
        // The accessibility surface includes the transparent shadow canvas.
        // Pick the middle of this fixture's 28-point visible left padding.
        let groupFrame = try frame(collage)
        let border = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: -groupFrame.width / 2 + 14, dy: 0))
        border.click(forDuration: 0.15, thenDragTo: border.withOffset(CGVector(dx: 32, dy: -24)))
        XCTAssertEqual(try frame(portrait).minX, firstFrame.minX + 32, accuracy: 1)
        XCTAssertEqual(try frame(portrait).minY, firstFrame.minY + 24, accuracy: 1)
        XCTAssertEqual(try frame(square).minX, squareFrame.minX + 32, accuracy: 1)
        let leave = second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        leave.click(forDuration: 0.15, thenDragTo: leave.withOffset(CGVector(dx: 260, dy: 150)))
        waitForParent(square, parent: nil)
        XCTAssertEqual(try frame(square).size, CGSize(width: 120, height: 120))
        evidence("Photo detached at native drop position")
    }

    func testCaptionAndPolaroidApplyAndCancelAreDurable() throws {
        try seed()
        app.launch(); app.activate()
        let edit = app.buttons["edit-collage-" + collage.uuidString]
        XCTAssertTrue(edit.waitForExistence(timeout: 8)); edit.click()
        let field = app.textFields["collage-caption"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText("Summer memories")
        let advanced = app.descendants(matching: .any)["collage-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 3)); advanced.click()
        for identifier in ["collage-group-depth", "collage-group-space", "apply-collage-settings", "cancel-collage-settings"] {
            XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 3), identifier)
        }
        app.buttons["Cancel"].click()
        let discard = app.windows["Edit Collage"].sheets.buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.click()
        XCTAssertEqual((try item(collage)["desktopCollage"] as? [String: Any])?["caption"] as? String, "")
        edit.click()
        let material = app.buttons["collage-preset-whitePolaroid"]
        XCTAssertTrue(material.waitForExistence(timeout: 5)); material.click()
        app.textFields["collage-caption"].click(); app.textFields["collage-caption"].typeText("Summer memories")
        evidence("Polaroid collage settings preview")
        app.buttons["apply-collage-settings"].click()
        XCTAssertEqual((try item(collage)["desktopCollage"] as? [String: Any])?["caption"] as? String, "Summer memories")
        XCTAssertEqual((try item(collage)["desktopCollage"] as? [String: Any])?["skin"] as? String, "polaroid")
        app.terminate(); app.launch()
        XCTAssertEqual((try item(collage)["desktopCollage"] as? [String: Any])?["caption"] as? String, "Summer memories")
    }

    func testEveryCollageLookCanBeAppliedAndReopened() throws {
        try seed()
        app.launch(); app.activate()
        let edit = app.buttons["edit-collage-" + collage.uuidString]
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        for (preset, skin, tint) in [("whitePolaroid", "polaroid", "#FFFFFF"),
                                     ("gallery", "solid", "#F2F3F5"),
                                     ("ink", "solid", "#202226"),
                                     ("transparent", "transparent", "#F5EFE3"),
                                     ("systemGlass", "glass", "#F5EFE3")] {
            edit.click()
            let look = app.buttons["collage-preset-" + preset]
            XCTAssertTrue(look.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "collage-preset-" + preset).count, 1)
            look.click()
            XCTAssertEqual(look.value as? String, "Selected")
            app.buttons["apply-collage-settings"].click()
            let saved = try XCTUnwrap(try item(collage)["desktopCollage"] as? [String: Any])
            XCTAssertEqual(saved["skin"] as? String, skin)
            XCTAssertEqual(saved["tintHex"] as? String, tint)
            edit.click()
            XCTAssertTrue(look.waitForExistence(timeout: 5))
            XCTAssertEqual(look.value as? String, "Selected")
            app.buttons["cancel-collage-settings"].click()
        }
    }

    func testSettingsCreateEmptyCollage() throws {
        app.launch(); app.activate()
        let settings = app.windows["Arras"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.descendants(matching: .any)["Add photo"].click()
        settings.menuItems["create-desktop-collage"].click()
        let created = try XCTUnwrap(try items().first { $0["desktopCollage"] != nil })
        let size = NSRectFromString(created["frameString"] as! String).size
        XCTAssertGreaterThanOrEqual(size.width, 160)
        XCTAssertGreaterThanOrEqual(size.height, 160)
        XCTAssertTrue(settings.staticTexts["Drag a desktop widget onto this collage to add it."].waitForExistence(timeout: 5))
    }
}
