import AppKit
import XCTest
@testable import Arras

final class SavedSetupTests: XCTestCase {
    @MainActor
    func testFailedSetupSaveOrSwitchPreservesActiveGesturesAndCorruptionSafeguard() throws {
        for operation in ["save-write", "switch-recovery-write", "switch-active-write", "switch-corrupt-store"] {
            for gesture in ["background", "photo-resize", "group-resize"] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let setupID = try manager.saveDesktopSetup(named: "Original")
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                    let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                    manager.selectedPhotoIDs = [parent.id]
                    manager.nudgeSelected(.right, modifiers: [.shift])
                    surface.transition?.currentProgress = 1
                    let ids = Set(manager.photos.map(\.id))
                    let committed = manager.arrangementSnapshot(ids: ids)
                    try beginGesture(gesture, manager: manager, parent: parent.id, child: child.id)
                    let preview = manager.arrangementSnapshot(ids: ids)
                    let windows = manager.windows
                    let generation = manager.desktopGeneration
                    let undoCount = manager.arrangementUndo.count
                    let storeURL = manager.storageDir.appendingPathComponent("photos.json")
                    let setupsURL = manager.storageDir.appendingPathComponent("setups.json")
                    let originalStore = try Data(contentsOf: storeURL)
                    let setups = try Data(contentsOf: setupsURL)
                    let oldPermissions = try FileManager.default.attributesOfItem(atPath: manager.storageDir.path)[.posixPermissions]
                    defer {
                        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: storeURL.path)
                        if let oldPermissions { try? FileManager.default.setAttributes([.posixPermissions: oldPermissions], ofItemAtPath: manager.storageDir.path) }
                    }
                    if operation == "switch-active-write" {
                        // Only the active file refuses replacement; recovery can still commit.
                        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: storeURL.path)
                    } else if operation == "switch-corrupt-store" {
                        try Data("damaged active store".utf8).write(to: storeURL)
                    } else {
                        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    }
                    let stored = try Data(contentsOf: storeURL)

                    if operation == "save-write" {
                        XCTAssertThrowsError(try manager.saveDesktopSetup(named: "Must not save"))
                    } else { XCTAssertThrowsError(try manager.activateDesktopSetup(setupID)) }

