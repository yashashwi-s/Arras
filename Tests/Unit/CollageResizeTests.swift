import AppKit
import XCTest
@testable import Arras

final class CollageResizeTests: XCTestCase {
    @MainActor
    func testMemberDragKeepsIndependentEditingWithoutModifier() throws {
        try fixture { manager, parent, members in
            let child = manager.windows[members[0]]!
            let before = child.photoFrame
            let sibling = manager.windows[members[1]]!.photoFrame
            let start = CGPoint(x: before.midX, y: before.midY)
            child.sendEvent(try mouse(.leftMouseDown, in: child, at: start))
            XCTAssertNil(manager.collageMoveSnapshots[parent])
            XCTAssertNotNil(manager.collageDrags[members[0]])
            let end = CGPoint(x: start.x + 32, y: start.y + 24)
            child.sendEvent(try mouse(.leftMouseDragged, in: child, at: end))
            XCTAssertNotEqual(child.photoFrame.origin, before.origin)
            rect(manager.windows[members[1]]!.photoFrame, sibling)
            child.sendEvent(try mouse(.leftMouseUp, in: child, at: end))
            XCTAssertEqual(item(manager, members[0]).collageParentID, parent)
            rect(manager.windows[members[1]]!.photoFrame, sibling)
            XCTAssertTrue(manager.collageDrags.isEmpty)
        }
    }

    @MainActor
    func testMemberResizeImmediatelyGrowsAndShrinksCollageBeforeMouseRelease() throws {
        try fixture(styled: false) { manager, parent, members in
            let child = manager.windows[members[0]]!
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            let original = surface.photoFrame
            let sibling = manager.windows[members[1]]!.photoFrame
            var settings = item(manager, parent).desktopCollage!
            settings.skin = .glass
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            surface.transition?.currentProgress = 1
            let pickup = child.photoFrame
            let corner = CollageResizeCorner.bottomLeft
            child.sendEvent(try mouse(.leftMouseDown, in: child, at: corner.movingPoint(in: pickup)))
            XCTAssertNotNil(manager.collageDrags[members[0]])
            let grown = corner.frame(from: pickup, scale: 2.5)
            child.sendEvent(try mouse(.leftMouseDragged, in: child, at: corner.movingPoint(in: grown), modifiers: .option))
            rect(child.photoFrame, grown)
            XCTAssertNil(surface.transition, "Pointer resizing must not wait for a boundary animation")
            XCTAssertNotEqual(surface.photoFrame, original)
            XCTAssertTrue(surface.photoFrame.contains(grown))
            rect(surface.displayedBounds, surface.photoFrame)
            let expanded = surface.photoFrame
            let smaller = corner.frame(from: pickup, scale: 0.6)
            child.sendEvent(try mouse(.leftMouseDragged, in: child, at: corner.movingPoint(in: smaller), modifiers: .option))
            rect(child.photoFrame, smaller)
            XCTAssertLessThan(surface.photoFrame.width, expanded.width)
            XCTAssertLessThan(surface.photoFrame.height, expanded.height)
            XCTAssertNil(surface.transition)
            rect(surface.displayedBounds, surface.photoFrame)
            rect(manager.windows[members[1]]!.photoFrame, sibling)
            XCTAssertEqual(item(manager, members[0]).collageParentID, parent)
            child.sendEvent(try mouse(.leftMouseUp, in: child, at: corner.movingPoint(in: smaller)))
            XCTAssertEqual(item(manager, members[0]).collageParentID, parent)
            rect(manager.windows[members[1]]!.photoFrame, sibling)
        }
    }

    @MainActor
    func testCollageResizeControlsStayAboveOpaquePaperAndInsideCanvas() throws {
        let window = CollageDesktopWindow(settings: DesktopCollageSettings(skin: .polaroid))
        defer { window.hidePhoto() }
        window.setPhotoFrame(CGRect(x: 200, y: 200, width: 400, height: 300))
        window.setLocked(false)
        let surface = try XCTUnwrap(window.contentView as? CollageSurfaceView)
        surface.updatePointer(at: CGPoint(x: surface.bounds.midX, y: surface.bounds.midY))
        let chrome = try XCTUnwrap(surface.subviews.last)
        XCTAssertTrue(surface.outerBorder.superlayer === chrome.layer,
                      "Opaque material must not cover the border or resize controls")
        let grips = try XCTUnwrap(chrome.layer?.sublayers?.suffix(4))
        XCTAssertEqual(grips.count, 4)
        for layer in grips {
            let grip = try XCTUnwrap(layer as? CAShapeLayer)
            XCTAssertFalse(grip.isHidden)
            XCTAssertTrue(chrome.bounds.contains(try XCTUnwrap(grip.path).boundingBoxOfPath))
        }
        window.setLocked(true)
        XCTAssertTrue(grips.allSatisfy(\.isHidden))
    }

