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
    func testUpdateEndpointsAvoidCheckRedirectAndUniquelyTrackDownloads() throws {
        XCTAssertEqual(Updater.appcastURL.host, "raw.githubusercontent.com")

        let source = try XCTUnwrap(URL(string: "https://github.com/example/app/releases/download/v2.4.5/App.zip?source=arras-updater&version=2.4.5"))
        let requestID = UUID(uuidString: "A4A8BCDF-193B-4A13-8416-E92C66391055")!
        let tracked = Updater.trackedDownloadURL(source, requestID: requestID)
        let components = try XCTUnwrap(URLComponents(url: tracked, resolvingAgainstBaseURL: false))

        XCTAssertEqual(tracked.pathExtension, "zip")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "source" })?.value, "arras-updater")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "version" })?.value, "2.4.5")
        XCTAssertEqual(components.queryItems?.filter { $0.name == "request" }.map(\.value), [requestID.uuidString.lowercased()])
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
