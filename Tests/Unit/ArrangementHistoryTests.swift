import AppKit
import XCTest
@testable import Arras

final class ArrangementHistoryTests: XCTestCase {
    @MainActor
    func testDesktopMenuCanUndoAndRedoWithoutSettingsFocus() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let delegate = AppDelegate(manager: manager)
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.autoenablesItems = false
            status.menu = menu
            delegate.statusItem = status
            defer { NSStatusBar.system.removeStatusItem(status); delegate.statusItem = nil }
            let item = try XCTUnwrap(manager.photos.first)
            manager.selectedPhotoIDs = [item.id]
            let original = try XCTUnwrap(manager.windows[item.id]).photoFrame
            manager.nudgeSelected(.right, modifiers: [.shift])
            delegate.rebuildMenu()
            let palette = try XCTUnwrap(menu.items.first { $0.submenu?.presentationStyle == .palette }?.submenu)
            XCTAssertFalse(palette.autoenablesItems)
            XCTAssertEqual(palette.items.count, 2)
            XCTAssertFalse(palette.items[1].isEnabled)
            XCTAssertTrue(palette.items.allSatisfy { $0.image != nil && $0.toolTip?.isEmpty == false })
            let undo = palette.items[0]
            XCTAssertTrue(undo.isEnabled)
            XCTAssertEqual(undo.accessibilityLabel(), undo.title)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(undo.action), to: undo.target, from: undo))
            XCTAssertEqual(manager.windows[item.id]?.photoFrame, original)
            delegate.rebuildMenu()
            let refreshed = try XCTUnwrap(menu.items.first { $0.submenu?.presentationStyle == .palette }?.submenu)
            XCTAssertFalse(refreshed.items[0].isEnabled)
            let redo = refreshed.items[1]
            XCTAssertTrue(redo.isEnabled)
            // Keep native modifier/key-code fields coherent without posting keyboard input.
            let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
            key.flags = [.maskCommand, .maskShift]
            let shortcut = try XCTUnwrap(NSEvent(cgEvent: key))
            XCTAssertTrue(menu.performKeyEquivalent(with: shortcut))
            XCTAssertEqual(manager.windows[item.id]?.photoFrame.minX, original.minX + 10)
            let top = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(top[0].title, "Add")
            XCTAssertTrue(top[1].title.hasPrefix("Widgets ("))
            let row = try XCTUnwrap(top.firstIndex { $0.submenu?.presentationStyle == .palette })
            let settings = try XCTUnwrap(top.firstIndex { $0.keyEquivalent == "," })
            XCTAssertLessThan(row, settings)
            XCTAssertEqual(top[settings + 1].title, "Options")
            XCTAssertEqual(top.last?.title, "Quit Arras")
            XCTAssertFalse(menu.items.contains { $0.keyEquivalent == "z" }, "History commands belong inside the icon row")
        }
    }

    @MainActor
    func testUndoRedoRestoresPlacementAndPreservesLaterNameAndAppearance() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let item = try XCTUnwrap(manager.photos.first)
            manager.selectedPhotoIDs = [item.id]
            let original = try XCTUnwrap(manager.windows[item.id]).photoFrame
            manager.nudgeSelected(.right, modifiers: [.shift])
            XCTAssertTrue(manager.canUndoArrangement)
            let moved = manager.windows[item.id]!.photoFrame
            XCTAssertEqual(moved.minX, original.minX + 10)
            manager.photos[0].customName = "Keep this name"
            manager.photos[0].opacity = 0.4
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.windows[item.id]!.photoFrame, original)
            XCTAssertEqual(manager.photos[0].customName, "Keep this name")
            XCTAssertEqual(manager.photos[0].opacity, 0.4)
            XCTAssertTrue(manager.redoArrangement())
            XCTAssertEqual(manager.windows[item.id]!.photoFrame, moved)
            manager.nudgeSelected(.down)
            XCTAssertTrue(manager.arrangementRedo.isEmpty)
        }
    }

    @MainActor
    func testUndoMovesCollageChildrenTogetherAndRejectsMembershipChange() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let members = manager.collageMembers(parent.id)
            let ids = Set([parent.id] + members.map(\.id))
            let original = manager.arrangementSnapshot(ids: ids)
            manager.selectedPhotoIDs = [parent.id]
            manager.nudgeSelected(.right, modifiers: [.shift])
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), original)
            XCTAssertTrue(manager.redoArrangement())
            let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == members.first?.id })
            manager.photos[index].collageParentID = nil
            XCTAssertFalse(manager.canUndoArrangement)
            XCTAssertFalse(manager.undoArrangement())
        }
    }

    @MainActor
    func testFailedUndoKeepsHistoryAndWindows() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let item = try XCTUnwrap(manager.photos.first)
            manager.selectedPhotoIDs = [item.id]
            manager.nudgeSelected(.right)
            let frame = manager.windows[item.id]!.photoFrame
            try Data("corrupt".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertFalse(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            XCTAssertTrue(manager.arrangementRedo.isEmpty)
            XCTAssertEqual(manager.windows[item.id]!.photoFrame, frame)
        }
    }

    @MainActor
    func testDesktopReplacementClearsArrangementHistory() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let item = try XCTUnwrap(manager.photos.first)
            manager.selectedPhotoIDs = [item.id]
            manager.nudgeSelected(.right)
            XCTAssertFalse(manager.arrangementUndo.isEmpty)
            XCTAssertTrue(manager.restoreDesktopSetupItems(manager.photos))
            XCTAssertTrue(manager.arrangementUndo.isEmpty)
            XCTAssertTrue(manager.arrangementRedo.isEmpty)
        }
    }

    @MainActor
    func testPhotoDragAndResizeCommitOneEntryAndCancelCommitsNone() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let item = try XCTUnwrap(manager.photos.first)
            let window = try XCTUnwrap(manager.windows[item.id])
            let original = window.photoFrame
            manager.beginCollageDrag(item.id)
            window.setPhotoFrame(original.offsetBy(dx: 50, dy: 20))
            XCTAssertTrue(manager.finishCollageDrag(item.id))
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(window.photoFrame, original)
            manager.beginCollageDrag(item.id, resizing: true)
            window.setPhotoFrame(NSRect(x: original.minX, y: original.minY, width: original.width * 1.2, height: original.height * 1.2))
            XCTAssertTrue(manager.finishCollageDrag(item.id))
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(window.photoFrame, original)
            manager.beginCollageDrag(item.id)
            window.setPhotoFrame(original.offsetBy(dx: 80, dy: 0))
            manager.cancelCollageDrag(item.id)
            XCTAssertTrue(manager.arrangementUndo.isEmpty)
            XCTAssertEqual(NSRectFromString(manager.photos[0].frameString), original)
            // Cancellation eases back; settle that transition before comparing the window.
            manager.cancelCollageInteractions()
            XCTAssertEqual(window.photoFrame, original)
        }
    }

    @MainActor
    func testWholeCollageDragUndoAndFailedCommit() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
            let before = manager.arrangementSnapshot(ids: ids)
            let window = try XCTUnwrap(manager.windows[parent.id])
            let original = window.photoFrame
            manager.moveCollage(parent.id, to: original.offsetBy(dx: 20, dy: 10), finished: false)
            XCTAssertFalse(manager.canUndoArrangement)
            manager.moveCollage(parent.id, to: window.photoFrame, finished: true)
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), before)
            try Data("corrupt".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.moveCollage(parent.id, to: original.offsetBy(dx: 25, dy: 0), finished: true)
            XCTAssertTrue(manager.arrangementUndo.isEmpty)
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), before)
        }
    }

    @MainActor
    func testCollageResizeUndoRestoresScaledAppearanceWithoutChangingContent() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
            let before = manager.arrangementSnapshot(ids: ids)
            let dimensions = Dictionary(uniqueKeysWithValues: manager.photos.map { ($0.id, WidgetScaledDimensions($0)) })
            XCTAssertNotNil(manager.beginCollageResize(parent.id))
            manager.resizeCollage(parent.id, scale: 1.3, corner: .bottomRight, finished: false)
            manager.resizeCollage(parent.id, scale: 1.3, corner: .bottomRight, finished: true)
            manager.cancelCollageInteractions()
            XCTAssertEqual(manager.arrangementUndo.count, 1)
            let childIndex = try XCTUnwrap(manager.photos.firstIndex { $0.collageParentID == parent.id })
            manager.photos[childIndex].customName = "Keep new name"
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), before)
            for item in manager.photos { XCTAssertEqual(WidgetScaledDimensions(item), dimensions[item.id]) }
            XCTAssertEqual(manager.photos[childIndex].customName, "Keep new name")
            XCTAssertTrue(manager.redoArrangement())
            manager.photos[childIndex].borderWidth += 2
            XCTAssertFalse(manager.undoArrangement(), "Do not overwrite a later border-size edit")
        }
    }

    @MainActor
    func testAttachTransferAndDetachUndoRestoreMembershipBoundsAndStacking() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let photo = try XCTUnwrap(manager.photos.first)
            let first = try XCTUnwrap(manager.addDesktopCollage())
            let second = try XCTUnwrap(manager.addDesktopCollage())
            let ids: Set<UUID> = [photo.id, first, second]
            let original = manager.arrangementSnapshot(ids: ids)
            let originalOrder = photo.stackOrder
            @MainActor func attach(to parent: UUID) throws {
                manager.beginCollageDrag(photo.id)
                // Candidate geometry is covered by DesktopCollageTests; exercise its commit.
                manager.collageDrags[photo.id]?.targetID = parent
                manager.collageDrags[photo.id]?.hasProposed = true
                let frame = try XCTUnwrap(manager.windows[parent]).photoFrame
                manager.windows[photo.id]?.setPhotoFrame(frame.insetBy(dx: 20, dy: 20))
                XCTAssertTrue(manager.finishCollageDrag(photo.id))
                manager.cancelCollageInteractions()
            }
            try attach(to: first)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), original)
            XCTAssertEqual(manager.photos.first { $0.id == photo.id }?.stackOrder, originalOrder)
            XCTAssertTrue(manager.redoArrangement())
            let inFirst = manager.arrangementSnapshot(ids: ids)
            try attach(to: second)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), inFirst)
            XCTAssertTrue(manager.redoArrangement())
            XCTAssertTrue(manager.removeFromCollage(photo.id))
            manager.cancelCollageInteractions()
            XCTAssertNil(manager.photos.first { $0.id == photo.id }?.collageParentID)
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertEqual(manager.photos.first { $0.id == photo.id }?.collageParentID, second)
            XCTAssertTrue(manager.redoArrangement())
            XCTAssertNil(manager.photos.first { $0.id == photo.id }?.collageParentID)
        }
    }

    @MainActor
    func testUndoDetachIntoHiddenCollageKeepsPhotoHidden() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
            manager.toggleVisibility(parent.id)
            XCTAssertNil(manager.windows[child.id])
            XCTAssertTrue(manager.removeFromCollage(child.id))
            manager.cancelCollageInteractions()
            XCTAssertNotNil(manager.windows[child.id])
            XCTAssertTrue(manager.undoArrangement())
            XCTAssertNil(manager.windows[child.id])
            XCTAssertEqual(manager.photos.first { $0.id == child.id }?.collageParentID, parent.id)
            XCTAssertTrue(manager.redoArrangement())
            XCTAssertNotNil(manager.windows[child.id])
        }
    }

    @MainActor
    func testInterveningMoveIsNotOverwrittenAndHistoryIsBounded() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let item = try XCTUnwrap(manager.photos.first)
            manager.selectedPhotoIDs = [item.id]
            for _ in 0..<55 { manager.nudgeSelected(.right) }
            XCTAssertEqual(manager.arrangementUndo.count, 50)
            let window = try XCTUnwrap(manager.windows[item.id])
            window.setPhotoFrame(window.photoFrame.offsetBy(dx: 20, dy: 0))
            XCTAssertFalse(manager.undoArrangement())
        }
    }
}