    func testLegacyScaleAndScaledAppearanceRoundTripWithoutClampingBaseSettings() throws {
        let old = try JSONDecoder().decode(DesktopCollageSettings.self, from: Data(#"{"caption":"Summer","padding":28,"gap":20}"#.utf8))
        XCTAssertEqual(old.compositionScale, 1)
        var enlarged = old
        XCTAssertEqual(old.borderWidth, 0)
        enlarged.borderWidth = 3
        enlarged.borderColorHex = "#294655"
        enlarged.compositionScale = 4
        let decoded = try JSONDecoder().decode(DesktopCollageSettings.self, from: JSONEncoder().encode(enlarged))
        XCTAssertEqual(decoded, enlarged)
        XCTAssertEqual(decoded.effectivePadding, 112)
        XCTAssertEqual(decoded.effectiveGap, 80)
        XCTAssertEqual(decoded.effectiveBorderWidth, 12)
        XCTAssertEqual(decoded.captionHeight, 176)
        XCTAssertEqual(CollageGeometry.enclosing([], fallback: CGRect(x: 10, y: 20, width: 160, height: 160), settings: decoded).size,
                       CGSize(width: 640, height: 640))
    }

    @MainActor
    func testAllFourNativeCornerDragsKeepOppositeAnchorAndCommitOneComposition() throws {
        for corner in CollageResizeCorner.allCases {
            try fixture { manager, parent, members in
                let group = manager.windows[parent] as! CollageDesktopWindow
                let before = group.photoFrame
                let originals = members.map { item(manager, $0) }
                let windows = members.map { manager.windows[$0]! }
                let views = windows.map { $0.contentView! }
                let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                let pointer = corner.gripCenter(in: before, radius: group.settings.effectiveCornerRadius)
                group.sendEvent(try mouse(.leftMouseDown, in: group, at: pointer))
                XCTAssertNotNil(manager.collageResizeSnapshots[parent])
                let anchor = corner.anchor(in: before), moving = corner.movingPoint(in: before)
                for step in 1...10 {
                    let scale = 1 + CGFloat(step) * 0.05
                    let point = CGPoint(x: pointer.x + (moving.x - anchor.x) * (scale - 1),
                                        y: pointer.y + (moving.y - anchor.y) * (scale - 1))
                    group.sendEvent(try mouse(.leftMouseDragged, in: group, at: point, modifiers: .option))
                    rect(group.photoFrame, corner.frame(from: before, scale: scale))
                    for (index, original) in originals.enumerated() {
                        rect(windows[index].photoFrame, CollageGeometry.scaled(NSRectFromString(original.frameString), around: anchor, by: scale))
                        XCTAssertTrue(windows[index].contentView === views[index])
                        XCTAssertTrue(windows[index].isVisible)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
                XCTAssertEqual(item(manager, members[0]).widgetWidth, originals[0].widgetWidth)
                let end = CGPoint(x: pointer.x + (moving.x - anchor.x) * 0.5, y: pointer.y + (moving.y - anchor.y) * 0.5)
                group.sendEvent(try mouse(.leftMouseUp, in: group, at: end))
                XCTAssertTrue(manager.collageResizeSnapshots.isEmpty)
                XCTAssertFalse(SnapGuideOverlay.shared.isVisible)
                XCTAssertEqual(item(manager, parent).desktopCollage!.compositionScale, 1.5, accuracy: 0.00001)
                for (original, id) in zip(originals, members) {
                    let resized = item(manager, id)
                    XCTAssertEqual(resized.matWidth, original.matWidth * 1.5, accuracy: 0.00001)
                    XCTAssertEqual(resized.cornerRadius, original.cornerRadius * 1.5, accuracy: 0.00001)
                    XCTAssertEqual(resized.tiltDegrees, original.tiltDegrees)
                    XCTAssertEqual(resized.collageParentID, parent)
                }
                let expected = CollageGeometry.enclosing(members.map { manager.collageFootprint(item(manager, $0)) }, fallback: before, settings: item(manager, parent).desktopCollage!)
                rect(group.photoFrame, expected)
            }
        }
    }

    @MainActor
    func testShrinkEnlargeRoundTripAndReloadPreserveFramesStylesAndCaption() throws {
        try fixture { manager, parent, members in
            let originals = manager.photos
            let body = manager.windows[parent]!.photoFrame
            resize(manager, parent, 0.5)
            resize(manager, parent, 2)
            rect(manager.windows[parent]!.photoFrame, body)
            for original in originals {
                let current = item(manager, original.id)
                rect(NSRectFromString(current.frameString), NSRectFromString(original.frameString))
                XCTAssertEqual(current.matWidth, original.matWidth, accuracy: 0.00001)
                XCTAssertEqual(current.shadowBlur, original.shadowBlur, accuracy: 0.00001)
                XCTAssertEqual(current.borderWidth, original.borderWidth, accuracy: 0.00001)
            }
            let reloaded = PhotoManager(storageDirectory: manager.storageDir)
            defer { reloaded.windows.values.forEach { $0.hidePhoto() }; reloaded.windows.removeAll() }
            XCTAssertEqual(item(reloaded, parent).desktopCollage, item(manager, parent).desktopCollage)
            for id in members { rect(reloaded.windows[id]!.photoFrame, manager.windows[id]!.photoFrame) }
        }
    }

    @MainActor
    func testHiddenLockedMemberSpaceConfigurationsAndRotationStayCoherent() throws {
        try fixture { manager, parent, members in
            let hidden = members[1], index = manager.photos.firstIndex { $0.id == hidden }!
            manager.photos[index].isVisible = false
            manager.photos[index].isLocked = true
            manager.photos[index].folderImageConfigs["other.png"] = FolderImageConfig(frameString: "{{30,40},{210,120}}", widgetWidth: 210)
            manager.windows.removeValue(forKey: hidden)?.hidePhoto()
            XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
            let space = manager.photos.last!.id
            manager.setRotationInterval(space, "click")
            manager.windows[space]?.setPhotoFrame(CGRect(x: 130, y: 410, width: 220, height: 150))
            attach(manager, space, parent)
            settle(manager)
            let oldHidden = item(manager, hidden)
            let oldSpace = item(manager, space)
            let group = manager.windows[parent] as! CollageDesktopWindow
            let before = group.photoFrame
            XCTAssertNotNil(manager.beginCollageResize(parent))
            manager.nextFolderImage(space)
            manager.prevFolderImage(space)
            XCTAssertEqual(item(manager, space).folderImageIndex, oldSpace.folderImageIndex)
            manager.resizeCollage(parent, scale: 1.6, corner: .topRight, finished: false)
            manager.resizeCollage(parent, scale: 1.6, corner: .topRight, finished: true)
            let child = item(manager, hidden)
            XCTAssertFalse(child.isVisible)
            XCTAssertTrue(child.isLocked)
            XCTAssertNil(manager.windows[hidden])
            rect(NSRectFromString(child.frameString), CollageGeometry.scaled(NSRectFromString(oldHidden.frameString), around: before.origin, by: 1.6))
            let config = child.folderImageConfigs["other.png"]!
            XCTAssertEqual(config.widgetWidth, 336, accuracy: 0.00001)
            rect(NSRectFromString(config.frameString), CollageGeometry.scaled(CGRect(x: 30, y: 40, width: 210, height: 120), around: before.origin, by: 1.6))
            let sceneIDs = Set([parent, space] + members)
            let returning = manager.collageFlights.keys.contains { sceneIDs.contains($0) }
            XCTAssertNil(manager.collageResizeSnapshots[parent])
            XCTAssertEqual(manager.replacementConflictsWithArrangement(item(manager, space)), returning)
            if returning {
                manager.nextFolderImage(space)
                XCTAssertEqual(item(manager, space).folderImageIndex, oldSpace.folderImageIndex,
                               "Return motion still owns the resized scene")
            }
            settle(manager)
            manager.nextFolderImage(space)
            XCTAssertNotEqual(item(manager, space).folderImageIndex, oldSpace.folderImageIndex)
        }
    }

    @MainActor
    func testCancellationSaveFailureAndLockRestoreLiveStylesWithoutReplacingPhotos() throws {
        try fixture { manager, parent, members in
            let before = manager.photos
            let body = manager.windows[parent]!.photoFrame
            let window = manager.windows[members[0]]!
            let view = window.contentView!
            let visual = window.visualFrame
            XCTAssertNotNil(manager.beginCollageResize(parent))
            manager.resizeCollage(parent, scale: 1.8, corner: .topLeft, finished: false)
            manager.cancelCollageInteractions()
            rect(window.visualFrame, visual)
            rect(manager.windows[parent]!.photoFrame, body)
            XCTAssertTrue(window.contentView === view)
            XCTAssertEqual(try canonical(manager.photos), try canonical(before))
            XCTAssertNotNil(manager.beginCollageResize(parent))
            manager.resizeCollage(parent, scale: 1.6, corner: .bottomRight, finished: false)
            let corrupt = Data("damaged fixture".utf8)
            try corrupt.write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.resizeCollage(parent, scale: 1.6, corner: .bottomRight, finished: true)
            XCTAssertTrue(manager.collageResizeSnapshots.isEmpty)
            rect(window.visualFrame, visual)
            XCTAssertTrue(window.contentView === view)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), corrupt)
            XCTAssertEqual(try canonical(manager.photos), try canonical(before))
        }
    }

    @MainActor
    func testResizingDuringSpacingMotionFreezesVisiblePickupAndNoMotionResumesDestinations() throws {
        try fixture { manager, parent, members in
            var settings = item(manager, parent).desktopCollage!
            settings.gap = 50
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            for flight in manager.collageFlights.values { flight.currentProgress = 0.3 }
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 0.3
            let visible = members.map { manager.windows[$0]!.photoFrame }
            let visibleBody = group.displayedBounds
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertNotNil(manager.beginCollageResize(parent))
            rect(group.photoFrame, visibleBody)
            for (id, frame) in zip(members, visible) { rect(manager.windows[id]!.photoFrame, frame) }
            manager.resizeCollage(parent, scale: 1, corner: .topRight, finished: true)
            settle(manager)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
            for id in members { rect(manager.windows[id]!.photoFrame, NSRectFromString(item(manager, id).frameString)) }
            rect(group.photoFrame, NSRectFromString(item(manager, parent).frameString))
        }
    }

    @MainActor
    func testActualResizeDuringGapAnimationPreservesDestinationGapForNextEdit() throws {
        try fixture { manager, parent, members in
            for id in members {
                let index = manager.photos.firstIndex { $0.id == id }!
                manager.photos[index].matWidth = 0
                manager.photos[index].tiltDegrees = 0
                (manager.windows[id]!.contentView as! DraggablePhotoView).setMat(width: 0, color: .white)
                (manager.windows[id]!.contentView as! DraggablePhotoView).setTilt(0)
            }
            manager.windows[members[1]]!.setPhotoFrame(CGRect(x: 400, y: 160, width: 220, height: 160))
            for id in members { manager.storeCollageFrame(id, manager.windows[id]!.photoFrame) }
            manager.fitCollageModel(parent); manager.fitCollageWindow(parent, animated: false)
            var settings = item(manager, parent).desktopCollage!
            settings.gap = 50
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            for flight in manager.collageFlights.values { flight.currentProgress = 0.3 }
            (manager.windows[parent] as! CollageDesktopWindow).transition?.currentProgress = 0.3
            resize(manager, parent, 1.5)
            settle(manager)
            XCTAssertEqual(manager.windows[members[1]]!.photoFrame.minX - manager.windows[members[0]]!.photoFrame.maxX, 75, accuracy: 0.001)
            settings = item(manager, parent).desktopCollage!
            settings.gap = 60
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            settle(manager)
            XCTAssertEqual(manager.windows[members[1]]!.photoFrame.minX - manager.windows[members[0]]!.photoFrame.maxX, 90, accuracy: 0.001)
        }
    }

    @MainActor
    func testDisplayDisconnectCancelsPreviewBeforeSavingProfilesAndRecreatesCollage() throws {
        try fixture { manager, parent, members in
            let display = "isolated-disconnected-display"
            for index in manager.photos.indices { manager.photos[index].displayIdentifier = display }
            let originals = manager.photos
            XCTAssertNotNil(manager.beginCollageResize(parent))
            manager.resizeCollage(parent, scale: 1.7, corner: .bottomLeft, finished: false)
            manager.handleScreenChanges(connected: [], disconnected: [display])
            XCTAssertTrue(manager.collageResizeSnapshots.isEmpty)
            for original in originals {
                let hidden = item(manager, original.id)
                XCTAssertTrue(hidden.isHiddenForDisplay)
                XCTAssertNil(manager.windows[original.id])
                rect(NSRectFromString(hidden.savedDisplayFrames[display]!), NSRectFromString(original.frameString))
                XCTAssertEqual(hidden.matWidth, original.matWidth)
            }
            manager.handleScreenChanges(connected: [display], disconnected: [])
            XCTAssertTrue(manager.windows[parent] is CollageDesktopWindow)
            for id in [parent] + members {
                XCTAssertFalse(item(manager, id).isHiddenForDisplay)
                rect(manager.windows[id]!.photoFrame, NSRectFromString(originals.first { $0.id == id }!.frameString))
            }
        }
    }

    @MainActor
    func testScaleClampEmptyResizeAndStaleAppearanceDraftDoNotUndoSize() throws {
        try fixture { manager, parent, _ in
            let draft = item(manager, parent).desktopCollage!
            let snapshot = try XCTUnwrap(manager.beginCollageResize(parent))
            manager.resizeCollage(parent, scale: 0.001, corner: .topRight, finished: false)
            XCTAssertEqual(manager.windows[parent]!.photoFrame.width, snapshot.bounds.width * snapshot.limits.lowerBound, accuracy: 0.00001)
            manager.cancelCollageInteractions()
            resize(manager, parent, 1.7)
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: draft))
            XCTAssertEqual(item(manager, parent).desktopCollage!.compositionScale, 1.7, accuracy: 0.00001)
            let empty = try XCTUnwrap(manager.addDesktopCollage())
            resize(manager, empty, 2)
            XCTAssertEqual(manager.windows[empty]!.photoFrame.width, 320, accuracy: 0.00001)
            XCTAssertTrue(manager.applyCollageSettings(empty, settings: DesktopCollageSettings(skin: .polaroid)))
            XCTAssertEqual(manager.windows[empty]!.photoFrame.width, 320, accuracy: 0.00001)
        }
    }

