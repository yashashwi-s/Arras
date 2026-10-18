import XCTest
import AppKit
@testable import Arras

final class WidgetSelectionTests: XCTestCase {
    @MainActor
    func testAppearancePastePreservesUnrelatedCollageInteractionOnSuccessAndSaveFailure() throws {
        for interaction in ["photo-drag", "group-drag", "group-resize", "draft"] {
            for saveFails in [false, true] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.minimal))
                    let source = try XCTUnwrap(manager.photos.first?.id)
                    manager.setMat(source, width: 28, colorHex: "#EEE4D3")
                    XCTAssertTrue(manager.addStarterExample(.minimal))
                    let target = try XCTUnwrap(manager.photos.first { $0.id != source }?.id)
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                    let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                    switch interaction {
                    case "photo-drag":
                        manager.beginCollageDrag(child.id)
                        let photo = try XCTUnwrap(manager.windows[child.id])
                        photo.setPhotoFrame(photo.photoFrame.offsetBy(dx: 17, dy: 11))
                    case "group-drag":
                        manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 17, dy: 11), finished: false)
                    case "group-resize":
                        XCTAssertNotNil(manager.beginCollageResize(parent.id))
                        manager.resizeCollage(parent.id, scale: 1.1, corner: .bottomRight, finished: false)
                    default:
                        let session = UUID()
                        manager.beginCollageAppearancePreview(parent.id, session: session)
                        var draft = try XCTUnwrap(parent.desktopCollage)
                        draft.gap += 30
                        draft.caption = "Keep this unsaved preview"
                        manager.previewCollageAppearance(parent.id, session: session, settings: draft)
                        manager.collageFlights.values.forEach { $0.currentProgress = 0.4 }
                        surface.transition?.currentProgress = 0.4
                    }
                    let groupIDs = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
                    let frames = Dictionary(uniqueKeysWithValues: groupIDs.compactMap { id in
                        manager.windows[id].map { (id, $0.photoFrame) }
                    })
                    let groupWindows = manager.windows.filter { groupIDs.contains($0.key) }
                    let flights = manager.collageFlights
                    let interactions = [Set(manager.collageDrags.keys), Set(manager.collageMoveSnapshots.keys),
                                        Set(manager.collageResizeSnapshots.keys), Set(manager.collageAppearanceDrafts.keys)]
                    let draftSession = manager.collageAppearanceDrafts[parent.id]?.session
                    let settings = surface.settings
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    let model = try encoder.encode(manager.photos)
                    let groupModel = try encoder.encode(manager.photos.filter { groupIDs.contains($0.id) })
                    let store = manager.storageDir.appendingPathComponent("photos.json")
                    if saveFails { try Data("protected invalid store".utf8).write(to: store) }
                    let stored = try Data(contentsOf: store)
                    XCTAssertTrue(manager.copyAppearance(of: source))
                    manager.selectedPhotoIDs = [target]
                    XCTAssertTrue(manager.canPasteSelectedAppearance)

                    XCTAssertEqual(manager.pasteSelectedStyle(), !saveFails)

                    let context = "\(interaction), save fails: \(saveFails)"
                    XCTAssertEqual([Set(manager.collageDrags.keys), Set(manager.collageMoveSnapshots.keys),
                                    Set(manager.collageResizeSnapshots.keys), Set(manager.collageAppearanceDrafts.keys)],
                                   interactions, context)
                    XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, draftSession, context)
                    XCTAssertEqual(surface.settings, settings, context)
                    XCTAssertEqual(try encoder.encode(manager.photos.filter { groupIDs.contains($0.id) }), groupModel, context)
                    XCTAssertEqual(Set(manager.collageFlights.keys), Set(flights.keys), context)
                    for (id, flight) in flights { XCTAssertTrue(manager.collageFlights[id] === flight, context) }
                    for (id, frame) in frames { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, context) }
                    for (id, window) in groupWindows { XCTAssertTrue(manager.windows[id] === window, context) }
                    if saveFails {
                        XCTAssertEqual(try encoder.encode(manager.photos), model, context)
                        XCTAssertEqual(try Data(contentsOf: store), stored, context)
                    } else {
                        let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store))
                        XCTAssertEqual(saved.first { $0.id == target }?.matWidth, 28, context)
                        XCTAssertEqual(manager.photos.first { $0.id == target }?.matWidth, 28, context)
                    }
                }
            }
        }
    }

    @MainActor
    func testAppearancePasteWaitsForAffectedCollageDraftDragResizeAndReturnMotion() throws {
        for interaction in ["draft", "photo-drag", "group-drag", "group-resize", "return-motion"] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.minimal))
                let source = try XCTUnwrap(manager.photos.first?.id)
                manager.setMat(source, width: 28, colorHex: "#EEE4D3")
                XCTAssertTrue(manager.addStarterExample(.galleryWall))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                let surface = try XCTUnwrap(manager.windows[parent.id])
                switch interaction {
                case "draft":
                    let session = UUID()
                    manager.beginCollageAppearancePreview(parent.id, session: session)
                    var draft = try XCTUnwrap(parent.desktopCollage)
                    draft.caption = "Unsaved collage"
                    manager.previewCollageAppearance(parent.id, session: session, settings: draft)
                case "photo-drag":
                    manager.beginCollageDrag(child.id)
                    let photo = try XCTUnwrap(manager.windows[child.id])
                    photo.setPhotoFrame(photo.photoFrame.offsetBy(dx: 17, dy: 11))
                case "group-drag":
                    manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 17, dy: 11), finished: false)
                case "group-resize":
                    XCTAssertNotNil(manager.beginCollageResize(parent.id))
                    manager.resizeCollage(parent.id, scale: 1.1, corner: .bottomRight, finished: false)
                default:
                    let photo = try XCTUnwrap(manager.windows[child.id])
                    manager.animateCollagePhoto(child.id, to: photo.photoFrame.offsetBy(dx: 17, dy: 11), duration: 1)
                    manager.collageFlights[child.id]?.currentProgress = 0.4
                }
                let frames = manager.windows.mapValues(\.photoFrame)
                let interactions = [Set(manager.collageDrags.keys), Set(manager.collageMoveSnapshots.keys),
                                    Set(manager.collageResizeSnapshots.keys), Set(manager.collageAppearanceDrafts.keys),
                                    Set(manager.collageFlights.keys)]
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let model = try encoder.encode(manager.photos)
                let store = manager.storageDir.appendingPathComponent("photos.json")
                let stored = try Data(contentsOf: store)
                XCTAssertTrue(manager.copyAppearance(of: source))
                manager.selectedPhotoIDs = [child.id]

                XCTAssertFalse(manager.canPasteSelectedAppearance, interaction)
                XCTAssertFalse(manager.pasteSelectedStyle(), interaction)

                XCTAssertEqual(try encoder.encode(manager.photos), model, interaction)
                XCTAssertEqual(try Data(contentsOf: store), stored, interaction)
                XCTAssertEqual(manager.windows.mapValues(\.photoFrame), frames, interaction)
                XCTAssertEqual([Set(manager.collageDrags.keys), Set(manager.collageMoveSnapshots.keys),
                                Set(manager.collageResizeSnapshots.keys), Set(manager.collageAppearanceDrafts.keys),
                                Set(manager.collageFlights.keys)], interactions, interaction)

                switch interaction {
                case "draft": manager.endCollageAppearancePreview(parent.id, animated: false)
                case "photo-drag": XCTAssertTrue(manager.finishCollageDrag(child.id))
                case "group-drag": manager.moveCollage(parent.id, to: surface.photoFrame, finished: true)
                case "group-resize": manager.resizeCollage(parent.id, scale: 1.1, corner: .bottomRight, finished: true)
                default: manager.collageFlights[child.id]?.currentProgress = 1
                }
                manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                (surface as? CollageDesktopWindow)?.transition?.currentProgress = 1
                XCTAssertTrue(manager.canPasteSelectedAppearance, interaction)
                XCTAssertTrue(manager.pasteSelectedStyle(), interaction)
                let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store))
                XCTAssertEqual(saved.first { $0.id == child.id }?.matWidth, 28, interaction)
            }
        }
    }

    @MainActor
    func testArrangementCommandsPreserveUnrelatedCollageDraftOnSuccessAndSaveFailure() throws {
        for command in ["nudge", "align", "distribute"] {
            for saveFails in [false, true] {
                try withTestLibrary { manager in
                    let screen = try XCTUnwrap(NSScreen.main).visibleFrame
                    var selected: Set<UUID> = []
                    for fraction in [CGFloat(0.1), 0.3, 0.7] {
                        let existing = Set(manager.photos.map(\.id))
                        XCTAssertTrue(manager.addStarterExample(.minimal))
                        let id = try XCTUnwrap(manager.photos.first { !existing.contains($0.id) }?.id)
                        let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == id })
                        let frame = NSRect(x: screen.minX + screen.width * fraction,
                                           y: screen.minY + screen.height * 0.3,
                                           width: min(100, screen.width * 0.08), height: 80)
                        manager.windows[id]?.setPhotoFrame(frame)
                        manager.photos[index].frameString = NSStringFromRect(frame)
                        manager.photos[index].widgetWidth = frame.width
                        selected.insert(id)
                    }
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let groupIDs = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
                    XCTAssertTrue(manager.persist())
                    let session = UUID()
                    manager.beginCollageAppearancePreview(parent.id, session: session)
                    var draft = try XCTUnwrap(parent.desktopCollage)
                    draft.gap += 30
                    draft.caption = "Unsaved " + command
                    manager.previewCollageAppearance(parent.id, session: session, settings: draft)
                    manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                    let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                    surface.transition?.currentProgress = 1
                    let preview = manager.arrangementSnapshot(ids: groupIDs)
                    let groupWindows = manager.windows.filter { groupIDs.contains($0.key) }
                    let label = try XCTUnwrap(manager.collageLabelWindows[parent.id])
                    manager.selectedPhotoIDs = selected
                    XCTAssertTrue(manager.canAlignSelection)
                    XCTAssertTrue(manager.canDistributeSelection(.horizontally))
                    let selectedBefore = manager.arrangementSnapshot(ids: selected)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    let modelBefore = try encoder.encode(manager.photos)
                    let activeURL = manager.storageDir.appendingPathComponent("photos.json")
                    if saveFails { try Data("damaged active store".utf8).write(to: activeURL) }
                    let storedBefore = try Data(contentsOf: activeURL)

                    switch command {
                    case "nudge": manager.nudgeSelected(.right)
                    case "align": XCTAssertEqual(manager.alignSelected(.left), !saveFails)
                    default: XCTAssertEqual(manager.distributeSelected(.horizontally), !saveFails)
                    }

                    let context = "\(command), save fails: \(saveFails)"
                    XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, session, context)
                    XCTAssertEqual(surface.settings.caption, draft.caption, context)
                    XCTAssertEqual(manager.arrangementSnapshot(ids: groupIDs), preview, context)
                    for (id, window) in groupWindows { XCTAssertTrue(manager.windows[id] === window, context) }
                    XCTAssertTrue(manager.collageLabelWindows[parent.id] === label, context)
                    if saveFails {
                        XCTAssertEqual(try encoder.encode(manager.photos), modelBefore, context)
                        XCTAssertEqual(try Data(contentsOf: activeURL), storedBefore, context)
                        XCTAssertEqual(manager.arrangementSnapshot(ids: selected), selectedBefore, context)
                        XCTAssertTrue(manager.arrangementUndo.isEmpty, context)
                    } else {
                        XCTAssertNotEqual(manager.arrangementSnapshot(ids: selected), selectedBefore, context)
                        XCTAssertEqual(manager.arrangementUndo.count, 1, context)
                        let stored = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: activeURL))
                        XCTAssertEqual(stored.first { $0.id == parent.id }?.desktopCollage, parent.desktopCollage, context)
                    }
                }
            }
        }
    }

    @MainActor
    func testNudgeWaitsForAffectedCollageDraftDragAndResize() throws {
        for interaction in ["draft", "photo-drag", "group-drag", "group-resize"] {
            for selectingParent in [false, true] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                    let window = try XCTUnwrap(manager.windows[parent.id])
                    switch interaction {
                    case "draft":
                        let session = UUID()
                        manager.beginCollageAppearancePreview(parent.id, session: session)
                        var draft = try XCTUnwrap(parent.desktopCollage)
                        draft.caption = "Unsaved arrangement"
                        manager.previewCollageAppearance(parent.id, session: session, settings: draft)
                    case "photo-drag":
                        manager.beginCollageDrag(child.id)
                        let photo = try XCTUnwrap(manager.windows[child.id])
                        photo.setPhotoFrame(photo.photoFrame.offsetBy(dx: 15, dy: 10))
                    case "group-drag":
                        manager.moveCollage(parent.id, to: window.photoFrame.offsetBy(dx: 15, dy: 10), finished: false)
                    default:
                        XCTAssertNotNil(manager.beginCollageResize(parent.id))
                        manager.resizeCollage(parent.id, scale: 1.1, corner: .bottomRight, finished: false)
                    }
                    let ids = Set(manager.photos.map(\.id))
                    let placement = manager.arrangementSnapshot(ids: ids)
                    let interactions = [Set(manager.collageDrags.keys), Set(manager.collageMoveSnapshots.keys),
                                        Set(manager.collageResizeSnapshots.keys), Set(manager.collageAppearanceDrafts.keys)]
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    let model = try encoder.encode(manager.photos)
                    let storedURL = manager.storageDir.appendingPathComponent("photos.json")
                    let stored = try Data(contentsOf: storedURL)
                    manager.selectedPhotoIDs = [selectingParent ? parent.id : child.id]
                    XCTAssertTrue(manager.hasActiveArrangementInteraction)

                    manager.nudgeSelected(.right)

                    let context = "\(interaction), selecting parent: \(selectingParent)"
                    XCTAssertEqual(manager.arrangementSnapshot(ids: ids), placement, context)
                    XCTAssertEqual(try encoder.encode(manager.photos), model, context)
                    XCTAssertEqual(try Data(contentsOf: storedURL), stored, context)
                    XCTAssertEqual([Set(manager.collageDrags.keys), Set(manager.collageMoveSnapshots.keys),
                                    Set(manager.collageResizeSnapshots.keys), Set(manager.collageAppearanceDrafts.keys)],
                                   interactions, context)
                    XCTAssertTrue(manager.arrangementUndo.isEmpty, context)
                }
            }
        }
    }

    @MainActor
    func testFailedDoubleClickActionSavePreservesTheNativeSlideshowAction() throws {
        for grouped in [false, true] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
                let id = try XCTUnwrap(manager.photos.first?.id)
                manager.setRotationInterval(id, "click")
                var parent: UUID?
                if grouped {
                    parent = try XCTUnwrap(manager.addDesktopCollage())
                    let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == id })
                    manager.photos[index].collageParentID = parent
                    manager.syncCollages()
                    XCTAssertTrue(manager.persist())
                }
                let window = try XCTUnwrap(manager.windows[id])
                let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
                let initialImage = try XCTUnwrap(view.photoLayer.layer.contents as AnyObject?)
                let store = manager.storageDir.appendingPathComponent("photos.json")
                let stored = try Data(contentsOf: store)
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }

                manager.setClickAction(id, .quickLook)

                XCTAssertEqual(try Data(contentsOf: store), stored)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path)
                guard manager.photos.first(where: { $0.id == id })?.clickAction == .advance else {
                    XCTFail("Refused action change reached the live model; stop before dispatching a Quick Look panel")
                    return
                }
                let center = CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
                view.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: center, clicks: 2))
                view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: center, clicks: 2))
                let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store))
                let photo = try XCTUnwrap(saved.first { $0.id == id })
                XCTAssertEqual(photo.folderImageIndex, 1, "The retained native double-click action should advance normally")
                XCTAssertEqual(photo.clickAction, .advance)
                XCTAssertEqual(photo.collageParentID, parent)
                XCTAssertFalse((view.photoLayer.layer.contents as AnyObject?) === initialImage)
                XCTAssertTrue(manager.windows[id] === window)
                manager.setClickAction(id, .quickLook)
                let edited = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store))
                XCTAssertEqual(edited.first { $0.id == id }?.clickAction, .quickLook,
                               "A later successful save should still change the action")
            }
        }
    }

    @MainActor
    func testSelectedCollageNudgeMovesChildrenAndAllSlideshowFramesOnlyOnce() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let child = try XCTUnwrap(manager.photos.first)
            let parent = try XCTUnwrap(manager.addDesktopCollage())
            let i = try XCTUnwrap(manager.photos.firstIndex { $0.id == child.id })
            manager.photos[i].collageParentID = parent
            let frame = manager.windows[child.id]!.photoFrame
            manager.photos[i].frameString = NSStringFromRect(frame)
            manager.photos[i].folderImageConfigs["another.png"] = FolderImageConfig(frameString: NSStringFromRect(frame.offsetBy(dx: 15, dy: 20)), widgetWidth: frame.width)
            manager.syncCollages(); manager.selectedPhotoIDs = [parent, child.id]
            let before = manager.photos
            let parentFrame = manager.windows[parent]!.photoFrame
            manager.nudgeSelected(.right, modifiers: [.shift])
            let delta = manager.windows[parent]!.photoFrame.minX - parentFrame.minX
            XCTAssertEqual(delta, 10)
            XCTAssertEqual(manager.windows[child.id]!.photoFrame.minX, frame.minX + delta)
            let current = try XCTUnwrap(manager.photos.first { $0.id == child.id })
            XCTAssertEqual(NSRectFromString(current.folderImageConfigs["another.png"]!.frameString).minX, frame.minX + 15 + delta)
            // Force the durable write to fail, then verify the complete scene rolls back.
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let saved = try encoder.encode(manager.photos)
            let savedParent = manager.windows[parent]!.photoFrame
            let savedChild = manager.windows[child.id]!.photoFrame
            manager.nudgeSelected(.down)
            XCTAssertEqual(try encoder.encode(manager.photos), saved)
            XCTAssertEqual(manager.windows[parent]!.photoFrame, savedParent)
            XCTAssertEqual(manager.windows[child.id]!.photoFrame, savedChild)
            XCTAssertEqual(manager.photos.count, before.count)
        }
    }

    @MainActor
    func testAppearancePasteSupportsHiddenLockedPhotosAndPreservesContentAndFraming() throws {
        try withTestLibrary { manager in
            var source = PhotoItem(filename: "source.png")
            source.matWidth = 32; source.opacity = 0.4
            source.focalPoint = NormalizedFocalPoint(x: 0, y: 0)
            var target = PhotoItem(filename: "target.png")
            target.isVisible = false; target.isLocked = true
            target.frameString = "{{100,200},{120,80}}"
            target.focalPoint = NormalizedFocalPoint(x: 1, y: 1)
            var parent = PhotoItem(filename: "")
            parent.desktopCollage = DesktopCollageSettings()
            target.collageParentID = parent.id
            manager.photos = [source, target, parent]
            XCTAssertTrue(manager.persist())
            XCTAssertTrue(manager.copyAppearance(of: source.id))
            manager.selectedPhotoIDs = [target.id, parent.id]
            XCTAssertTrue(manager.canPasteSelectedAppearance)
            XCTAssertTrue(manager.pasteSelectedStyle())
            let result = manager.photos[1]
            XCTAssertEqual(result.matWidth, 32)
            XCTAssertEqual(result.opacity, 0.4)
            XCTAssertEqual(result.focalPoint, target.focalPoint)
            XCTAssertEqual(result.frameString, target.frameString)
            XCTAssertEqual(result.filename, target.filename)
            XCTAssertEqual(result.collageParentID, parent.id)
            XCTAssertTrue(result.isLocked)
            XCTAssertFalse(result.isVisible)
            XCTAssertNil(manager.windows[target.id])
            XCTAssertEqual(manager.photos[2].matWidth, parent.matWidth)
            XCTAssertFalse(manager.copyAppearance(of: parent.id))
        }
    }

    @MainActor
    func testAppearancePasteFailureRestoresCompleteModel() throws {
        try withTestLibrary { manager in
            var source = PhotoItem(filename: "source.png"); source.matWidth = 40
            let target = PhotoItem(filename: "target.png")
            manager.photos = [source, target]
            XCTAssertTrue(manager.copyAppearance(of: source.id))
            try Data("invalid store".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertFalse(manager.pasteAppearance(to: [target.id]))
            XCTAssertEqual(manager.photos[1].matWidth, target.matWidth)
            XCTAssertEqual(try String(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), "invalid store")
        }
    }

    @MainActor
    func testSearchFindsCollageChildrenAndExplainsInheritedVisibility() throws {
        try withTestLibrary { manager in
            var parent = PhotoItem(filename: "")
            parent.desktopCollage = DesktopCollageSettings(); parent.customName = "Travel"
            var child = PhotoItem(filename: "image.png")
            child.customName = "Mountain"; child.collageParentID = parent.id
            manager.photos = [parent, child]
            XCTAssertEqual(manager.filteredWidgetRoots(query: "mount", filter: .all).map(\.id), [parent.id])
            XCTAssertTrue(manager.filteredWidgetRoots(query: "missing", filter: .all).isEmpty)
            manager.photos[0].isVisible = false
            XCTAssertEqual(manager.visibilityExplanation(for: child), "Hidden with collage")
            XCTAssertEqual(manager.filteredWidgetRoots(query: "mount", filter: .hidden).map(\.id), [parent.id])
            XCTAssertTrue(manager.filteredWidgetRoots(query: "", filter: .visible).isEmpty)
            child.isVisible = false
            XCTAssertEqual(manager.visibilityExplanation(for: child), "Hidden by you")
        }
    }

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


    func testSelectionSupportsCommandToggleAndShiftRange() {
        let ids = (0..<4).map { _ in UUID() }

        let first = WidgetSelectionLogic.selection(
            orderedIDs: ids,
            currentIDs: [],
            anchorID: nil,
            clickedID: ids[1],
            modifiers: []
        )
        XCTAssertEqual(first.selectedIDs, [ids[1]])

        let toggled = WidgetSelectionLogic.selection(
            orderedIDs: ids,
            currentIDs: first.selectedIDs,
            anchorID: first.anchorID,
            clickedID: ids[3],
            modifiers: [.command]
        )
        XCTAssertEqual(toggled.selectedIDs, [ids[1], ids[3]])

        let ranged = WidgetSelectionLogic.selection(
            orderedIDs: ids,
            currentIDs: toggled.selectedIDs,
            anchorID: toggled.anchorID,
            clickedID: ids[0],
            modifiers: [.shift]
        )
        XCTAssertEqual(ranged.selectedIDs, [ids[0], ids[1], ids[2], ids[3]])
    }

    func testAlignmentUsesVisibleEdgesAndPreservesSize() {
        let first = WidgetGeometryItem(
            id: UUID(),
            photoFrame: CGRect(x: 10, y: 20, width: 100, height: 80),
            visualFrame: CGRect(x: 0, y: 20, width: 120, height: 80)
        )
        let second = WidgetGeometryItem(
            id: UUID(),
            photoFrame: CGRect(x: 300, y: 40, width: 60, height: 60),
            visualFrame: CGRect(x: 290, y: 40, width: 80, height: 60)
        )

        let deltas = WidgetSelectionGeometry.alignmentDeltas([first, second], alignment: .left)
        XCTAssertEqual(deltas[first.id]?.x, 0)
        XCTAssertEqual(deltas[second.id]?.x, -290)
        XCTAssertEqual(deltas[first.id]?.y, 0)
        XCTAssertEqual(deltas[second.id]?.y, 0)
    }

    func testDistributionKeepsOuterEdgesAndEqualizesGaps() {
        let items = [
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 0, y: 0, width: 20, height: 20)),
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 50, y: 0, width: 10, height: 20)),
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 140, y: 0, width: 20, height: 20))
        ]

        let deltas = WidgetSelectionGeometry.distributionDeltas(items, distribution: .horizontally)
        XCTAssertEqual(deltas[items[0].id]?.x, 0)
        XCTAssertEqual(deltas[items[1].id]?.x, 25)
        XCTAssertEqual(deltas[items[2].id]?.x, 0)
    }

    func testDistributionDoesNotCreateMoreOverlapWhenThereIsNoRoomForGaps() {
        let items = [
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 0, y: 0, width: 80, height: 20)),
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 20, y: 0, width: 80, height: 20)),
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 100, y: 0, width: 80, height: 20))
        ]

        XCTAssertEqual(
            WidgetSelectionGeometry.distributionDeltas(items, distribution: .horizontally),
            [:]
        )
    }

    func testVerticalDistributionDoesNotCreateMoreOverlapWhenThereIsNoRoomForGaps() {
        let items = [
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 0, y: 0, width: 20, height: 80)),
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 0, y: 20, width: 20, height: 80)),
            WidgetGeometryItem(id: UUID(), photoFrame: .zero, visualFrame: CGRect(x: 0, y: 100, width: 20, height: 80))
        ]

        XCTAssertEqual(
            WidgetSelectionGeometry.distributionDeltas(items, distribution: .vertically),
            [:]
        )
    }

    func testVisibleFootprintIncludesMatAndTiltAroundItsCenter() {
        // `frame` is the already-expanded mat boundary supplied by DesktopPhotoWindow.
        let footprint = WidgetSelectionGeometry.visibleFootprint(
            CGRect(x: 40, y: 80, width: 120, height: 60),
            tiltDegrees: 90
        )

        XCTAssertEqual(footprint.midX, 100, accuracy: 0.0001)
        XCTAssertEqual(footprint.midY, 110, accuracy: 0.0001)
        XCTAssertEqual(footprint.width, 60, accuracy: 0.0001)
        XCTAssertEqual(footprint.height, 120, accuracy: 0.0001)
        let reversed = WidgetSelectionGeometry.visibleFootprint(
            CGRect(x: 40, y: 80, width: 120, height: 60), tiltDegrees: 270
        )
        XCTAssertEqual(reversed.width, 60, accuracy: 0.0001)
        XCTAssertEqual(reversed.height, 120, accuracy: 0.0001)
    }

    @MainActor
    func testLockedViewStillForwardsDoubleClickAction() throws {
        let view = DraggablePhotoView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 80),
            content: .still(interactionTestImage()),
            locked: true,
            canvasInset: 0
        )
        var actionCount = 0
        view.onClickAction = { actionCount += 1 }

        try view.mouseDown(with: mouseEvent(type: .leftMouseDown, clickCount: 2))

        XCTAssertEqual(actionCount, 1)
    }

    @MainActor
    func testLockedViewDoesNotMoveWhenDragged() throws {
        let window = DesktopPhotoWindow()
        let view = DraggablePhotoView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 80),
            content: .still(interactionTestImage()),
            locked: true,
            canvasInset: 0
        )
        window.contentView = view
        let original = CGRect(x: 120, y: 180, width: 120, height: 80)
        window.setPhotoFrame(original, display: false)
        defer { window.orderOut(nil) }

        try view.mouseDown(with: mouseEvent(type: .leftMouseDown, clickCount: 1, window: window))
        try view.mouseDragged(with: mouseEvent(
            type: .leftMouseDragged,
            clickCount: 1,
            window: window,
            location: CGPoint(x: 80, y: 40)
        ))

        XCTAssertEqual(window.photoFrame, original)
    }

    @MainActor
    func testLockedSlideshowAdvanceRemainsAvailableButHiddenAndBehindIconsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasLockedClick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "one.jpg")
        item.isVisible = true
        item.isLocked = true
        item.spaceImageFilenames = ["one.jpg", "two.jpg", "three.jpg"]
        let image = interactionTestImage()
        for name in item.spaceImageFilenames {
            try XCTUnwrap(image.tiffRepresentation).write(to: directory.appendingPathComponent(name))
        }
        item.clickAction = .advance
        item.depth = .onDesktop
        manager.photos = [item]
        manager.spaceImages[item.id] = item.spaceImageFilenames.map { directory.appendingPathComponent($0) }

        manager.performClickAction(item.id)
        let advancedStep = try XCTUnwrap(manager.photos.first?.folderImageIndex)
        XCTAssertNotEqual(advancedStep, 0, "Locking protects placement, not a configured action.")

        manager.photos[0].isHiddenForPresence = true
        manager.performClickAction(item.id)
        XCTAssertEqual(manager.photos[0].folderImageIndex, advancedStep)

        manager.photos[0].isHiddenForPresence = false
        manager.photos[0].depth = .behindIcons
        manager.performClickAction(item.id)
        XCTAssertEqual(manager.photos[0].folderImageIndex, advancedStep)
    }

    func testFocalCropMovesTheVisibleSourceRectangleWithoutChangingItsAspect() {
        let centered = PhotoCropGeometry.contentsRect(
            sourceSize: CGSize(width: 1600, height: 900),
            targetSize: CGSize(width: 400, height: 400)
        )
        let rightFocused = PhotoCropGeometry.contentsRect(
            sourceSize: CGSize(width: 1600, height: 900),
            targetSize: CGSize(width: 400, height: 400),
            focalPoint: NormalizedFocalPoint(x: 1, y: 0.5)
        )

        XCTAssertEqual(centered.width, 0.5625, accuracy: 0.0001)
        XCTAssertEqual(centered.minX, 0.21875, accuracy: 0.0001)
        XCTAssertEqual(rightFocused.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(rightFocused.width, centered.width, accuracy: 0.0001)
    }

    func testStylePayloadChangesAppearanceOnly() {
        var source = PhotoItem(filename: "source.jpg")
        source.customName = "Source"
        source.frameString = "{{10, 20}, {300, 200}}"
        source.filename = "source.jpg"
        source.scheduleEnabled = true
        source.clickAction = .copyPath
        source.opacity = 0.55
        source.revealOnHover = true
        source.focalPoint = NormalizedFocalPoint(x: 0.1, y: 0.9)

        var target = PhotoItem(filename: "target.jpg")
        target.customName = "Target"
        target.frameString = "{{400, 500}, {120, 80}}"
        target.scheduleEnabled = false
        target.clickAction = .advance

        let style = WidgetAppearanceStyle(source)
        style.apply(to: &target)

        XCTAssertEqual(target.opacity, source.opacity)
        XCTAssertEqual(target.revealOnHover, source.revealOnHover)
        XCTAssertEqual(target.focalPoint, source.focalPoint)
        XCTAssertEqual(target.filename, "target.jpg")
        XCTAssertEqual(target.customName, "Target")
        XCTAssertEqual(target.frameString, "{{400, 500}, {120, 80}}")
        XCTAssertFalse(target.scheduleEnabled)
        XCTAssertEqual(target.clickAction, .advance)
    }

    @MainActor
    private func interactionTestImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        return image
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        clickCount: Int,
        window: NSWindow? = nil,
        location: CGPoint = CGPoint(x: 20, y: 20)
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}
