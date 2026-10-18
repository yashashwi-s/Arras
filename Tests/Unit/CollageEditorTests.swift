import AppKit
import XCTest
@testable import Arras

final class CollageEditorTests: XCTestCase {
    @MainActor
    func testClosedEditorReleasesItsModelWhileTheClosedControllerIsRetained() throws {
        for makeEditor in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasClosedEditor-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            weak var model: PhotoManager?
            var retainedController: CollageEditorWindowController?
            try autoreleasepool {
                let manager = PhotoManager(storageDirectory: root)
                model = manager
                let id = try XCTUnwrap(manager.addDesktopCollage())
                if makeEditor {
                    var closed = 0
                    let editor = CollageEditorWindowController(manager: manager, id: id) { closed += 1 }
                    retainedController = editor
                    editor.requestClose()
                    XCTAssertEqual(closed, 1)
                }
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                manager.collageLabelWindows.values.forEach { $0.close() }
                manager.collageLabelWindows.removeAll()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            withExtendedLifetime(retainedController) {
                XCTAssertNil(model, "A closed collage editor must release its observed model; editor present=\(makeEditor)")
            }
        }
    }

    @MainActor
    func testUnchangedAndRevertedEditorsCloseWithoutPrompt() throws {
        try fixture { manager, id in
            var closed = 0
            let editor = controller(manager, id) { closed += 1 }
            editor.presentAlert = { _, _, _ in XCTFail("Unchanged editor should close immediately") }
            XCTAssertFalse(editor.hasUnsavedChanges)
            editor.window!.performClose(nil)
            XCTAssertEqual(closed, 1)
            XCTAssertNil(manager.collageAppearanceDrafts[id])
            editor.close()
            XCTAssertEqual(closed, 1)

            let reverted = controller(manager, id) { closed += 1 }
            let opening = reverted.editorDraft.settings
            reverted.editorDraft.settings.applyPreset(.ink)
            XCTAssertTrue(reverted.hasUnsavedChanges)
            reverted.editorDraft.settings = opening
            reverted.presentAlert = { _, _, _ in XCTFail("Reverted changes should not prompt") }
            reverted.close()
            XCTAssertEqual(closed, 2)
            XCTAssertNil(manager.collageAppearanceDrafts[id])
        }
    }

    @MainActor
    func testNativeCloseAsksOnceAndKeepEditingPreservesUnsavedDraft() throws {
        try fixture { manager, id in
            var closed = 0
            let editor = controller(manager, id) { closed += 1 }
            let file = manager.storageDir.appendingPathComponent("photos.json")
            let saved = try Data(contentsOf: file)
            editor.editorDraft.settings.applyPreset(.whitePolaroid)
            editor.editorDraft.settings.caption = "Not saved yet"
            preview(editor, manager, id)
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.window!.performClose(nil)
            editor.close()
            editor.requestClose()
            XCTAssertEqual(alerts.items.count, 1)
            XCTAssertEqual(alerts.items[0].alert.buttons.map(\.title), ["Apply", "Discard Changes", "Keep Editing"])
            XCTAssertEqual(alerts.items[0].alert.buttons[2].keyEquivalent, "\u{1b}")
            XCTAssertEqual(try Data(contentsOf: file), saved)
            XCTAssertEqual(closed, 0)
            alerts.respond(.alertThirdButtonReturn)
            XCTAssertNil(editor.activeAlert)
            XCTAssertTrue(editor.hasUnsavedChanges)
            XCTAssertEqual(editor.editorDraft.settings.caption, "Not saved yet")
            XCTAssertEqual((manager.windows[id] as! CollageDesktopWindow).settings.skin, .polaroid)
            XCTAssertNotNil(manager.collageAppearanceDrafts[id])
            XCTAssertEqual(try Data(contentsOf: file), saved)
            // The fixture's invalidation closes without asking or invoking a switch.
        }
    }