    @MainActor
    func testResizeGuidesIgnoreOwnMembersAndDoNotChangePointerGeometry() throws {
        try fixture { manager, parent, members in
            let suite = "CollageResizeSnap-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let engine = SnapEngine(defaults: defaults)
            engine.includesOtherApps = false
            let group = manager.windows[parent] as! CollageDesktopWindow
            let body = group.photoFrame
            engine.beginDrag(for: group, excluding: Set(members), includeCollages: true)
            let free = CollageResizeCorner.topRight.frame(from: body, scale: 1.003)
            XCTAssertTrue(engine.resizeGuides(for: free, corner: .topRight, modifiers: []).isEmpty)
            let external = try photo(manager, CGRect(x: body.minX + body.width * 1.25, y: body.maxY + 170, width: 180, height: 140), styled: false)
            engine.beginDrag(for: group, excluding: Set(members), includeCollages: true)
            let rect = CollageResizeCorner.topRight.frame(from: body, scale: 1.245)
            let guides = engine.resizeGuides(for: rect, corner: .topRight, modifiers: [])
            XCTAssertTrue(guides.contains { $0.orientation == .vertical && $0.position == manager.windows[external]!.visualFrame.minX })
            XCTAssertEqual(rect.origin, body.origin)
            XCTAssertEqual(rect.width / rect.height, body.width / body.height, accuracy: 0.00001)
            XCTAssertEqual(rect.width, body.width * 1.245, accuracy: 0.00001)
            XCTAssertNotEqual(rect.maxX, manager.windows[external]!.visualFrame.minX)
            XCTAssertTrue(engine.resizeGuides(for: rect, corner: .topRight, modifiers: .option).isEmpty)
            engine.endDrag()
        }
    }

