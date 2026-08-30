import AppKit
import XCTest
@testable import Arras

final class LayoutAndUpdaterTests: XCTestCase {
    func testRelativeFrameRestoresProportionalPlacement() {
        let sourceScreen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let sourceFrame = NSRect(x: 600, y: 300, width: 200, height: 100)
        let relative = RelativeFrame(frame: sourceFrame, in: sourceScreen)

        let restored = relative.absoluteFrame(
            in: NSRect(x: 0, y: 0, width: 2000, height: 1600),
            aspectRatio: 2
        )

        XCTAssertEqual(restored.midX, 1400, accuracy: 0.01)
        XCTAssertEqual(restored.midY, 700, accuracy: 0.01)
        XCTAssertEqual(restored.width, 400, accuracy: 0.01)
        XCTAssertEqual(restored.height, 200, accuracy: 0.01)
    }

    @MainActor
    func testVersionComparisonIsNumericAndHandlesMissingComponents() {
        XCTAssertTrue(Updater.compare("2.4.10", isNewerThan: "2.4.9"))
        XCTAssertTrue(Updater.compare("3", isNewerThan: "2.99.99"))
        XCTAssertFalse(Updater.compare("2.4.0", isNewerThan: "2.4"))
        XCTAssertFalse(Updater.compare("2.4.3", isNewerThan: "2.4.4"))
    }

    @MainActor
    func testSettingsWindowIsConfiguredForTheActiveSpace() {
        let window = NSWindow()
        AppDelegate.configureSettingsWindow(window)

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }
}
