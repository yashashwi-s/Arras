import AppKit
import XCTest
@testable import Arras

final class SlideshowEditingTests: XCTestCase {
    @MainActor
    func testSlideshowAdvancePreservesIndividualGesturesAndUnrelatedPlayback() throws {
        for grouped in [false, true] {
            for resizing in [false, true] {
                for previous in [false, true] {
                    try withTestLibrary { manager in
                        if grouped { XCTAssertTrue(manager.addStarterExample(.galleryWall)) }
                        XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
                        let item = try XCTUnwrap(manager.photos.last)
                        manager.setRotationInterval(item.id, "click")
                        if let parent = manager.photos.first(where: { $0.desktopCollage != nil }) {
                            let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == item.id })
                            manager.photos[index].collageParentID = parent.id
                            manager.fitCollageModel(parent.id)
                            manager.syncCollages(only: [parent.id])
                        }
                        XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
                        let other = try XCTUnwrap(manager.photos.last)
                        manager.setRotationInterval(other.id, "click")
                        let otherWindow = try XCTUnwrap(manager.windows[other.id])
                        let elsewhere = otherWindow.photoFrame.offsetBy(dx: 800, dy: 0)
                        otherWindow.setPhotoFrame(elsewhere)
                        manager.storeCollageFrame(other.id, elsewhere)
                        manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                        XCTAssertTrue(manager.persist())
                        let window = try XCTUnwrap(manager.windows[item.id])
                        let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
                        let pickup = resizing ? CGPoint(x: window.photoFrame.maxX - 1, y: window.photoFrame.maxY - 1)
                            : CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
                        let moved = CGPoint(x: pickup.x + 18, y: pickup.y + 12)
                        view.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: pickup))
                        view.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: window, at: moved, modifiers: .option))
                        XCTAssertEqual(manager.collageDrags[item.id]?.resized, resizing)
                        let frame = window.photoFrame
                        let image = try XCTUnwrap(view.photoLayer.image)
                        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                        let model = try encoder.encode(manager.photos)
                        let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                        if previous { manager.prevFolderImage(item.id) }
                        else { manager.nextFolderImage(item.id) }
                        let context = "grouped=\(grouped), resizing=\(resizing), previous=\(previous)"
                        XCTAssertEqual(try encoder.encode(manager.photos), model, context)
                        XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored, context)
                        XCTAssertEqual(window.photoFrame, frame, context)
                        XCTAssertTrue(view.photoLayer.image === image, context)
                        XCTAssertNotNil(manager.collageDrags[item.id], context)
                        manager.nextFolderImage(other.id)
                        XCTAssertEqual(manager.photos.first { $0.id == other.id }?.folderImageIndex, 1)
                        XCTAssertEqual(window.photoFrame, frame, context)
                        view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: moved))
                        XCTAssertNil(manager.collageDrags[item.id])
                        XCTAssertTrue(manager.undoArrangement(), context)
                        manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                        if previous { manager.prevFolderImage(item.id) }
                        else { manager.nextFolderImage(item.id) }
                        XCTAssertEqual(manager.photos.first { $0.id == item.id }?.folderImageIndex,
                                       previous ? item.spaceImageFilenames.count - 1 : 1, context)
                    }
                }
            }
        }
    }

    @MainActor
    func testElapsedAutomaticRotationWaitsForIndividualResizeAndResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasRotationGesture-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: root)
        defer {
            manager.cancelCollageInteractions(endAppearancePreviews: true)
            manager.rotationTimers.values.forEach { $0.cancel() }
            manager.windows.values.forEach { $0.hidePhoto() }
            manager.windows.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(manager.addStarterExample(.rotatingSpace, makeVisible: false))
        manager.photos[0].isVisible = true
        manager.photos[0].rotationInterval = "custom"
        manager.photos[0].customRotationSeconds = 5
        let item = manager.photos[0]
        let window = DesktopPhotoWindow()
        window.photoId = item.id
        window.showPhoto(try XCTUnwrap(manager.loadDisplayContent(for: item)), locked: false, settings: item)
        window.setPhotoFrame(NSRectFromString(item.frameString))
        // Isolate the actual timer from whichever app covers the test host.
        // Own-process gesture delivery is real; physical/occlusion acceptance is separate.
        window.orderOut(nil)
        XCTAssertTrue(window.runtimeActivityDecision.allowsRotation)
        manager.windows[item.id] = window
        manager.wireCollageDrag(window, item: item)
        XCTAssertTrue(manager.persist())
        let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
        let pickup = CGPoint(x: window.photoFrame.maxX - 1, y: window.photoFrame.maxY - 1)
        let moved = CGPoint(x: pickup.x + 18, y: pickup.y + 12)
        view.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: pickup))
        view.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: window, at: moved, modifiers: .option))
        XCTAssertEqual(manager.collageDrags[item.id]?.resized, true)
        let image = try XCTUnwrap(view.photoLayer.image)
        let frame = window.photoFrame
        let stored = try Data(contentsOf: root.appendingPathComponent("photos.json"))
        manager.setupRotationTimer(for: item)
        XCTAssertNotNil(manager.rotationTimers[item.id])
        try await Task.sleep(for: .milliseconds(6200))
        XCTAssertEqual(manager.photos[0].folderImageIndex, 0)
        XCTAssertTrue(view.photoLayer.image === image)
        XCTAssertEqual(window.photoFrame, frame)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photos.json")), stored)
        view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: moved))
        let deadline = Date().addingTimeInterval(6)
        while manager.photos[0].folderImageIndex == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(manager.photos[0].folderImageIndex, 1, "The normal elapsed timer resumes after release")
        XCTAssertNil(manager.collageDrags[item.id])
    }

    @MainActor
    func testFailedSlideshowControlSavesPreservePlaybackTimerAndCrop() throws {
        for control in ["order", "interval", "seconds", "size"] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.rotatingSpace, makeVisible: false))
                var item = try XCTUnwrap(manager.photos.first)
                item.isVisible = true
                item.rotationInterval = "custom"
                item.customRotationSeconds = 60
                item.playbackOrder = .random
                item.playbackStep = 4
                item.playbackHistory = [item.spaceImageFilenames[0]]
                manager.photos = [item]
                let content = try XCTUnwrap(manager.loadDisplayContent(for: item))
                let window = DesktopPhotoWindow()
                window.showPhoto(content, locked: false, settings: item)
                manager.windows[item.id] = window
                manager.setupRotationTimer(for: item)
                defer {
                    manager.rotationTimers.values.forEach { $0.cancel() }
                    manager.rotationTimers.removeAll()
                }
                let timer = try XCTUnwrap(manager.rotationTimers[item.id])
                let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
                let gravity = view.photoLayer.layer.contentsGravity
                let frame = window.photoFrame
                XCTAssertTrue(manager.persist())
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let before = try encoder.encode(manager.photos)
                let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                switch control {
                case "order": manager.setPlaybackOrder(item.id, .noRepeat)
                case "interval": manager.setRotationInterval(item.id, "click")
                case "seconds": manager.setCustomRotationSeconds(item.id, 10)
                default: manager.setFolderSizeMode(item.id, "fixed")
                }
                XCTAssertEqual(try encoder.encode(manager.photos), before, control)
                XCTAssertTrue(manager.rotationTimers[item.id] === timer, control)
                XCTAssertEqual(view.photoLayer.layer.contentsGravity, gravity, control)
                XCTAssertEqual(window.photoFrame, frame, control)
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored, control)
            }
        }
    }

    @MainActor
    func testFailedSlideshowAdvancePreservesVisibleImageAndSelection() throws {
        for direction in ["next", "previous"] {
            for failure in ["save", "decode"] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
                    let item = try XCTUnwrap(manager.photos.first)
                    manager.setRotationInterval(item.id, "click")
                    let window = try XCTUnwrap(manager.windows[item.id])
                    let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
                    let contents = try XCTUnwrap(view.photoLayer.layer.contents as AnyObject?)
                    let frame = window.photoFrame
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                    if failure == "save" {
                        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    } else {
                        let target = direction == "next" ? 1 : item.spaceImageFilenames.count - 1
                        try Data("unreadable sample image".utf8).write(to:
                            manager.storageDir.appendingPathComponent(item.spaceImageFilenames[target]))
                    }
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                    if direction == "next" { manager.nextFolderImage(item.id) }
                    else { manager.prevFolderImage(item.id) }
                    let context = "\(direction), \(failure)"
                    XCTAssertEqual(try encoder.encode(manager.photos), before, context)
                    XCTAssertTrue((view.photoLayer.layer.contents as AnyObject?) === contents, context)
                    XCTAssertEqual(window.photoFrame, frame, context)
                    XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored, context)
                }
            }
        }
    }

    @MainActor
    func testEditReordersRemovesAndKeepsDisplayedImageWithRemappedHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["one.jpg", "two.jpg", "three.jpg"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }

        let manager = PhotoManager(storageDirectory: directory)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = ["one.jpg", "two.jpg", "three.jpg"]
        space.folderImageIndex = 1
        space.playbackOrder = .noRepeat
        space.playbackStep = 9
        space.playbackHistory = ["one.jpg", "two.jpg", "removed.jpg", "one.jpg"]
        space.folderImageConfigs = [
            "one.jpg": FolderImageConfig(frameString: "{1, 1}, {100, 100}"),
            "two.jpg": FolderImageConfig(frameString: "{2, 2}, {200, 200}"),
            "three.jpg": FolderImageConfig(frameString: "{3, 3}, {300, 300}")
        ]
        space.mediaFidelity = ["one.jpg": .transformed, "two.jpg": .sourceBytes, "three.jpg": .sourceBytes]
        manager.photos = [space]
        XCTAssertTrue(manager.persist())

        XCTAssertTrue(manager.applySlideshowEdit(space.id, imageFilenames: ["three.jpg", "two.jpg"]))

        let edited = try XCTUnwrap(manager.photos.first)
        XCTAssertEqual(edited.spaceImageFilenames, ["three.jpg", "two.jpg"])
        XCTAssertEqual(edited.folderImageIndex, 1)
        XCTAssertEqual(edited.playbackStep, 0)
        XCTAssertEqual(edited.playbackHistory, ["two.jpg"])
        XCTAssertEqual(Set(edited.folderImageConfigs.keys), Set(["two.jpg", "three.jpg"]))
        XCTAssertEqual(Set(edited.mediaFidelity.keys), Set(["two.jpg", "three.jpg"]))
        XCTAssertEqual(manager.spaceImages[space.id]?.map(\.lastPathComponent), ["three.jpg", "two.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("one.jpg").path))

        let reloaded = PhotoManager(storageDirectory: directory)
        XCTAssertEqual(reloaded.photos.first?.spaceImageFilenames, ["three.jpg", "two.jpg"])
        XCTAssertEqual(reloaded.photos.first?.folderImageIndex, 1)
    }

    @MainActor
    func testEditSelectsAValidReplacementAndResetsNonNoRepeatHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = ["one.jpg", "two.jpg", "three.jpg"]
        space.folderImageIndex = 2
        space.playbackOrder = .random
        space.playbackStep = 4
        space.playbackHistory = ["one.jpg"]
        manager.photos = [space]
        XCTAssertTrue(manager.persist())

        XCTAssertTrue(manager.applySlideshowEdit(space.id, imageFilenames: ["one.jpg", "two.jpg"]))

        let edited = try XCTUnwrap(manager.photos.first)
        XCTAssertEqual(edited.folderImageIndex, 1)
        XCTAssertEqual(edited.spaceImageFilenames[edited.folderImageIndex], "two.jpg")
        XCTAssertEqual(edited.playbackStep, 0)
        XCTAssertTrue(edited.playbackHistory.isEmpty)
    }

    @MainActor
    func testEditRejectsInvalidMembershipLinkedSourcesAndPersistenceFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = ["one.jpg", "two.jpg"]
        manager.photos = [space]

        XCTAssertFalse(manager.applySlideshowEdit(space.id, imageFilenames: []))
        XCTAssertFalse(manager.applySlideshowEdit(space.id, imageFilenames: ["foreign.jpg"]))
        XCTAssertEqual(manager.photos.first?.spaceImageFilenames, ["one.jpg", "two.jpg"])

        manager.photos[0].liveFolderSource = LiveFolderSource(sourcePath: "/linked")
        XCTAssertFalse(manager.applySlideshowEdit(space.id, imageFilenames: ["two.jpg", "one.jpg"]))
        manager.photos[0].liveFolderSource = nil

        let corruptStore = Data("not valid json".utf8)
        try corruptStore.write(to: directory.appendingPathComponent("photos.json"))
        XCTAssertFalse(manager.applySlideshowEdit(space.id, imageFilenames: ["one.jpg"]))
        XCTAssertEqual(manager.photos.first?.spaceImageFilenames, ["one.jpg", "two.jpg"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), corruptStore)
    }

    @MainActor
    func testUnreadableReplacementLeavesOpenWidgetAndPlaylistIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "")
        item.spaceImageFilenames = ["current.png", "missing.png"]
        manager.photos = [item]
        let window = DesktopPhotoWindow()
        manager.windows[item.id] = window
        defer { window.close() }
        XCTAssertTrue(manager.persist())
        let saved = try Data(contentsOf: directory.appendingPathComponent("photos.json"))
        XCTAssertFalse(manager.applySlideshowEdit(item.id, imageFilenames: ["missing.png"]))
        XCTAssertEqual(manager.photos[0].spaceImageFilenames, item.spaceImageFilenames)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), saved)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasSlideshowEditing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