    @MainActor
    func testLiveAppearanceRepeatedGapDraftsDoNotAccumulateOrPersistAndApplyMatchesDesktop() throws {
        try fixture { manager, parent, members in
            align(manager, parent, members)
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let original = try canonical(manager.photos)
            let session = UUID()
            manager.beginCollageAppearancePreview(parent, session: session)
            var settings = item(manager, parent).desktopCollage!
            settings.glassStyle = .clear
            settings.usesCustomTint = true
            settings.tintHex = "#77CCEE"
            settings.tintStrength = 0.28
            settings.caption = "Our place"
            for gap: CGFloat in [60, 35, 70, 40] {
                settings.gap = gap
                manager.previewCollageAppearance(parent, session: session, settings: settings)
                settle(manager)
                let expected = try XCTUnwrap(manager.collageAppearanceLayout(parent, settings: settings))
                for id in members { rect(manager.windows[id]!.photoFrame, expected.frames[id]!) }
                let window = manager.windows[parent] as! CollageDesktopWindow
                rect(window.photoFrame, expected.bounds)
                XCTAssertEqual(window.settings, expected.settings)
                if #available(macOS 26.0, *) {
                    let glass = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSGlassEffectView }.first)
                    XCTAssertEqual(glass.style, .clear)
                    XCTAssertEqual(glass.tintColor, NSColor.fromHex(settings.tintHex)!.withAlphaComponent(settings.tintStrength))
                }
            }
            XCTAssertEqual(try canonical(manager.photos), original)
            XCTAssertTrue(manager.persist())
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
            let previewFrames = members.map { manager.windows[$0]!.photoFrame }
            let previewBody = manager.windows[parent]!.photoFrame
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            settle(manager)
            XCTAssertNil(manager.collageAppearanceDrafts[parent])
            rect(manager.windows[parent]!.photoFrame, previewBody)
            for (id, frame) in zip(members, previewFrames) {
                rect(NSRectFromString(item(manager, id).frameString), frame)
                rect(manager.windows[id]!.photoFrame, frame)
            }
            manager.endCollageAppearancePreview(parent, session: session)
            rect(manager.windows[parent]!.photoFrame, previewBody)
        }
    }

    @MainActor
    func testLiveDraftCancelPreservesMovementAndResizeCommittedWhileEditorRemainsOpen() throws {
        try fixture { manager, parent, members in
            align(manager, parent, members)
            let originalSettings = item(manager, parent).desktopCollage!
            let originalFrame = NSRectFromString(item(manager, members[0]).frameString)
            let session = UUID()
            manager.beginCollageAppearancePreview(parent, session: session)
            var draft = originalSettings
            draft.gap = 65; draft.padding = 40; draft.glassStyle = .clear
            manager.previewCollageAppearance(parent, session: session, settings: draft)
            settle(manager)
            let group = manager.windows[parent] as! CollageDesktopWindow
            let point = CGPoint(x: group.photoFrame.midX, y: group.photoFrame.minY + 10)
            group.sendEvent(try mouse(.leftMouseDown, in: group, at: point))
            group.sendEvent(try mouse(.leftMouseDragged, in: group, at: CGPoint(x: point.x + 33, y: point.y + 27), modifiers: .option))
            group.sendEvent(try mouse(.leftMouseUp, in: group, at: CGPoint(x: point.x + 33, y: point.y + 27)))
            settle(manager)
            rect(NSRectFromString(item(manager, members[0]).frameString), originalFrame.offsetBy(dx: 33, dy: 27))
            resize(manager, parent, 1.5)
            settle(manager)
            let committed = try canonical(manager.photos)
            let destinations = members.map { NSRectFromString(item(manager, $0).frameString) }
            manager.endCollageAppearancePreview(parent, session: session)
            settle(manager)
            XCTAssertEqual(try canonical(manager.photos), committed)
            XCTAssertEqual(group.settings.glassStyle, originalSettings.glassStyle)
            XCTAssertEqual(group.settings.compositionScale, 1.5, accuracy: 0.00001)
            for (id, frame) in zip(members, destinations) { rect(manager.windows[id]!.photoFrame, frame) }
            rect(group.photoFrame, NSRectFromString(item(manager, parent).frameString))
        }
    }

    @MainActor
    func testEndedEditorSessionCannotReappearAndFailedApplyKeepsEditableDraft() throws {
        try fixture { manager, parent, members in
            align(manager, parent, members)
            let original = try canonical(manager.photos)
            let first = UUID(), second = UUID()
            var settings = item(manager, parent).desktopCollage!
            settings.skin = .solid; settings.gap = 70
            manager.beginCollageAppearancePreview(parent, session: first)
            manager.previewCollageAppearance(parent, session: first, settings: settings)
            manager.endCollageAppearancePreview(parent, session: first)
            manager.previewCollageAppearance(parent, session: first, settings: settings)
            XCTAssertNil(manager.collageAppearanceDrafts[parent])
            manager.beginCollageAppearancePreview(parent, session: second)
            manager.endCollageAppearancePreview(parent, session: first)
            XCTAssertEqual(manager.collageAppearanceDrafts[parent]?.session, second)
            manager.previewCollageAppearance(parent, session: second, settings: settings)
            settle(manager)
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertFalse(manager.applyCollageSettings(parent, settings: settings))
            XCTAssertEqual(try canonical(manager.photos), original)
            XCTAssertEqual(manager.collageAppearanceDrafts[parent]?.settings, settings)
            manager.endCollageAppearancePreview(parent, session: second)
            settle(manager)
            XCTAssertEqual((manager.windows[parent] as! CollageDesktopWindow).settings, item(manager, parent).desktopCollage!)
            for id in members { rect(manager.windows[id]!.photoFrame, NSRectFromString(item(manager, id).frameString)) }
        }
    }

    @MainActor
    func testSameBoundsMaterialTintAndStyleDraftUpdatesTheActualNativeSurface() throws {
        try fixture { manager, parent, _ in
            let session = UUID()
            manager.beginCollageAppearancePreview(parent, session: session)
            var settings = item(manager, parent).desktopCollage!
            manager.previewCollageAppearance(parent, session: session, settings: settings)
            settle(manager)
            let window = manager.windows[parent] as! CollageDesktopWindow
            let bounds = window.photoFrame
            if #available(macOS 26.0, *) {
                let glass = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSGlassEffectView }.first)
                for style in [CollageGlassStyle.clear, .system, .clear] {
                    settings.glassStyle = style
                    settings.usesCustomTint = true
                    settings.tintHex = style == .clear ? "#77CCEE" : "#FF8844"
                    settings.tintStrength = style == .clear ? 0.2 : 0.4
                    manager.previewCollageAppearance(parent, session: session, settings: settings)
                    XCTAssertEqual(window.photoFrame, bounds)
                    XCTAssertEqual(glass.style, style == .clear ? .clear : .regular)
                    XCTAssertEqual(glass.tintColor, NSColor.fromHex(settings.tintHex)!.withAlphaComponent(settings.tintStrength))
                }
                settings.skin = .solid
                manager.previewCollageAppearance(parent, session: session, settings: settings)
                XCTAssertTrue(glass.isHidden)
                settings.skin = .glass
                settings.usesCustomTint = false
                manager.previewCollageAppearance(parent, session: session, settings: settings)
                XCTAssertFalse(glass.isHidden)
                XCTAssertNil(glass.tintColor)
                settings.caption = "Another memory"
                manager.previewCollageAppearance(parent, session: session, settings: settings)
                XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == settings.caption })
            }
        }
    }

    @MainActor
    func testSettledAppearanceDraftDisplayDisconnectSavesOnlyCommittedFrames() throws {
        try fixture { manager, parent, members in
            align(manager, parent, members)
            let display = "appearance-fixture-display"
            for index in manager.photos.indices { manager.photos[index].displayIdentifier = display }
            let originals = manager.photos
            let session = UUID()
            manager.beginCollageAppearancePreview(parent, session: session)
            var settings = item(manager, parent).desktopCollage!
            settings.gap = 70; settings.padding = 60
            manager.previewCollageAppearance(parent, session: session, settings: settings)
            settle(manager)
            XCTAssertNotEqual(manager.windows[members[1]]!.photoFrame, NSRectFromString(item(manager, members[1]).frameString))
            manager.handleScreenChanges(connected: [], disconnected: [display])
            XCTAssertTrue(manager.collageAppearanceDrafts.isEmpty)
            for original in originals {
                let hidden = item(manager, original.id)
                rect(NSRectFromString(hidden.savedDisplayFrames[display]!), NSRectFromString(original.frameString))
            }
            manager.previewCollageAppearance(parent, session: session, settings: settings)
            XCTAssertTrue(manager.collageAppearanceDrafts.isEmpty)
            manager.handleScreenChanges(connected: [display], disconnected: [])
            for original in originals { rect(manager.windows[original.id]!.photoFrame, NSRectFromString(original.frameString)) }
        }
    }

    @MainActor
    func testNativeEditorCloseEndsItsActualDesktopDraft() throws {
        try fixture { manager, parent, _ in
            let editor = CollageEditorWindowController(manager: manager, id: parent) {}
            editor.window?.level = WidgetDepth.onDesktop.windowLevel
            editor.window?.orderFront(nil)
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let session = try XCTUnwrap(manager.collageAppearanceDrafts[parent]?.session)
            var settings = item(manager, parent).desktopCollage!
            settings.skin = .solid
            manager.previewCollageAppearance(parent, session: session, settings: settings)
            settle(manager)
            XCTAssertEqual((manager.windows[parent] as! CollageDesktopWindow).settings.skin, .solid)
            editor.close()
            settle(manager)
            XCTAssertNil(manager.collageAppearanceDrafts[parent])
            XCTAssertEqual((manager.windows[parent] as! CollageDesktopWindow).settings.skin, .glass)
            let next = CollageEditorWindowController(manager: manager, id: parent) {}
            next.window?.level = WidgetDepth.onDesktop.windowLevel
            next.window?.orderFront(nil)
            manager.cancelCollageInteractions(endAppearancePreviews: true)
            XCTAssertFalse(next.window?.isVisible ?? true)
            XCTAssertTrue(manager.collageAppearanceDrafts.isEmpty)
        }
    }

    @MainActor
    func testAnimatedPhotoKeepsItsPlaybackAndWindowThroughGroupScaling() throws {
        try fixture { manager, parent, _ in
            XCTAssertTrue(manager.addStarterExample(.animated))
            let id = manager.photos.last!.id
            attach(manager, id, parent)
            settle(manager)
            let window = manager.windows[id]!
            let view = window.contentView as! DraggablePhotoView
            let frames = try XCTUnwrap(view.photoLayer.animatedFrames)
            // This checks active playback; the test runner may cover desktop windows.
            window.stopRuntimeActivityMonitoring()
            view.photoLayer.setPlaybackEnabled(true)
            let layer = view.imageLayer
            let keys = layer.animationKeys()
            XCTAssertNotNil(keys)
            resize(manager, parent, 1.2)
            XCTAssertTrue(manager.windows[id] === window)
            XCTAssertTrue(window.contentView === view)
            XCTAssertTrue(view.imageLayer === layer)
            XCTAssertEqual(view.photoLayer.animatedFrames?.images.count, frames.images.count)
            XCTAssertEqual(layer.animationKeys(), keys)
        }
    }

    @MainActor
    private func align(_ manager: PhotoManager, _ parent: UUID, _ members: [UUID]) {
        for id in members {
            let index = manager.photos.firstIndex { $0.id == id }!
            manager.photos[index].matWidth = 0; manager.photos[index].tiltDegrees = 0
            let view = manager.windows[id]!.contentView as! DraggablePhotoView
            view.setMat(width: 0, color: .white); view.setTilt(0)
        }
        manager.windows[members[1]]!.setPhotoFrame(CGRect(x: 400, y: 160, width: 220, height: 160))
        for id in members { manager.storeCollageFrame(id, manager.windows[id]!.photoFrame) }
        manager.fitCollageModel(parent); manager.fitCollageWindow(parent, animated: false)
        XCTAssertTrue(manager.persist())
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    private func fixture(styled: Bool = true, _ body: (PhotoManager, UUID, [UUID]) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollageResize-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: directory)
        defer {
            manager.cancelCollageInteractions()
            manager.windows.values.forEach { $0.hidePhoto() }; manager.windows.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try photo(manager, CGRect(x: 180, y: 160, width: 200, height: 280), styled: styled)
        let second = try photo(manager, CGRect(x: 430, y: 160, width: 220, height: 160), styled: styled)
        let parent = try XCTUnwrap(manager.addDesktopCollage())
        manager.moveCollage(parent, to: CGRect(x: 170, y: 150, width: 160, height: 160), finished: true)
        attach(manager, first, parent); attach(manager, second, parent)
        var settings = item(manager, parent).desktopCollage!
        settings.caption = "A memory"
        XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
        settle(manager)
        try body(manager, parent, [first, second])
    }

    @MainActor
    private func photo(_ manager: PhotoManager, _ frame: CGRect, styled: Bool = true) throws -> UUID {
        let image = NSImage(size: frame.size, flipped: false) { bounds in NSColor.systemTeal.setFill(); bounds.fill(); return true }
        var item = PhotoItem(filename: UUID().uuidString + ".png", width: frame.width)
        item.frameString = NSStringFromRect(frame)
        if styled { item.matWidth = 12; item.tiltDegrees = 3; item.borderWidth = 2; item.cornerRadius = 14 }
        try StarterArtwork.pngData(for: image).write(to: manager.storageDir.appendingPathComponent(item.filename))
        manager.photos.append(item)
        manager.createWindow(for: item, content: .still(image))
        XCTAssertTrue(manager.persist())
        return item.id
    }

    @MainActor
    private func attach(_ manager: PhotoManager, _ photo: UUID, _ parent: UUID) {
        let index = manager.photos.firstIndex { $0.id == photo }!
        manager.photos[index].collageParentID = parent
        manager.fitCollageModel(parent); manager.fitCollageWindow(parent, animated: false)
        manager.syncCollages()
        XCTAssertTrue(manager.persist())
    }

    @MainActor
    private func resize(_ manager: PhotoManager, _ parent: UUID, _ scale: CGFloat) {
        XCTAssertNotNil(manager.beginCollageResize(parent))
        manager.resizeCollage(parent, scale: scale, corner: .topRight, finished: false)
        manager.resizeCollage(parent, scale: scale, corner: .topRight, finished: true)
    }

    @MainActor
    private func settle(_ manager: PhotoManager) {
        for flight in Array(manager.collageFlights.values) { flight.currentProgress = 1 }
        for window in manager.windows.values.compactMap({ $0 as? CollageDesktopWindow }) { window.transition?.currentProgress = 1 }
    }

    @MainActor
    private func item(_ manager: PhotoManager, _ id: UUID) -> PhotoItem { manager.photos.first { $0.id == id }! }

    private func canonical(_ photos: [PhotoItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(photos)
    }

    private func rect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try testMouseEvent(type, in: window, at: point, modifiers: modifiers)
    }
}
