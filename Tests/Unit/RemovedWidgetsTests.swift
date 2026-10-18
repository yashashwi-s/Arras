import AppKit
import XCTest
@testable import Arras

final class RemovedWidgetsTests: XCTestCase {
    @MainActor
    func testMissingFailedAndSuccessfulRemovalPreserveUnrelatedAppearancePreview() throws {
        for outcome in ["missing", "recovery-failure", "save-failure", "success"] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
                manager.removePhoto(try XCTUnwrap(manager.photos.first).id)
                XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
                let target = try XCTUnwrap(manager.photos.first)
                XCTAssertTrue(manager.addStarterExample(.galleryWall))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
                let session = UUID()
                manager.beginCollageAppearancePreview(parent.id, session: session)
                var draft = try XCTUnwrap(parent.desktopCollage)
                draft.gap += 30
                draft.caption = "Unsaved during " + outcome
                manager.previewCollageAppearance(parent.id, session: session, settings: draft)
                manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                surface.transition?.currentProgress = 1
                let preview = manager.arrangementSnapshot(ids: ids)
                let windows = manager.windows
                let label = try XCTUnwrap(manager.collageLabelWindows[parent.id])
                let generation = manager.desktopGeneration
                let activeURL = manager.storageDir.appendingPathComponent("photos.json")
                let recoveryURL = manager.storageDir.appendingPathComponent("setups.json")
                if outcome == "recovery-failure" { try Data("damaged recovery".utf8).write(to: recoveryURL) }
                if outcome == "save-failure" { try Data("damaged active store".utf8).write(to: activeURL) }
                let active = try Data(contentsOf: activeURL), recovery = try Data(contentsOf: recoveryURL)

                manager.removePhoto(outcome == "missing" ? UUID() : target.id)

                XCTAssertEqual(manager.desktopGeneration, generation, outcome)
                XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, session, outcome)
                XCTAssertEqual(surface.settings.caption, draft.caption, outcome)
                XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview, outcome)
                for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window, outcome) }
                XCTAssertTrue(manager.collageLabelWindows[parent.id] === label, outcome)
                XCTAssertTrue(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(target.filename).path))
                if outcome == "success" {
                    XCTAssertNil(manager.photos.first { $0.id == target.id })
                    XCTAssertEqual(try DesktopSetupLibrary.read(in: manager.storageDir).removed?.photos.map(\.id), [target.id])
                    let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: activeURL))
                    XCTAssertEqual(saved.first { $0.id == parent.id }?.desktopCollage, parent.desktopCollage)
                } else {
                    XCTAssertNotNil(manager.photos.first { $0.id == target.id }, outcome)
                    XCTAssertEqual(try Data(contentsOf: activeURL), active, outcome)
                    XCTAssertEqual(try Data(contentsOf: recoveryURL), recovery, outcome)
                }
            }
        }
    }

    @MainActor
    func testRemovalWaitsForAffectedAppearancePreviewAndRetainsItsRecovery() throws {
        for removingParent in [false, true] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.galleryWall))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                let target: PhotoItem
                if removingParent { target = parent }
                else { target = try XCTUnwrap(manager.collageMembers(parent.id).first) }
                let session = UUID()
                manager.beginCollageAppearancePreview(parent.id, session: session)
                var draft = try XCTUnwrap(parent.desktopCollage)
                draft.gap += 30
                manager.previewCollageAppearance(parent.id, session: session, settings: draft)
                manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                (manager.windows[parent.id] as? CollageDesktopWindow)?.transition?.currentProgress = 1
                let ids = Set(manager.photos.map(\.id))
                let preview = manager.arrangementSnapshot(ids: ids)
                let windows = manager.windows
                let activeURL = manager.storageDir.appendingPathComponent("photos.json")
                let recoveryURL = manager.storageDir.appendingPathComponent("setups.json")
                let active = try Data(contentsOf: activeURL)
                let recovery = try? Data(contentsOf: recoveryURL)

                manager.removePhoto(target.id)

                XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, session)
                XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
                for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
                XCTAssertNotNil(manager.photos.first { $0.id == target.id })
                XCTAssertEqual(try Data(contentsOf: activeURL), active)
                XCTAssertEqual(try? Data(contentsOf: recoveryURL), recovery)
                manager.endCollageAppearancePreview(parent.id, session: session, animated: false)
                manager.removePhoto(target.id)
                XCTAssertNil(manager.photos.first { $0.id == target.id })
                XCTAssertEqual(try DesktopSetupLibrary.read(in: manager.storageDir).removed?.photos.map(\.id), [target.id])
            }
        }
    }

    @MainActor
    func testRemovalPreservesUnrelatedGesturesAndDefersConflictingOnes() throws {
        for gesture in ["background", "photo", "resize"] {
            for related in [false, true] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
                    let unrelated = try XCTUnwrap(manager.photos.first)
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                    let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                    surface.transition?.currentProgress = 1
                    let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
                    let before = manager.arrangementSnapshot(ids: ids)
                    if gesture == "background" {
                        manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 24, dy: 12), finished: false)
                    } else if gesture == "photo" {
                        manager.beginCollageDrag(child.id)
                        let window = try XCTUnwrap(manager.windows[child.id])
                        window.setPhotoFrame(window.photoFrame.offsetBy(dx: 24, dy: 12))
                    } else {
                        XCTAssertNotNil(manager.beginCollageResize(parent.id))
                        manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
                    }
                    let preview = manager.arrangementSnapshot(ids: ids)
                    let windows = manager.windows
                    let target = related ? child.id : unrelated.id
                    let activeURL = manager.storageDir.appendingPathComponent("photos.json")
                    let recoveryURL = manager.storageDir.appendingPathComponent("setups.json")
                    let active = try Data(contentsOf: activeURL), recovery = try? Data(contentsOf: recoveryURL)

                    manager.removePhoto(target)

                    XCTAssertTrue(manager.hasActiveArrangementInteraction, gesture)
                    XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview, gesture)
                    for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window, gesture) }
                    if related {
                        XCTAssertNotNil(manager.photos.first { $0.id == target })
                        XCTAssertEqual(try Data(contentsOf: activeURL), active)
                        XCTAssertEqual(try? Data(contentsOf: recoveryURL), recovery)
                    } else {
                        XCTAssertNil(manager.photos.first { $0.id == target })
                        if gesture == "background" { manager.moveCollage(parent.id, to: surface.photoFrame, finished: true) }
                        else if gesture == "photo" { XCTAssertTrue(manager.finishCollageDrag(child.id)) }
                        else { manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: true) }
                        XCTAssertTrue(manager.undoArrangement(), gesture)
                        XCTAssertEqual(manager.arrangementSnapshot(ids: ids), before, gesture)
                        XCTAssertNil(manager.photos.first { $0.id == target }, "Undo must not restore a later removed widget")
                    }
                }
            }
        }
    }

    @MainActor
    func testRecoveryPreservesAnUnrelatedAppearancePreviewAndHistory() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let removed = try XCTUnwrap(manager.photos.first)
            manager.removePhoto(removed.id)
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let ids = Set(manager.photos.map(\.id))
            let original = manager.arrangementSnapshot(ids: ids)
            manager.selectedPhotoIDs = [parent.id]
            manager.nudgeSelected(.right, modifiers: [.shift])
            let committed = manager.photos
            let session = UUID()
            manager.beginCollageAppearancePreview(parent.id, session: session)
            var draft = try XCTUnwrap(parent.desktopCollage)
            draft.gap += 30
            draft.caption = "Keep this unsaved appearance"
            manager.previewCollageAppearance(parent.id, session: session, settings: draft)
            manager.collageFlights.values.forEach { $0.currentProgress = 1 }
            let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            let preview = manager.arrangementSnapshot(ids: ids)
            let windows = manager.windows
            let label = try XCTUnwrap(manager.collageLabelWindows[parent.id])
            let generation = manager.desktopGeneration
            XCTAssertNotEqual(preview, original)

            try manager.restoreRemovedWidgets()

            XCTAssertEqual(manager.desktopGeneration, generation)
            XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, session)
            XCTAssertEqual(surface.settings.caption, draft.caption)
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            XCTAssertTrue(manager.collageLabelWindows[parent.id] === label)
            XCTAssertNotNil(manager.photos.first { $0.id == removed.id })
            XCTAssertNil(manager.windows[removed.id])
            let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            for item in committed {
                let persisted = try XCTUnwrap(saved.first { $0.id == item.id })
                XCTAssertEqual(persisted.frameString, item.frameString)
                XCTAssertEqual(persisted.desktopCollage, item.desktopCollage,
                               "Recovery must not save the unrelated appearance draft")
            }
            manager.endCollageAppearancePreview(parent.id, session: session, animated: false)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), original)
            XCTAssertNotNil(manager.photos.first { $0.id == removed.id }, "Undo must retain the recovery addition")
        }
    }

    @MainActor
    func testRecoveryDefersAnAffectedAppearancePreviewWithoutChangingIt() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let removed = try XCTUnwrap(manager.collageMembers(parent.id).first)
            manager.removePhoto(removed.id)
            let session = UUID()
            manager.beginCollageAppearancePreview(parent.id, session: session)
            var draft = try XCTUnwrap(parent.desktopCollage)
            draft.gap += 30
            draft.caption = "Finish this edit first"
            manager.previewCollageAppearance(parent.id, session: session, settings: draft)
            manager.collageFlights.values.forEach { $0.currentProgress = 1 }
            (manager.windows[parent.id] as? CollageDesktopWindow)?.transition?.currentProgress = 1
            let ids = Set(manager.photos.map(\.id))
            let preview = manager.arrangementSnapshot(ids: ids)
            let windows = manager.windows
            let activeURL = manager.storageDir.appendingPathComponent("photos.json")
            let recoveryURL = manager.storageDir.appendingPathComponent("setups.json")
            let active = try Data(contentsOf: activeURL), recovery = try Data(contentsOf: recoveryURL)

            XCTAssertThrowsError(try manager.restoreRemovedWidgets()) { error in
                guard case SetupError.unfinishedArrangement = error else {
                    return XCTFail("Recovery must identify the affected appearance edit: \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("appearance"))
            }

            XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, session)
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            XCTAssertNil(manager.photos.first { $0.id == removed.id })
            XCTAssertEqual(try Data(contentsOf: activeURL), active)
            XCTAssertEqual(try Data(contentsOf: recoveryURL), recovery)
            manager.endCollageAppearancePreview(parent.id, session: session, animated: false)
            try manager.restoreRemovedWidgets()
            XCTAssertEqual(manager.photos.first { $0.id == removed.id }?.collageParentID, parent.id)
            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            XCTAssertNil(try DesktopSetupLibrary.read(in: manager.storageDir).removed)
        }
    }

    @MainActor
    func testRecoveryPreservesUnrelatedPlaybackGestureAndUndo() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let removed = try XCTUnwrap(manager.photos.first)
            manager.removePhoto(removed.id)
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let ids = Set(manager.photos.map(\.id))
            let original = manager.arrangementSnapshot(ids: ids)
            manager.selectedPhotoIDs = [parent.id]
            manager.nudgeSelected(.right, modifiers: [.shift])
            let nudged = manager.arrangementSnapshot(ids: ids)
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
            let slideshow = try XCTUnwrap(manager.photos.last)
            let player = try XCTUnwrap(manager.windows[slideshow.id])
            let image = try XCTUnwrap((player.contentView as? DraggablePhotoView)?.photoLayer.image)
            let urls = manager.spaceImages[slideshow.id]
            let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            let windows = manager.windows
            let label = try XCTUnwrap(manager.collageLabelWindows[parent.id])
            let generation = manager.desktopGeneration
            manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 24, dy: 12), finished: false)
            let preview = manager.arrangementSnapshot(ids: ids)
            XCTAssertTrue(manager.hasActiveArrangementInteraction)

            try manager.restoreRemovedWidgets()

            XCTAssertEqual(manager.desktopGeneration, generation)
            XCTAssertTrue(manager.hasActiveArrangementInteraction)
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            XCTAssertTrue(manager.collageLabelWindows[parent.id] === label)
            XCTAssertTrue((manager.windows[slideshow.id]?.contentView as? DraggablePhotoView)?.photoLayer.image === image)
            XCTAssertEqual(manager.spaceImages[slideshow.id], urls)
            XCTAssertNotNil(manager.photos.first { $0.id == removed.id })
            XCTAssertNil(manager.windows[removed.id], "A hidden recovered photo must stay hidden")
            manager.moveCollage(parent.id, to: surface.photoFrame, finished: true)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), nudged)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), original)
            XCTAssertNil(try DesktopSetupLibrary.read(in: manager.storageDir).removed)
            manager.rotationTimers.values.forEach { $0.cancel() }
        }
    }

    @MainActor
    func testRecoveredCollageRefitsLaterMemberEditsWithoutRecreatingTheirWindows() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let children = manager.collageMembers(parent.id)
            let child = try XCTUnwrap(children.first)
            manager.removePhoto(parent.id)
            manager.selectedPhotoIDs = [child.id]
            manager.nudgeSelected(.right, modifiers: [.shift, .option])
            manager.resize(child.id, to: 100)
            let windows = manager.windows
            let frames = Dictionary(uniqueKeysWithValues: manager.photos.map { ($0.id, NSRectFromString($0.frameString)) })
            let footprints = manager.photos.filter { $0.isVisible }.map {
                CollageGeometry.footprint($0, frame: NSRectFromString($0.frameString))
            }
            let expected = CollageGeometry.enclosing(footprints, fallback: NSRectFromString(parent.frameString),
                                                    settings: try XCTUnwrap(parent.desktopCollage))
            XCTAssertNotEqual(expected, NSRectFromString(parent.frameString))

            try manager.restoreRemovedWidgets()

            let recovered = try XCTUnwrap(manager.photos.first { $0.id == parent.id })
            XCTAssertEqual(NSRectFromString(recovered.frameString), expected)
            XCTAssertEqual(manager.windows[parent.id]?.photoFrame, expected)
            for (id, frame) in frames {
                XCTAssertTrue(manager.windows[id] === windows[id])
                XCTAssertEqual(manager.windows[id]?.photoFrame, frame)
                XCTAssertEqual(manager.photos.first { $0.id == id }?.collageParentID, parent.id)
            }
            let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            XCTAssertEqual(saved.first { $0.id == parent.id }?.frameString, recovered.frameString)
        }
    }

    @MainActor
    func testRecoveryConflictingWithActiveMemberDragPreservesItUntilRetry() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
            manager.removePhoto(parent.id)
            let window = try XCTUnwrap(manager.windows[child.id])
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            let center = CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
            let moved = CGPoint(x: center.x + 25, y: center.y + 15)
            view.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: center))
            view.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: window, at: moved, modifiers: .option))
            let preview = window.photoFrame
            let store = manager.storageDir.appendingPathComponent("photos.json")
            let setups = manager.storageDir.appendingPathComponent("setups.json")
            let stored = try Data(contentsOf: store), recovery = try Data(contentsOf: setups)

            XCTAssertThrowsError(try manager.restoreRemovedWidgets())

            XCTAssertTrue(manager.windows[child.id] === window)
            XCTAssertEqual(manager.windows[child.id]?.photoFrame, preview)
            XCTAssertTrue(manager.hasActiveArrangementInteraction)
            XCTAssertNil(manager.photos.first { $0.id == parent.id })
            XCTAssertNil(manager.photos.first { $0.id == child.id }?.collageParentID)
            XCTAssertEqual(try Data(contentsOf: store), stored)
            XCTAssertEqual(try Data(contentsOf: setups), recovery)
            view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: moved))
            try manager.restoreRemovedWidgets()
            XCTAssertEqual(manager.photos.first { $0.id == child.id }?.collageParentID, parent.id)
            XCTAssertTrue(manager.windows[child.id] === window)
        }
    }

    @MainActor
    func testFailedRecoverySavePreservesDetachedMembersAndRecovery() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            manager.removePhoto(parent.id)
            let windows = manager.windows
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(manager.photos)
            let recoveryURL = manager.storageDir.appendingPathComponent("setups.json")
            let recovery = try Data(contentsOf: recoveryURL)
            let store = manager.storageDir.appendingPathComponent("photos.json")
            let damaged = Data("damaged active store".utf8)
            try damaged.write(to: store)

            XCTAssertThrowsError(try manager.restoreRemovedWidgets())

            XCTAssertEqual(try encoder.encode(manager.photos), before)
            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            XCTAssertEqual(try Data(contentsOf: store), damaged)
            XCTAssertEqual(try Data(contentsOf: recoveryURL), recovery)
        }
    }

    @MainActor
    func testRecoveredMemberRefitsExistingParentAndDefersDuringItsResize() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
            manager.removePhoto(child.id)
            let windows = manager.windows
            let surface = try XCTUnwrap(windows[parent.id] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            let store = manager.storageDir.appendingPathComponent("photos.json")
            let recoveryURL = manager.storageDir.appendingPathComponent("setups.json")
            let saved = try Data(contentsOf: store), recovery = try Data(contentsOf: recoveryURL)
            XCTAssertNotNil(manager.beginCollageResize(parent.id))
            manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
            let ids = Set(manager.photos.map(\.id))
            let preview = manager.arrangementSnapshot(ids: ids)

            XCTAssertThrowsError(try manager.restoreRemovedWidgets())

            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
            XCTAssertNotNil(manager.collageResizeSnapshots[parent.id])
            XCTAssertEqual(try Data(contentsOf: store), saved)
            XCTAssertEqual(try Data(contentsOf: recoveryURL), recovery)
            manager.cancelCollageResize(parent.id)
            let frames = Dictionary(uniqueKeysWithValues: manager.photos.filter { $0.desktopCollage == nil }.map { ($0.id, manager.collageFrame($0)) })

            try manager.restoreRemovedWidgets()

            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            for (id, frame) in frames { XCTAssertEqual(manager.windows[id]?.photoFrame, frame) }
            let footprints = manager.collageMembers(parent.id).filter { $0.isVisible }.map {
                CollageGeometry.footprint($0, frame: NSRectFromString($0.frameString))
            }
            let restoredParent = try XCTUnwrap(manager.photos.first { $0.id == parent.id })
            let expected = CollageGeometry.enclosing(footprints, fallback: NSRectFromString(parent.frameString),
                                                    settings: try XCTUnwrap(restoredParent.desktopCollage))
            XCTAssertEqual(NSRectFromString(restoredParent.frameString), expected)
            XCTAssertEqual(manager.windows[parent.id]?.photoFrame, expected)
            XCTAssertNotNil(manager.windows[child.id])
            XCTAssertEqual(manager.photos.first { $0.id == child.id }?.collageParentID, parent.id)
            let decoded = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store))
            XCTAssertEqual(decoded.first { $0.id == parent.id }?.frameString, restoredParent.frameString)
        }
    }

    @MainActor
    func testRestoringCollageRecoversUnassignedChildrenWithoutStealingMovedChildren() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall, makeVisible: false))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let children = manager.collageMembers(parent.id)
            XCTAssertGreaterThan(children.count, 1)
            manager.removePhoto(parent.id)
            XCTAssertTrue(manager.photos.allSatisfy { $0.collageParentID == nil })
            var otherParent = PhotoItem(filename: "")
            otherParent.isVisible = false
            otherParent.desktopCollage = DesktopCollageSettings()
            manager.photos.append(otherParent)
            let movedIndex = try XCTUnwrap(manager.photos.firstIndex { $0.id == children[0].id })
            manager.photos[movedIndex].collageParentID = otherParent.id
            XCTAssertTrue(manager.persist())
            try manager.restoreRemovedWidgets()
            XCTAssertEqual(manager.photos.first { $0.id == children[0].id }?.collageParentID, otherParent.id)
            XCTAssertEqual(manager.photos.first { $0.id == children[1].id }?.collageParentID, parent.id)
            XCTAssertNotNil(manager.photos.first { $0.id == parent.id }?.desktopCollage)
        }
    }

    @MainActor
    func testRecoverySurvivesRelaunchAndPreservesSubsequentAdditionsAndEdits() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let removed = try XCTUnwrap(manager.photos.first)
            manager.removePhoto(removed.id)
            XCTAssertEqual(manager.removedWidgetCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(removed.filename).path))
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let addedID = try XCTUnwrap(manager.photos.first?.id)
            manager.renamePhoto(addedID, to: "Keep my later edit")
            let reloaded = PhotoManager(storageDirectory: manager.storageDir)
            defer { reloaded.windows.values.forEach { $0.hidePhoto() }; reloaded.windows.removeAll() }
            XCTAssertEqual(reloaded.removedWidgetCount, 1)
            try reloaded.restoreRemovedWidgets()
            XCTAssertEqual(Set(reloaded.photos.map(\.id)), [removed.id, addedID])
            XCTAssertEqual(reloaded.photos.first { $0.id == addedID }?.customName, "Keep my later edit")
            XCTAssertEqual(reloaded.removedWidgetCount, 0)
            XCTAssertNil(try DesktopSetupLibrary.read(in: manager.storageDir).removed)
        }
    }

    @MainActor
    func testSecondRemovalReleasesOnlyPreviousRecoveryAndMissingMediaLeavesDesktopIntact() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let first = try XCTUnwrap(manager.photos.first)
            manager.removePhoto(first.id)
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let second = try XCTUnwrap(manager.photos.first)
            manager.removePhoto(second.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(first.filename).path))
            try FileManager.default.removeItem(at: manager.storageDir.appendingPathComponent(second.filename))
            XCTAssertThrowsError(try manager.restoreRemovedWidgets())
            XCTAssertTrue(manager.photos.isEmpty)
            XCTAssertNotNil(try DesktopSetupLibrary.read(in: manager.storageDir).removed)
        }
    }

    @MainActor
    func testFailedRemovalPreservesPriorRecovery() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let first = try XCTUnwrap(manager.photos.first)
            manager.removePhoto(first.id)
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let current = try XCTUnwrap(manager.photos.first)
            try Data("broken".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.removePhoto(current.id)
            XCTAssertEqual(manager.photos.first?.id, current.id)
            XCTAssertEqual(try DesktopSetupLibrary.read(in: manager.storageDir).removed?.photos.first?.id, first.id)
        }
    }
}
