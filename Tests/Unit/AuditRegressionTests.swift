import AppKit
import XCTest
@testable import Arras

final class AuditRegressionTests: XCTestCase {
    @MainActor
    func testReconnectBeforeLaunchRestoresHiddenWidgetWithoutShowingUserHiddenItems() throws {
        try withTestLibrary { manager in
            // Display restoration must not depend on other applications running
            // on the developer's Mac or their saved Privacy preferences.
            XCTAssertFalse(manager.autoHideForConferencingApps)
            XCTAssertFalse(manager.hideWhenFullscreenActive)
            let display = DisplayManager.identifier(for: try XCTUnwrap(NSScreen.main))
            var item = PhotoItem(filename: ""); item.desktopCollage = DesktopCollageSettings()
            item.frameString = "{{100,100},{160,160}}"
            item.displayIdentifier = display; item.isHiddenForDisplay = true
            item.savedDisplayFrames[display] = "{{200,200},{160,160}}"
            var hidden = PhotoItem(filename: ""); hidden.desktopCollage = DesktopCollageSettings()
            hidden.isVisible = false; hidden.isHiddenForDisplay = true; hidden.displayIdentifier = display
            manager.photos = [item, hidden]; XCTAssertTrue(manager.persist())
            manager.loadSaved()
            XCTAssertFalse(manager.photos[0].isHiddenForDisplay)
            XCTAssertNotNil(manager.windows[item.id])
            XCTAssertEqual(manager.photos[0].frameString, item.savedDisplayFrames[display])
            XCTAssertFalse(manager.photos[1].isVisible)
            XCTAssertNil(manager.windows[hidden.id])
            manager.reconcileDisplayPresence(connected: [])
            XCTAssertTrue(manager.photos.allSatisfy(\.isHiddenForDisplay))
        }
    }

    @MainActor
    func testGeometryOnlyScreenChangeRecoversOffscreenCollageAsAGroup() throws {
        try withTestLibrary { manager in
            _ = try XCTUnwrap(NSScreen.main)
            var group = PhotoItem(filename: ""); group.desktopCollage = DesktopCollageSettings()
            group.frameString = "{{99999,99999},{300,300}}"
            var child = PhotoItem(filename: "missing.png"); child.collageParentID = group.id
            child.frameString = "{{100039,100049},{100,100}}"; child.isVisible = false
            manager.photos = [group, child]; manager.createCollageWindow(group)
            manager.handleScreenChanges(connected: [], disconnected: [])
            let parentFrame = NSRectFromString(manager.photos[0].frameString)
            let childFrame = NSRectFromString(manager.photos[1].frameString)
            XCTAssertTrue(NSScreen.screens.contains { $0.frame.intersects(parentFrame) })
            XCTAssertEqual(childFrame.minX - parentFrame.minX, 40, accuracy: 0.01)
            XCTAssertEqual(childFrame.minY - parentFrame.minY, 50, accuracy: 0.01)
        }
    }

    @MainActor
    func testGroupedSlideshowActionsFollowParentDepthAndVisibility() throws {
        try withTestLibrary { manager in
            var group = PhotoItem(filename: ""); group.desktopCollage = DesktopCollageSettings()
            var child = PhotoItem(filename: "a.png"); child.depth = .behindIcons; child.collageParentID = group.id
            child.spaceImageFilenames = ["a.png", "b.png"]
            let sample = try StarterArtwork.pngData(for: StarterArtwork.image(for: .minimal, index: 0, phase: 0))
            for name in child.spaceImageFilenames { try sample.write(to: manager.storageDir.appendingPathComponent(name)) }
            manager.photos = [group, child]
            manager.spaceImages[child.id] = child.spaceImageFilenames.map { manager.storageDir.appendingPathComponent($0) }
            manager.performClickAction(child.id)
            XCTAssertEqual(manager.photos[1].folderImageIndex, 1)
            XCTAssertEqual(manager.photos[1].depth, .behindIcons)
            manager.photos[0].depth = .behindIcons
            manager.photos[1].depth = .floating
            manager.performClickAction(child.id)
            XCTAssertEqual(manager.photos[1].folderImageIndex, 1)
            manager.photos[0].depth = .floating; manager.photos[0].isVisible = false
            manager.performClickAction(child.id)
            XCTAssertEqual(manager.photos[1].folderImageIndex, 1)
        }
    }
}
