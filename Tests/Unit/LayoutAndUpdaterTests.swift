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
    func testVersionComparisonUsesSemVerPrecedence() {
        XCTAssertTrue(Updater.compare("2.4.10", isNewerThan: "2.4.9"))
        XCTAssertTrue(Updater.compare("3.0.0", isNewerThan: "2.99.99"))
        XCTAssertFalse(Updater.compare("2.4.3", isNewerThan: "2.4.4"))
        XCTAssertTrue(Updater.compare("2.4.0", isNewerThan: "2.4.0-rc.1"))
        XCTAssertTrue(Updater.compare("2.4.0-rc.10", isNewerThan: "2.4.0-rc.2"))
        XCTAssertTrue(Updater.compare("2.4.0-rc.2", isNewerThan: "2.4.0-rc.1"))
        XCTAssertTrue(Updater.compare("2.4.0-rc.1", isNewerThan: "2.4.0-rc"))
        XCTAssertFalse(Updater.compare("2.4.0+build.2", isNewerThan: "2.4.0+build.1"))
        XCTAssertFalse(Updater.compare("2.4", isNewerThan: "2.3.0"))
        XCTAssertFalse(Updater.isValidVersion("2.4"))
        XCTAssertFalse(Updater.isValidVersion("2.4.0-rc..1"))
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
    func testAutomaticUpdatesDefaultOnAndUseDailyCadence() {
        let defaults = UserDefaults.standard
        let updater = Updater.shared
        let previousAutomatic = defaults.object(forKey: "automaticUpdatesEnabled")
        let previousFrequency = defaults.object(forKey: "updateCheckFrequency")
        defer {
            updater.checkFrequency = previousFrequency
                .flatMap { $0 as? TimeInterval }
                .flatMap(Updater.CheckFrequency.init(rawValue:)) ?? .daily
            updater.automaticUpdatesEnabled = previousAutomatic as? Bool ?? true
            if let previousAutomatic {
                defaults.set(previousAutomatic, forKey: "automaticUpdatesEnabled")
            } else {
                defaults.removeObject(forKey: "automaticUpdatesEnabled")
            }
            if let previousFrequency {
                defaults.set(previousFrequency, forKey: "updateCheckFrequency")
            } else {
                defaults.removeObject(forKey: "updateCheckFrequency")
            }
        }

        defaults.removeObject(forKey: "automaticUpdatesEnabled")
        defaults.removeObject(forKey: "updateCheckFrequency")

        XCTAssertTrue(updater.automaticUpdatesEnabled)
        XCTAssertEqual(updater.checkFrequency, .daily)
        XCTAssertEqual(updater.activeCheckFrequency, .daily)

        updater.checkFrequency = .weekly
        XCTAssertEqual(updater.activeCheckFrequency, .daily)
        updater.automaticUpdatesEnabled = false
        XCTAssertEqual(updater.activeCheckFrequency, .weekly)
    }

    @MainActor
    func testUpdateNotificationBodyIncludesVersionAndUsefulReleaseStatement() {
        XCTAssertEqual(
            Updater.updateNotificationBody(version: "2.5.0", releaseNotes: "Improves Spaces and fixes import reliability."),
            "Version 2.5.0 is available. Improves Spaces and fixes import reliability."
        )
        XCTAssertTrue(
            Updater.updateNotificationBody(version: "2.5.0", releaseNotes: nil)
                .contains("latest fixes and improvements")
        )
    }

    @MainActor
    func testAvailableUpdateStatusIncludesReleaseNotesForAssistiveTechnologies() {
        let status = UpdateStatusPhrasing.availableUpdate(
            version: "2.5.0",
            notes: "Improves Spaces and fixes import reliability.",
            currentVersion: "2.4.5"
        )

        XCTAssertEqual(
            status,
            "Version 2.5.0 is available. You have 2.4.5. Improves Spaces and fixes import reliability."
        )
    }

    @MainActor
    func testMismatchedUpdateBreadcrumbSurfacesARealFailure() {
        let updater = Updater.shared
        updater.announceInstallResult(expectedVersion: "99.0.0")

        guard case .failed(let message) = updater.phase else {
            XCTFail("A breadcrumb for a version that did not launch must not report success")
            return
        }
        XCTAssertTrue(message.contains("99.0.0"))
        XCTAssertTrue(message.contains(Constants.version))
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