    @MainActor
    func testDiscardRestoresAppearanceAndPreservesCommittedMoveAndResize() throws {
        try fixture { manager, id in
            var closed = 0
            let editor = controller(manager, id) { closed += 1 }
            XCTAssertNotNil(manager.beginCollageResize(id))
            manager.resizeCollage(id, scale: 1.25, corner: .topRight, finished: true)
            settle(manager)
            let frame = manager.windows[id]!.photoFrame.offsetBy(dx: 45, dy: 28)
            manager.moveCollage(id, to: frame, finished: true)
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let committed = manager.photos
            editor.editorDraft.settings.applyPreset(.ink)
            editor.editorDraft.settings.caption = "Discard this"
            editor.editorDraft.settings.gap = 75
            editor.editorDraft.depth = .floating
            editor.editorDraft.isSpaceBound = true
            preview(editor, manager, id)
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.close()
            alerts.respond(.alertSecondButtonReturn)
            settle(manager)
            XCTAssertEqual(closed, 1)
            XCTAssertNil(manager.collageAppearanceDrafts[id])
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(manager.photos), try encoder.encode(committed))
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
            for item in committed { XCTAssertEqual(manager.windows[item.id]!.photoFrame, NSRectFromString(item.frameString)) }
            XCTAssertEqual((manager.windows[id] as! CollageDesktopWindow).settings, committed.first { $0.id == id }!.desktopCollage)
        }
    }

    @MainActor
    func testApplyFromClosePromptPersistsTypographyPlacementDepthAndSpaceTogether() throws {
        try fixture { manager, id in
            var closed = 0
            let editor = controller(manager, id) { closed += 1 }
            editor.editorDraft.settings.applyPreset(.whitePolaroid)
            editor.editorDraft.settings.caption = "A good day"
            editor.editorDraft.settings.gap = 38
            var label = CollageTextLabel(text: "Kept close")
            label.style.font = .editorial; label.style.fontSize = 31
            label.style.positionX = 0.24; label.style.positionY = 0.78
            editor.editorDraft.settings.labels = [label]
            editor.editorDraft.depth = .floating
            editor.editorDraft.isSpaceBound = true
            preview(editor, manager, id)
            let targets = try XCTUnwrap(manager.collageAppearanceLayout(id, settings: editor.editorDraft.settings))
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.requestClose()
            alerts.respond(.alertFirstButtonReturn)
            settle(manager)
            XCTAssertEqual(closed, 1)
            XCTAssertNil(manager.collageAppearanceDrafts[id])
            let stored = manager.photos.first { $0.id == id }!
            XCTAssertEqual(stored.desktopCollage, targets.settings)
            XCTAssertEqual(stored.depth, .floating)
            XCTAssertTrue(stored.isSpaceBound)
            XCTAssertEqual(manager.windows[id]!.photoFrame, targets.bounds)
            for (member, frame) in targets.frames { XCTAssertEqual(manager.windows[member]!.photoFrame, frame) }
            let decoded = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            XCTAssertEqual(decoded.first { $0.id == id }!.desktopCollage, targets.settings)
            XCTAssertEqual(decoded.first { $0.id == id }!.depth, .floating)
            XCTAssertTrue(decoded.first { $0.id == id }!.isSpaceBound)
        }
    }

    @MainActor
    func testFailedApplyKeepsDraftAndSavedSceneUntilUserDiscards() throws {
        try fixture { manager, id in
            var events: [String] = []
            let editor = controller(manager, id) { events.append("closed") }
            let original = manager.photos.first { $0.id == id }!
            let file = manager.storageDir.appendingPathComponent("photos.json")
            let saved = try Data(contentsOf: file)
            editor.editorDraft.settings.caption = "Still editable"
            editor.editorDraft.settings.applyPreset(.ink)
            preview(editor, manager, id)
            // Replace only the isolated fixture's destination with a directory.
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.requestClose(onClosed: { events.append("next editor") })
            alerts.respond(.alertFirstButtonReturn)
            XCTAssertEqual(alerts.items.count, 2)
            XCTAssertEqual(alerts.items[1].alert.messageText, "Couldn’t Save Collage")
            XCTAssertTrue(events.isEmpty)
            XCTAssertEqual(manager.photos.first { $0.id == id }!.desktopCollage, original.desktopCollage)
            XCTAssertEqual(editor.editorDraft.settings.caption, "Still editable")
            XCTAssertNotNil(manager.collageAppearanceDrafts[id])
            alerts.respond(.alertFirstButtonReturn, at: 1)
            try FileManager.default.removeItem(at: file)
            try saved.write(to: file)
            editor.close()
            alerts.respond(.alertSecondButtonReturn, at: 2)
            XCTAssertEqual(events, ["closed"])
            XCTAssertEqual(try Data(contentsOf: file), saved)
        }
    }

    @MainActor
    func testDepthAndSpaceChangesAloneRequireConfirmation() throws {
        try fixture { manager, id in
            let editor = controller(manager, id) {}
            editor.editorDraft.depth = .floating
            XCTAssertTrue(editor.hasUnsavedChanges)
            editor.editorDraft.depth = manager.photos.first { $0.id == id }!.depth
            XCTAssertFalse(editor.hasUnsavedChanges)
            editor.editorDraft.isSpaceBound.toggle()
            XCTAssertTrue(editor.hasUnsavedChanges)
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.close()
            XCTAssertEqual(alerts.items.count, 1)
            alerts.respond(.alertSecondButtonReturn)
        }
    }

    @MainActor
    func testCommittedResizeAndUnusedCaptionMetadataDoNotCountAsEdits() throws {
        try fixture { manager, id in
            let editor = controller(manager, id) {}
            XCTAssertNotNil(manager.beginCollageResize(id))
            manager.resizeCollage(id, scale: 1.3, corner: .bottomLeft, finished: true)
            editor.editorDraft.settings.freeCaptionBandHeight = 84
            XCTAssertFalse(editor.hasUnsavedChanges)
            editor.presentAlert = { _, _, _ in XCTFail("Saved resizing and unused strip metadata should not prompt") }
            editor.close()
        }
    }

    @MainActor
    func testSwitchingEditorWaitsForActualCloseAndKeepEditingCancelsSwitch() throws {
        try fixture { manager, id in
            var events: [String] = []
            let editor = controller(manager, id) { events.append("closed") }
            editor.editorDraft.settings.caption = "Unsaved"
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.requestClose(onClosed: { events.append("cancelled switch") })
            alerts.respond(.alertThirdButtonReturn)
            XCTAssertTrue(events.isEmpty)
            editor.requestClose(onClosed: { events.append("next editor") })
            alerts.respond(.alertSecondButtonReturn, at: 1)
            XCTAssertEqual(events, ["closed", "next editor"])
            alerts.respond(.alertFirstButtonReturn, at: 1)
            XCTAssertEqual(events, ["closed", "next editor"])
        }
    }

    @MainActor
    func testInvalidationCancelsPendingPromptAndIgnoresLateApply() throws {
        try fixture { manager, id in
            var closed = 0
            var switched = false
            let editor = controller(manager, id) { closed += 1 }
            let original = manager.photos.first { $0.id == id }!.desktopCollage
            editor.editorDraft.settings.caption = "Must not apply"
            let alerts = Alerts()
            editor.presentAlert = alerts.present
            editor.requestClose(onClosed: { switched = true })
            manager.cancelCollageInteractions(endAppearancePreviews: true)
            XCTAssertEqual(closed, 1)
            XCTAssertNil(editor.activeAlert)
            XCTAssertFalse(switched)
            alerts.respond(.alertFirstButtonReturn)
            XCTAssertEqual(manager.photos.first { $0.id == id }!.desktopCollage, original)
            XCTAssertNil(manager.collageAppearanceDrafts[id])
            XCTAssertEqual(closed, 1)
        }
    }

    @MainActor
    func testCloseWaitsForLabelSheetAndRechecksCancelledEdits() throws {
        try fixture { manager, id in
            var closed = 0
            let editor = controller(manager, id) { closed += 1 }
            let opening = editor.editorDraft.settings
            editor.editorDraft.settings.caption = "Cancelled by wizard"
            editor.presentAlert = { _, _, _ in XCTFail("Cancelling the sheet reverted every edit") }
            let sheet = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            editor.window!.beginSheet(sheet)
            XCTAssertNotNil(editor.window!.attachedSheet)
            editor.requestClose()
            XCTAssertEqual(closed, 0)
            editor.editorDraft.settings = opening
            editor.window!.endSheet(sheet)
            sheet.orderOut(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            XCTAssertEqual(closed, 1)
            XCTAssertNil(manager.collageAppearanceDrafts[id])
        }
    }

    @MainActor
    private final class Alerts {
        struct Item {
            let alert: NSAlert
            let completion: (NSApplication.ModalResponse) -> Void
        }
        var items: [Item] = []
        func present(_ alert: NSAlert, _ window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
            items.append(Item(alert: alert, completion: completion))
        }
        func respond(_ response: NSApplication.ModalResponse, at index: Int = 0) {
            guard items.indices.contains(index) else { XCTFail("Expected a confirmation alert"); return }
            items[index].completion(response)
        }
    }

    @MainActor
    private func controller(_ manager: PhotoManager, _ id: UUID, onClose: @escaping () -> Void) -> CollageEditorWindowController {
        let editor = CollageEditorWindowController(manager: manager, id: id, onClose: onClose)
        editor.window!.level = WidgetDepth.onDesktop.windowLevel
        editor.window!.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        return editor
    }

    @MainActor
    private func preview(_ editor: CollageEditorWindowController, _ manager: PhotoManager, _ id: UUID) {
        manager.previewCollageAppearance(id, session: manager.collageAppearanceDrafts[id]!.session, settings: editor.editorDraft.settings)
        settle(manager)
    }

    @MainActor
    private func settle(_ manager: PhotoManager) {
        for flight in Array(manager.collageFlights.values) { flight.currentProgress = 1 }
        for window in manager.windows.values.compactMap({ $0 as? CollageDesktopWindow }) { window.transition?.currentProgress = 1 }
    }

    @MainActor
    private func fixture(_ body: (PhotoManager, UUID) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollageEditor-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: directory)
        defer {
            manager.cancelCollageInteractions(endAppearancePreviews: true)
            manager.windows.values.forEach { $0.hidePhoto() }; manager.windows.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
        let id = try XCTUnwrap(manager.addDesktopCollage())
        for frame in [CGRect(x: 80, y: 160, width: 160, height: 220), CGRect(x: 260, y: 160, width: 220, height: 160)] {
            let image = NSImage(size: frame.size, flipped: false) { bounds in NSColor.systemTeal.setFill(); bounds.fill(); return true }
            var item = PhotoItem(filename: UUID().uuidString + ".png", width: frame.width)
            item.frameString = NSStringFromRect(frame); item.collageParentID = id
            try StarterArtwork.pngData(for: image).write(to: directory.appendingPathComponent(item.filename))
            manager.photos.append(item)
            manager.createWindow(for: item, content: .still(image))
        }
        var settings = manager.photos.first { $0.id == id }!.desktopCollage!
        settings.caption = "A memory"
        XCTAssertTrue(manager.applyCollageSettings(id, settings: settings))
        settle(manager)
        try body(manager, id)
    }
}