                    XCTAssertTrue(manager.hasActiveArrangementInteraction, operation + " / " + gesture)
                    XCTAssertEqual(manager.desktopGeneration, generation)
                    XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
                    XCTAssertEqual(manager.arrangementUndo.count, undoCount)
                    for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
                    XCTAssertEqual(try Data(contentsOf: storeURL), stored)
                    if operation == "switch-active-write" || operation == "switch-corrupt-store" {
                        XCTAssertNotNil(try DesktopSetupLibrary.read(in: manager.storageDir).previous,
                                        "A successfully written recovery remains available when the active save fails")
                    } else { XCTAssertEqual(try Data(contentsOf: setupsURL), setups) }
                    if operation == "switch-corrupt-store" {
                        XCTAssertFalse(manager.persist(), "Unreadable stores must stay protected from later writes")
                        XCTAssertEqual(try Data(contentsOf: storeURL), stored)
                        return
                    }
                    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: storeURL.path)
                    if let oldPermissions { try FileManager.default.setAttributes([.posixPermissions: oldPermissions], ofItemAtPath: manager.storageDir.path) }
                    try originalStore.write(to: storeURL)
                    try finishGesture(gesture, manager: manager, parent: parent.id, child: child.id)
                    XCTAssertEqual(manager.arrangementUndo.count, undoCount + 1)
                    XCTAssertTrue(manager.undoArrangement())
                    XCTAssertEqual(manager.arrangementSnapshot(ids: ids), committed)
                }
            }
        }
    }

    @MainActor
    func testSuccessfulSetupSaveOrSwitchSettlesGestureOnlyAfterCommit() throws {
        for switching in [false, true] {
            for gesture in ["background", "photo-resize", "group-resize"] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let setupID = try manager.saveDesktopSetup(named: "Original")
                    let original = manager.photos
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                    manager.selectedPhotoIDs = [parent.id]
                    manager.nudgeSelected(.right, modifiers: [.shift])
                    let committed = manager.photos
                    let windows = manager.windows
                    let generation = manager.desktopGeneration
                    try beginGesture(gesture, manager: manager, parent: parent.id, child: child.id)

                    if switching { try manager.activateDesktopSetup(setupID) }
                    else { _ = try manager.saveDesktopSetup(named: "Committed placement") }

                    XCTAssertFalse(manager.hasActiveArrangementInteraction)
                    if switching {
                        XCTAssertNotEqual(manager.desktopGeneration, generation)
                        XCTAssertTrue(manager.arrangementUndo.isEmpty)
                        for item in original {
                            XCTAssertEqual(manager.photos.first { $0.id == item.id }?.frameString, item.frameString)
                        }
                    } else {
                        XCTAssertEqual(manager.desktopGeneration, generation)
                        for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
                        let saved = try XCTUnwrap(DesktopSetupLibrary.read(in: manager.storageDir).setups.last)
                        for item in committed {
                            XCTAssertEqual(saved.photos.first { $0.id == item.id }?.frameString, item.frameString)
                            XCTAssertEqual(manager.windows[item.id]?.photoFrame, NSRectFromString(item.frameString))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func beginGesture(_ gesture: String, manager: PhotoManager, parent: UUID, child: UUID) throws {
        let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
        surface.transition?.currentProgress = 1
        if gesture == "background" {
            manager.moveCollage(parent, to: surface.photoFrame.offsetBy(dx: 24, dy: 12), finished: false)
        } else if gesture == "photo-resize" {
            manager.beginCollageDrag(child, resizing: true)
            let window = try XCTUnwrap(manager.windows[child])
            var frame = window.photoFrame
            frame.size.width *= 1.1; frame.size.height *= 1.1
            window.setPhotoFrame(try XCTUnwrap(manager.proposeCollageDrag(child, frame: frame, bypassSnap: true)))
        } else {
            XCTAssertNotNil(manager.beginCollageResize(parent))
            manager.resizeCollage(parent, scale: 1.1, corner: .topRight, finished: false)
        }
    }

    @MainActor
    private func finishGesture(_ gesture: String, manager: PhotoManager, parent: UUID, child: UUID) throws {
        if gesture == "background" {
            manager.moveCollage(parent, to: try XCTUnwrap(manager.windows[parent]).photoFrame, finished: true)
        } else if gesture == "photo-resize" { XCTAssertTrue(manager.finishCollageDrag(child)) }
        else { manager.resizeCollage(parent, scale: 1.1, corner: .topRight, finished: true) }
    }

    @MainActor
    func testSavedMediaSurvivesMissingActiveStoreAndCorruptMediaCannotReplaceDesktop() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let saved = try manager.saveDesktopSetup(named: "Keep")
            let item = try XCTUnwrap(manager.photos.first)
            let mediaURL = manager.storageDir.appendingPathComponent(item.filename)
            try FileManager.default.removeItem(at: manager.storageDir.appendingPathComponent("photos.json"))
            manager.removeStoredFileIfUnreferenced(item.filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
            XCTAssertTrue(manager.persist())
            manager.photos[0].customName = "Current"
            XCTAssertTrue(manager.persist())
            try Data("not an image".utf8).write(to: mediaURL)
            XCTAssertThrowsError(try manager.activateDesktopSetup(saved))
            XCTAssertEqual(manager.photos[0].customName, "Current")
            XCTAssertNil(try DesktopSetupLibrary.read(in: manager.storageDir).previous)
        }
    }

    @MainActor
    func testSetupActionsPreserveOpenAppearanceDraft() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let saved = try manager.saveDesktopSetup(named: "Keep")
            let id = UUID()
            let session = UUID()
            manager.collageAppearanceDrafts[id] = CollageAppearanceDraft(session: session, settings: DesktopCollageSettings())
            XCTAssertThrowsError(try manager.saveDesktopSetup(named: "Draft"))
            XCTAssertThrowsError(try manager.activateDesktopSetup(saved))
            XCTAssertEqual(manager.collageAppearanceDrafts[id]?.session, session)
            manager.collageAppearanceDrafts.removeAll()
        }
    }

    @MainActor
    func testSwitchingRetainsMediaAndPreviousDesktopWithOriginalIDs() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let original = manager.photos
            let saved = try manager.saveDesktopSetup(named: "  Personal  ")
            manager.removeAllPhotos()
            XCTAssertTrue(manager.photos.isEmpty)
            for item in original {
                XCTAssertTrue(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(item.filename).path))
            }
            try manager.activateDesktopSetup(saved)
            XCTAssertEqual(manager.photos.map(\.id), original.map(\.id))
            try manager.activateDesktopSetup()
            XCTAssertTrue(manager.photos.isEmpty)
            try manager.activateDesktopSetup()
            XCTAssertEqual(manager.photos.map(\.id), original.map(\.id))
            try manager.duplicateDesktopSetup(saved)
            let duplicate = try XCTUnwrap(DesktopSetupLibrary.read(in: manager.storageDir).setups.last)
            XCTAssertNotEqual(duplicate.id, saved)
            XCTAssertEqual(duplicate.photos.map(\.id), original.map(\.id))
            try manager.deleteDesktopSetup(duplicate.id)
            try manager.renameDesktopSetup(saved, to: "Memories")
            let library = try DesktopSetupLibrary.read(in: manager.storageDir)
            XCTAssertEqual(library.setups.first?.name, "Memories")
            try manager.deleteDesktopSetup(saved)
            XCTAssertTrue(try DesktopSetupLibrary.read(in: manager.storageDir).setups.isEmpty)
            XCTAssertEqual(manager.photos.map(\.id), original.map(\.id))
        }
    }

    @MainActor
    func testDamagedSetupStorePreventsMediaDeletionAndOverwrite() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let item = try XCTUnwrap(manager.photos.first)
            let url = manager.storageDir.appendingPathComponent("setups.json")
            try Data("damaged".utf8).write(to: url)
            manager.removeAllPhotos()
            XCTAssertTrue(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(item.filename).path))
            XCTAssertThrowsError(try manager.saveDesktopSetup(named: "New"))
            XCTAssertEqual(try String(contentsOf: url), "damaged")
        }
    }

    @MainActor
    func testMissingSetupMediaAndFailedCommitKeepCurrentDesktop() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let id = try manager.saveDesktopSetup(named: "Original")
            manager.photos[0].customName = "Current"
            XCTAssertTrue(manager.persist())
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertThrowsError(try manager.activateDesktopSetup(id))
            XCTAssertEqual(manager.photos[0].customName, "Current")
            XCTAssertEqual(try DesktopSetupLibrary.read(in: manager.storageDir).previous?.photos.first?.customName, "Current")
            let item = manager.photos[0]
            try FileManager.default.removeItem(at: manager.storageDir.appendingPathComponent(item.filename))
            XCTAssertThrowsError(try manager.activateDesktopSetup(id))
            XCTAssertEqual(manager.photos[0].customName, "Current")
        }
    }
}
