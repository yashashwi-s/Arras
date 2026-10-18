import AppKit
import SwiftUI
import Combine
import XCTest
@testable import Arras

final class DesktopCollageTests: XCTestCase {
    func testSettingsRoundTripAndUnknownSkinFallback() throws {
        var settings = DesktopCollageSettings(skin: .polaroid)
        settings.caption = "Weekend in the hills"
        settings.borderWidth = 4
        settings.borderColorHex = "#294655"
        XCTAssertEqual(try JSONDecoder().decode(DesktopCollageSettings.self, from: JSONEncoder().encode(settings)), settings)
        let invalid = Data(#"{"skin":"future-material","padding":-1,"gap":900,"cornerRadius":-12,"tintHex":"invalid"}"#.utf8)
        let decoded = try JSONDecoder().decode(DesktopCollageSettings.self, from: invalid)
        XCTAssertEqual(decoded.skin, .glass)
        XCTAssertEqual(decoded.padding, 12)
        XCTAssertEqual(decoded.gap, 100)
        XCTAssertEqual(decoded.cornerRadius, 0)
        XCTAssertEqual(decoded.tintHex, "#F5EFE3")
        XCTAssertEqual(decoded.borderWidth, 0)
        XCTAssertEqual(decoded.borderColorHex, "#FFFFFF")
        let invalidBorder = try JSONDecoder().decode(DesktopCollageSettings.self, from: Data(#"{"skin":"transparent","borderWidth":500,"borderColorHex":"invalid"}"#.utf8))
        XCTAssertEqual(invalidBorder.skin, .transparent)
        XCTAssertEqual(invalidBorder.borderWidth, 12)
        XCTAssertEqual(invalidBorder.borderColorHex, "#FFFFFF")
    }

    @MainActor
    func testTransparentGroupingHasNoBackdropAndOutsideBorderFitsScaledCanvas() throws {
        var settings = DesktopCollageSettings()
        settings.borderWidth = 3
        settings.applyPreset(.transparent)
        XCTAssertEqual(settings.borderWidth, 0)
        let window = CollageDesktopWindow(settings: settings)
        defer { window.hidePhoto() }
        window.isEmpty = false
        let body = CGRect(x: 100, y: 100, width: 240, height: 180)
        window.setPhotoFrame(body)
        let surface = try XCTUnwrap(window.contentView as? CollageSurfaceView)
        let host = try XCTUnwrap(surface.subviews.first)
        XCTAssertEqual(host.layer?.shadowOpacity, 0)
        XCTAssertTrue(host.subviews.allSatisfy(\.isHidden), "Transparent groups draw no material, paper, empty hint or absent caption")
        XCTAssertTrue(surface.outerBorder.isHidden)
        XCTAssertEqual(window.visualFrame, body)

        settings.borderWidth = 4
        settings.borderColorHex = "#294655"
        settings.compositionScale = 4
        window.settings = settings
        window.render()
        XCTAssertEqual(window.photoFrame, body)
        XCTAssertEqual(surface.outerBorder.lineWidth, 16)
        XCTAssertFalse(surface.outerBorder.isHidden)
        let strokeBounds = try XCTUnwrap(surface.outerBorder.path).boundingBoxOfPath.insetBy(dx: -8, dy: -8)
        XCTAssertTrue(surface.bounds.contains(strokeBounds), "The whole border must fit outside the backdrop without clipping")
        XCTAssertEqual(window.visualFrame, body.insetBy(dx: -16, dy: -16))
        XCTAssertTrue(window.containsBackgroundPoint(CGPoint(x: body.minX - 10, y: body.midY)))
        XCTAssertFalse(window.containsBackgroundPoint(CGPoint(x: body.minX - 20, y: body.midY)))
        XCTAssertEqual(host.layer?.shadowOpacity, 0)
        XCTAssertTrue(host.subviews.allSatisfy(\.isHidden))
    }

    func testMixedAspectBoundsAreTightAndCaptionDoesNotCoverPhotos() {
        var settings = DesktopCollageSettings()
        settings.padding = 30
        settings.caption = "A memory"
        let portrait = CGRect(x: 100, y: 100, width: 180, height: 240)
        let square = CGRect(x: 300, y: 220, width: 120, height: 120)
        let result = CollageGeometry.enclosing([portrait, square], fallback: .zero, settings: settings)
        XCTAssertEqual(result, CGRect(x: 70, y: 26, width: 380, height: 344))
        XCTAssertTrue(result.contains(portrait))
        XCTAssertEqual(result.maxY - square.maxY, 30)
        XCTAssertEqual(portrait.minY - result.minY, 30 + settings.captionHeight)
    }

    func testMatAndTiltFitWithoutChangingPhotoDimensions() {
        var item = PhotoItem(filename: "photo.png")
        item.matWidth = 18; item.tiltDegrees = 12
        let frame = CGRect(x: 200, y: 150, width: 200, height: 280)
        let footprint = CollageGeometry.footprint(item, frame: frame)
        XCTAssertGreaterThan(footprint.width, frame.width + 36)
        XCTAssertGreaterThan(footprint.height, frame.height)
        XCTAssertEqual(footprint.midX, frame.midX, accuracy: 0.001)
        XCTAssertEqual(footprint.midY, frame.midY, accuracy: 0.001)
    }

    func testEqualGapAndTopAlignmentOnlySnapNearby() {
        let portrait = CGRect(x: 100, y: 100, width: 180, height: 240)
        let proposed = CGRect(x: 306, y: 216, width: 120, height: 120)
        let snapped = CollageGeometry.snapped(proposed, siblings: [portrait], gap: 20)
        XCTAssertEqual(snapped, CGRect(x: 300, y: 220, width: 120, height: 120))
        let far = CGRect(x: 460, y: 530, width: 120, height: 120)
        XCTAssertEqual(CollageGeometry.snapped(far, siblings: [portrait], gap: 20), far)
        XCTAssertEqual(snapped.size, proposed.size)
    }

    func testDropAcceptsAdjacentPhotoButRejectsNearMiss() {
        let body = CGRect(x: 72, y: 72, width: 236, height: 296)
        let portrait = CGRect(x: 100, y: 100, width: 180, height: 240)
        XCTAssertTrue(CollageGeometry.accepts(CGRect(x: 300, y: 220, width: 120, height: 120), body: body, siblings: [portrait], gap: 20))
        XCTAssertFalse(CollageGeometry.accepts(CGRect(x: 330, y: 220, width: 120, height: 120), body: body, siblings: [portrait], gap: 20))
        XCTAssertTrue(CollageGeometry.accepts(CGRect(x: 40, y: 40, width: 300, height: 400), body: body, siblings: [], gap: 20))
    }

    func testMaterialPathIsContinuousAndHasExactEndpoints() {
        let from = CGRect(x: 400, y: 400, width: 160, height: 160)
        let to = CGRect(x: 150, y: 100, width: 320, height: 440)
        XCTAssertEqual(CollageGeometry.interpolated(from, to, progress: 0), from)
        XCTAssertEqual(CollageGeometry.interpolated(from, to, progress: 1), to)
        var previous = from
        for step in 1...120 {
            let next = CollageGeometry.interpolated(from, to, progress: Double(step) / 120)
            XCTAssertLessThan(abs(next.minX - previous.minX), 4)
            XCTAssertLessThan(abs(next.height - previous.height), 5)
            previous = next
        }
    }

    @MainActor
    func testAttachPreservesOriginalImageFrameAndAppearanceAndReloadsMembership() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            let original = manager.photos.first { $0.id == photo }!
            let frame = manager.windows[photo]!.photoFrame
            try attach(manager, photo: photo, parent: parent, at: frame)
            let added = manager.photos.first { $0.id == photo }!
            XCTAssertEqual(added.collageParentID, parent)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, frame)
            XCTAssertEqual(added.matWidth, original.matWidth)
            XCTAssertEqual(added.tiltDegrees, original.tiltDegrees)
            XCTAssertEqual(added.filename, original.filename)
            let reloaded = PhotoManager(storageDirectory: manager.storageDir)
            defer { reloaded.cancelCollageInteractions(); reloaded.windows.values.forEach { $0.hidePhoto() }; reloaded.windows.removeAll() }
            XCTAssertEqual(reloaded.photos.first { $0.id == photo }?.collageParentID, parent)
            XCTAssertNotNil(reloaded.windows[parent] as? CollageDesktopWindow)
            XCTAssertEqual(reloaded.windows[photo]?.photoFrame, frame)
        }
    }

    @MainActor
    func testSharedCollagePlacementPreservesStandaloneSettingsThroughReloadAndDetach() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            manager.setDepth(photo, .aboveWidgets)
            manager.setSpaceBound(photo, true)
            let original = manager.photos.first { $0.id == photo }!
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            manager.setDepth(parent, .floating)
            manager.setSpaceBound(parent, false)
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            manager.setDepth(photo, .onDesktop)
            manager.setSpaceBound(photo, false)
            XCTAssertEqual(manager.photos.first { $0.id == parent }!.depth, .onDesktop)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.depth, original.depth)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.isSpaceBound, original.isSpaceBound)
            manager.setTilt(photo, 7)
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            settings.caption = "Shared placement"
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings, depth: .floating, isSpaceBound: false))
            manager.loadSaved()
            let grouped = manager.photos.first { $0.id == photo }!
            XCTAssertEqual(manager.effectiveDepth(of: grouped), .floating)
            XCTAssertEqual(grouped.depth, original.depth)
            XCTAssertEqual(grouped.isSpaceBound, original.isSpaceBound)
            XCTAssertEqual(grouped.matWidth, original.matWidth)
            XCTAssertEqual(grouped.shadowEnabled, original.shadowEnabled)
            XCTAssertEqual(grouped.tiltDegrees, 7)
            XCTAssertEqual(manager.windows[photo]!.level, WidgetDepth.floating.windowLevel)
            XCTAssertTrue(manager.windows[photo]!.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(manager.removeFromCollage(photo))
            let detached = manager.photos.first { $0.id == photo }!
            XCTAssertNil(detached.collageParentID)
            XCTAssertEqual(detached.depth, original.depth)
            XCTAssertEqual(detached.isSpaceBound, original.isSpaceBound)
            XCTAssertEqual(detached.tiltDegrees, 7)
            XCTAssertEqual(manager.windows[photo]!.level, original.depth.windowLevel)
            XCTAssertFalse(manager.windows[photo]!.collectionBehavior.contains(.canJoinAllSpaces))
        }
    }

    @MainActor
    func testSecondPhotoSnapsGapAndDetachStaysAtDropPosition() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 600, y: 200, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: first, parent: parent, at: manager.windows[first]!.photoFrame)
            try attach(manager, photo: second, parent: parent, at: CGRect(x: 306, y: 216, width: 120, height: 120))
            XCTAssertEqual(manager.windows[second]?.photoFrame, CGRect(x: 300, y: 220, width: 120, height: 120))
            manager.beginCollageDrag(second)
            let outside = CGRect(x: 850, y: 500, width: 120, height: 120)
            XCTAssertNil(manager.proposeCollageDrag(second, frame: outside, bypassSnap: false))
            manager.windows[second]?.setPhotoFrame(outside)
            XCTAssertTrue(manager.finishCollageDrag(second))
            XCTAssertNil(manager.photos.first { $0.id == second }?.collageParentID)
            XCTAssertEqual(manager.windows[second]?.photoFrame, outside)
        }
    }

    @MainActor
    func testMoveTranslatesWholeGroupAndRemoveKeepsMediaAndFrames() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let original = manager.windows[photo]!.photoFrame
            let oldParent = manager.windows[parent]!.photoFrame
            manager.moveCollage(parent, to: oldParent.offsetBy(dx: 54, dy: -32), finished: true)
            XCTAssertEqual(manager.windows[photo]?.photoFrame, original.offsetBy(dx: 54, dy: -32))
            manager.removePhoto(parent)
            XCTAssertEqual(manager.photos.count, 1)
            XCTAssertNil(manager.photos.first?.collageParentID)
            XCTAssertEqual(manager.windows[photo]?.photoFrame, original.offsetBy(dx: 54, dy: -32))
            XCTAssertTrue(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(manager.photos[0].filename).path))
        }
    }

    @MainActor
    func testGroupDragPreviewsWithoutPublishingPhotosOrReorderingEveryStep() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 1
            let pickup = group.photoFrame
            let memberPickup = manager.windows[photo]!.photoFrame
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let modelFrames = manager.photos.map(\.frameString)
            group.onMoveBegan?()
            XCTAssertTrue(manager.windows[photo]!.parent === group)
            var publications = 0, orderingCallbacks = 0
            let observation = manager.objectWillChange.sink { publications += 1 }
            defer { observation.cancel() }
            let ordering = group.onWindowInteraction
            group.onWindowInteraction = { orderingCallbacks += 1; ordering?() }
            for step in 1...100 {
                manager.moveCollage(parent, to: pickup.offsetBy(dx: CGFloat(step), dy: CGFloat(step) / 2), finished: false)
            }
            XCTAssertEqual(publications, 0, "Dragging must not rebuild the SwiftUI Photos list")
            XCTAssertEqual(orderingCallbacks, 0, "Translating windows must not repeatedly restack them")
            XCTAssertEqual(manager.photos.map(\.frameString), modelFrames)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, memberPickup.offsetBy(dx: 100, dy: 50))
            XCTAssertEqual(group.displayedBounds, pickup.offsetBy(dx: 100, dy: 50))
            let native = manager.windows[photo]!.frame
            let proposed = manager.windows[photo]!.windowFrame(forPhoto: manager.windows[photo]!.photoFrame)
            // Child movement submits WindowServer-rounded frames. Preserve the
            // precise scene while allowing its existing sub-point quantization.
            for (actual, expected) in [(native.minX, proposed.minX), (native.minY, proposed.minY),
                                       (native.width, proposed.width), (native.height, proposed.height)] {
                XCTAssertLessThanOrEqual(abs(actual - expected), 1)
            }
            group.onMoveCancelled?()
            XCTAssertNil(manager.windows[photo]!.parent)
            XCTAssertGreaterThan(publications, 0, "Cancellation must refresh Undo availability")
            XCTAssertEqual(group.photoFrame, pickup)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, memberPickup)
            XCTAssertEqual(manager.photos.map(\.frameString), modelFrames)
            group.onMoveBegan?()
            manager.moveCollage(parent, to: pickup.offsetBy(dx: 100, dy: 50), finished: false)
            manager.moveCollage(parent, to: group.photoFrame, finished: true)
            XCTAssertNil(manager.windows[photo]!.parent)
            XCTAssertEqual(NSRectFromString(manager.photos.first { $0.id == photo }!.frameString), memberPickup.offsetBy(dx: 100, dy: 50))
            XCTAssertTrue(manager.collageMoveSnapshots.isEmpty)
            manager.loadSaved()
            XCTAssertEqual(manager.windows[photo]!.photoFrame, memberPickup.offsetBy(dx: 100, dy: 50))
        }
    }

    @MainActor
    func testNativeGroupDragReleasesFollowersBeforeFailedSaveAndIndependentPhotoEditing() throws {
        for depth in [WidgetDepth.onDesktop, .floating] {
            try withManager { manager in
                let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
                let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
                let group = manager.windows[parent] as! CollageDesktopWindow
                var settings = group.settings
                settings.caption = "Native group movement"
                XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                manager.setDepth(parent, depth)
                group.transition?.currentProgress = 1
                let member = manager.windows[photo]!
                let label = try XCTUnwrap(manager.collageLabelWindows[parent])
                let original = member.photoFrame
                let pickup = group.photoFrame
                let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                group.onMoveBegan?()
                XCTAssertTrue(member.parent === group)
                XCTAssertTrue(label.parent === group)
                manager.moveCollage(parent, to: pickup.offsetBy(dx: 40, dy: 25), finished: false)
                XCTAssertEqual(member.photoFrame, original.offsetBy(dx: 40, dy: 25))
                XCTAssertEqual(member.frame, member.windowFrame(forPhoto: member.photoFrame))
                XCTAssertEqual(label.frame, group.displayedBounds)
                try assertAbove(label, member)
                try assertAbove(member, group)
                // The existing save guard rejects corrupt storage. Rollback
                // must detach first, or restoring the parent moves photos twice.
                try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
                manager.moveCollage(parent, to: group.photoFrame, finished: true)
                XCTAssertNil(member.parent)
                XCTAssertNil(label.parent)
                XCTAssertEqual(member.photoFrame, original)
                XCTAssertEqual(member.frame, member.windowFrame(forPhoto: original))
                XCTAssertEqual(group.photoFrame, pickup)
                try saved.write(to: manager.storageDir.appendingPathComponent("photos.json"))
                manager.loadSaved()
                let reloadedGroup = manager.windows[parent] as! CollageDesktopWindow
                let reloadedMember = manager.windows[photo]!
                reloadedGroup.onMoveBegan?()
                reloadedGroup.onMoveFinishedWithoutChange?()
                XCTAssertNil(reloadedMember.parent)
                XCTAssertNil(manager.collageLabelWindows[parent]?.parent)
                let view = reloadedMember.contentView as! DraggablePhotoView
                let point = CGPoint(x: original.midX, y: original.midY)
                let drop = CGPoint(x: point.x + 8, y: point.y + 6)
                view.mouseDown(with: try mouseEvent(.leftMouseDown, in: reloadedMember, at: point))
                view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: reloadedMember, at: drop, modifiers: .option))
                view.mouseUp(with: try mouseEvent(.leftMouseUp, in: reloadedMember, at: drop))
                XCTAssertEqual(reloadedMember.photoFrame, original.offsetBy(dx: 8, dy: 6))
                XCTAssertEqual(manager.photos.first { $0.id == photo }?.collageParentID, parent)
            }
        }
    }

    @MainActor
    func testBackgroundDragDuringBoundaryAnimationKeepsExplicitPlacementAndCancelsForDepthChange() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "This transition-in-progress check requires system animations; Reduce Motion intentionally completes synchronously.")
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 1
            let pickup = group.photoFrame
            let original = manager.windows[photo]!.photoFrame
            group.fit(to: pickup.insetBy(dx: -70, dy: -50))
            let transition = try XCTUnwrap(group.transition)
            transition.currentProgress = 0.3
            group.onMoveBegan?()
            XCTAssertTrue(manager.collageMoveSnapshots[parent]!.nativeFollowers.isEmpty)
            manager.moveCollage(parent, to: group.photoFrame.offsetBy(dx: 20, dy: 10), finished: false)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, original.offsetBy(dx: 20, dy: 10))
            XCTAssertNil(manager.windows[photo]!.parent)
            XCTAssertTrue(group.frame.contains(group.displayedBounds))
            manager.setDepth(parent, .floating)
            XCTAssertTrue(manager.collageMoveSnapshots.isEmpty)
            XCTAssertEqual(group.photoFrame, pickup)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, original)
            XCTAssertEqual(manager.windows[photo]!.level, WidgetDepth.floating.windowLevel)
            group.onMoveBegan?()
            XCTAssertTrue(manager.windows[photo]!.parent === group)
            manager.moveCollage(parent, to: pickup.offsetBy(dx: 20, dy: 10), finished: false)
            manager.setSpaceBound(parent, true)
            XCTAssertNil(manager.windows[photo]!.parent)
            XCTAssertTrue(manager.collageMoveSnapshots.isEmpty)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, original)
            XCTAssertTrue(manager.photos.first { $0.id == parent }!.isSpaceBound)
        }
    }

    @MainActor
    func testFloatingGroupMoveKeepsNativeFramesAlignedAtScreenEdges() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let group = manager.windows[parent] as! CollageDesktopWindow
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            settings.caption = "At the screen edge"
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            group.transition?.currentProgress = 1
            manager.setDepth(parent, .floating)
            let pickup = group.photoFrame
            group.onMoveBegan?()
            XCTAssertTrue(manager.windows[photo]!.parent === group)
            XCTAssertTrue(manager.collageLabelWindows[parent]?.parent === group)
            let screen = try XCTUnwrap(NSScreen.main).frame
            for origin in [CGPoint(x: 650, y: 200), CGPoint(x: 650, y: screen.maxY - 100), CGPoint(x: 650, y: -400), CGPoint(x: 300, y: 200)] {
                manager.moveCollage(parent, to: CGRect(origin: origin, size: pickup.size), finished: false)
                for window in [manager.windows[photo]!, group] {
                    XCTAssertEqual(window.frame, window.windowFrame(forPhoto: window.photoFrame), "Native window and photo geometry diverged at \(origin)")
                }
                XCTAssertEqual(manager.collageLabelWindows[parent]?.frame, group.displayedBounds)
                let surface = try XCTUnwrap(group.contentView)
                let material = try XCTUnwrap(surface.subviews.first)
                XCTAssertEqual(group.convertToScreen(surface.convert(material.frame, to: nil)), group.displayedBounds)
            }
            manager.moveCollage(parent, to: group.photoFrame, finished: true)
            XCTAssertNil(manager.windows[photo]!.parent)
            XCTAssertNil(manager.collageLabelWindows[parent]?.parent)
        }
    }

    @MainActor
    func testGroupMovementCorrectsNativeOriginDriftWithoutRelayout() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 1
            let member = manager.windows[photo]!
            let pickup = group.photoFrame
            let memberPickup = member.photoFrame
            XCTAssertFalse(group.isMovable)
            XCTAssertFalse(member.isMovable)
            XCTAssertFalse(group.contentView!.mouseDownCanMoveWindow)
            XCTAssertFalse(member.contentView!.mouseDownCanMoveWindow)
            // Emulate a native-origin change that bypassed Arras's logical scene.
            // The next gesture proposal must use absolute scene coordinates.
            group.setFrameOrigin(group.frame.origin.applying(CGAffineTransform(translationX: -160, y: -158)))
            member.setFrameOrigin(member.frame.origin.applying(CGAffineTransform(translationX: -160, y: -158)))
            manager.moveCollage(parent, to: pickup, finished: false)
            XCTAssertEqual(group.frame, group.windowFrame(forPhoto: group.photoFrame))
            XCTAssertEqual(member.frame, member.windowFrame(forPhoto: member.photoFrame))
            manager.moveCollage(parent, to: pickup.offsetBy(dx: 20, dy: 10), finished: false)
            XCTAssertEqual(group.frame, group.windowFrame(forPhoto: group.photoFrame))
            XCTAssertEqual(member.frame, member.windowFrame(forPhoto: member.photoFrame))
            XCTAssertEqual(member.photoFrame, memberPickup.offsetBy(dx: 20, dy: 10))
            manager.moveCollage(parent, to: group.photoFrame, finished: true)
        }
    }

    @MainActor
    func testParentVisibilityAndLockDoNotChangeChildPreferences() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            manager.toggleLock(parent)
            XCTAssertTrue((manager.windows[photo]?.contentView as? DraggablePhotoView)?.isLocked == true)
            XCTAssertFalse(manager.photos.first { $0.id == photo }!.isLocked)
            manager.toggleLock(parent)
            manager.toggleVisibility(parent)
            XCTAssertNil(manager.windows[photo])
            XCTAssertTrue(manager.photos.first { $0.id == photo }!.isVisible)
            manager.toggleVisibility(parent)
            XCTAssertNotNil(manager.windows[photo])
            XCTAssertFalse((manager.windows[photo]?.contentView as? DraggablePhotoView)!.isLocked)
        }
    }

    @MainActor
    func testFailedSettingsWidthSavePreservesPhotoAndCollageGeometry() throws {
        for grouped in [false, true] {
            try withManager { manager in
                let id = try makePhoto(manager, frame: CGRect(x: 200, y: 200, width: 180, height: 240))
                var parentID: UUID?
                if grouped {
                    let parent = try makeContainer(manager, frame: CGRect(x: 180, y: 180, width: 240, height: 300))
                    try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame)
                    var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
                    settings.caption = "Keep this collage"
                    XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                    parentID = parent
                }
                manager.cancelCollageInteractions()
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let before = try encoder.encode(manager.photos)
                let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                let frames = manager.windows.mapValues(\.photoFrame)
                let windows = manager.windows
                let labels = manager.collageLabelWindows
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                manager.resize(id, to: 360)
                XCTAssertEqual(try encoder.encode(manager.photos), before, "grouped=\(grouped)")
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored)
                for (key, window) in windows {
                    XCTAssertTrue(manager.windows[key] === window)
                    XCTAssertEqual(window.photoFrame, frames[key], "grouped=\(grouped)")
                }
                for (key, label) in labels { XCTAssertTrue(manager.collageLabelWindows[key] === label) }

                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path)
                for width in [CGFloat(360), 90] {
                    manager.resize(id, to: width)
                    XCTAssertEqual(manager.windows[id]?.photoFrame.width, width)
                    XCTAssertEqual(manager.photos.first { $0.id == id }?.widgetWidth, width)
                    if let parentID {
                        let parent = manager.photos.first { $0.id == parentID }!
                        XCTAssertTrue(NSRectFromString(parent.frameString).contains(manager.collageFootprint(manager.photos.first { $0.id == id }!)))
                        XCTAssertEqual(manager.windows[parentID]?.photoFrame, NSRectFromString(parent.frameString))
                    }
                }
            }
        }
    }

    @MainActor
    func testSettingsWidthSurvivesHiddenStateAndSavedSetupRestore() throws {
        for kind in ["photo", "slideshow", "member"] {
            try withManager { manager in
                let id: UUID
                if kind == "member" {
                    id = try makePhoto(manager, frame: CGRect(x: 200, y: 200, width: 180, height: 240))
                    let parent = try makeContainer(manager, frame: CGRect(x: 180, y: 180, width: 240, height: 300))
                    try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame)
                    manager.toggleVisibility(id)
                } else {
                    XCTAssertTrue(manager.addStarterExample(kind == "slideshow" ? .rotatingSpace : .minimal, makeVisible: false))
                    id = try XCTUnwrap(manager.photos.first?.id)
                    if kind == "slideshow" { manager.setRotationInterval(id, "click") }
                }
                manager.cancelCollageInteractions()
                let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == id })
                manager.photos[index].displayIdentifier = "offline-display"
                manager.photos[index].savedDisplayFrames = [
                    "offline-display": manager.photos[index].frameString,
                    "other-display": "{{900, 500}, {160, 120}}"
                ]
                XCTAssertTrue(manager.persist())
                let original = try XCTUnwrap(manager.photos.first { $0.id == id })
                let frame = NSRectFromString(original.frameString)
                XCTAssertNil(manager.windows[id])
                let width = frame.width * 1.5
                manager.resize(id, to: width)
                let resized = try XCTUnwrap(manager.photos.first { $0.id == id })
                XCTAssertEqual(NSRectFromString(resized.frameString).width, width, kind)
                XCTAssertEqual(NSRectFromString(resized.frameString).height, frame.height * 1.5, accuracy: 0.01, kind)
                XCTAssertEqual(resized.collageParentID, original.collageParentID)
                XCTAssertEqual(resized.displayIdentifier, original.displayIdentifier, kind)
                XCTAssertEqual(resized.savedDisplayFrames["other-display"], original.savedDisplayFrames["other-display"], kind)
                XCTAssertEqual(resized.savedDisplayFrames["offline-display"].map { NSRectFromString($0).width }, width, kind)
                if let name = resized.spaceImageFilenames.first {
                    XCTAssertEqual(resized.folderImageConfigs[name]?.widgetWidth, width)
                }
                let setup = try manager.saveDesktopSetup(named: "Resized sample")
                manager.toggleVisibility(id)
                XCTAssertEqual(try XCTUnwrap(manager.windows[id]).photoFrame.width, width, accuracy: 0.01, kind)
                try manager.activateDesktopSetup(setup)
                XCTAssertNil(manager.windows[id])
                manager.toggleVisibility(id)
                XCTAssertEqual(try XCTUnwrap(manager.windows[id]).photoFrame.width, width, accuracy: 0.01, kind)
                XCTAssertEqual(manager.photos.first { $0.id == id }?.collageParentID, original.collageParentID)
            }
        }
    }

    @MainActor
    func testFailedFadeAndRevealSavesPreservePhotoCollageAndCaptionAppearance() throws {
        for target in ["photo", "member", "collage"] {
            for control in target == "collage" ? ["opacity"] : ["opacity", "reveal"] {
                try withManager { manager in
                    let member = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
                    let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                    try attach(manager, photo: member, parent: parent, at: manager.windows[member]!.photoFrame)
                    let standalone = try makePhoto(manager, frame: CGRect(x: 600, y: 400, width: 120, height: 100), styled: false)
                    var settings = try XCTUnwrap(manager.photos.first { $0.id == parent }?.desktopCollage)
                    settings.caption = "Sample collage"
                    XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                    manager.cancelCollageInteractions()
                    let id = target == "photo" ? standalone : (target == "member" ? member : parent)
                    manager.setOpacity(id, 0.65)
                    let window = try XCTUnwrap(manager.windows[id])
                    if let view = window.contentView as? DraggablePhotoView {
                        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
                            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, trackingNumber: 0, userData: nil))
                        view.mouseExited(with: exit)
                    }
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                    let frame = window.photoFrame
                    let alpha = window.contentView?.alphaValue
                    let label = manager.collageLabelWindows[parent]
                    let labelAlpha = label?.alphaValue
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }

                    if control == "opacity" { manager.setOpacity(id, 0.3) }
                    else { manager.setRevealOnHover(id, true) }
                    let context = "\(target), \(control)"
                    XCTAssertEqual(try encoder.encode(manager.photos), before, context)
                    XCTAssertEqual(window.configuredOpacity, 0.65, context)
                    // Re-evaluate the window's effective alpha without animation;
                    // this also observes whether its private reveal state changed.
                    window.setPhotoOpacity(window.configuredOpacity)
                    XCTAssertEqual(window.contentView?.alphaValue, alpha, context)
                    XCTAssertEqual(window.photoFrame, frame, context)
                    XCTAssertTrue(manager.collageLabelWindows[parent] === label, context)
                    XCTAssertEqual(label?.alphaValue, labelAlpha, context)
                    XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored, context)
                }
            }
        }
    }

    @MainActor
    func testWidgetScrollOpacityCommitsBeforeChangingLiveAppearance() throws {
        for grouped in [false, true] {
            try withManager { manager in
                let id = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
                if grouped {
                    let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                    try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame)
                }
                manager.cancelCollageInteractions()
                manager.setOpacity(id, 0.65)
                let window = try XCTUnwrap(manager.windows[id])
                let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
                XCTAssertFalse(view.isLocked)
                // Construct an event for this view's handler only. It is never
                // posted to the system or sent to the user's mouse/foreground app.
                let raw = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                    wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0))
                let scroll = try XCTUnwrap(NSEvent(cgEvent: raw))
                XCTAssertLessThan(scroll.deltaY, 0)
                view.scrollWheel(with: scroll)
                let opacity = try XCTUnwrap(manager.photos.first { $0.id == id }?.opacity)
                XCTAssertLessThan(opacity, 0.65)
                XCTAssertEqual(window.configuredOpacity, opacity)
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let before = try encoder.encode(manager.photos)
                let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                let saved = try JSONDecoder().decode([PhotoItem].self, from: stored)
                XCTAssertEqual(saved.first { $0.id == id }?.opacity, opacity)

                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                view.scrollWheel(with: scroll)
                XCTAssertEqual(try encoder.encode(manager.photos), before, "grouped=\(grouped)")
                XCTAssertEqual(window.configuredOpacity, opacity, "grouped=\(grouped)")
                XCTAssertEqual(view.alphaValue, opacity, "grouped=\(grouped)")
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored)
            }
        }
    }

    @MainActor
    func testFailedGlobalVisibilitySaveReturnsTheActualStateAndPreservesTheDesktop() throws {
        for initiallyVisible in [true, false] {
            try withManager { manager in
                let member = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
                let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                try attach(manager, photo: member, parent: parent, at: manager.windows[member]!.photoFrame)
                _ = try makePhoto(manager, frame: CGRect(x: 600, y: 400, width: 120, height: 100), styled: false)
                var settings = try XCTUnwrap(manager.photos.first { $0.id == parent }?.desktopCollage)
                settings.caption = "Sample collage"
                XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                manager.cancelCollageInteractions()
                if !initiallyVisible { XCTAssertFalse(manager.toggleAllVisibility()) }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let before = try encoder.encode(manager.photos)
                let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                let windows = manager.windows
                let labels = manager.collageLabelWindows
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                XCTAssertEqual(manager.toggleAllVisibility(), initiallyVisible,
                               "A failed global toggle must return the current state to Shortcuts")
                XCTAssertEqual(try encoder.encode(manager.photos), before)
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored)
                XCTAssertEqual(Set(manager.windows.keys), Set(windows.keys))
                for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
                XCTAssertEqual(Set(manager.collageLabelWindows.keys), Set(labels.keys))
                for (id, window) in labels { XCTAssertTrue(manager.collageLabelWindows[id] === window) }
            }
        }
    }

    @MainActor
    func testGlobalVisibilityRestoresCompleteCollagesWithoutDuplicateMemberWindows() throws {
        try withManager { manager in
            var parents: [UUID] = []
            var members: [UUID] = []
            for offset in [CGFloat(0), 500] {
                let member = try makePhoto(manager, frame: CGRect(x: 100 + offset, y: 100, width: 180, height: 240), styled: false)
                let sibling = try makePhoto(manager, frame: CGRect(x: 300 + offset, y: 120, width: 150, height: 180), styled: false)
                let parent = try makeContainer(manager, frame: CGRect(x: 100 + offset, y: 150, width: 160, height: 160))
                for id in [member, sibling] {
                    try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame)
                }
                var settings = try XCTUnwrap(manager.photos.first { $0.id == parent }?.desktopCollage)
                settings.caption = "Sample collage"
                XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                manager.setDepth(parent, offset == 0 ? .onDesktop : .floating)
                manager.toggleVisibility(member)
                parents.append(parent)
                members.append(contentsOf: [member, sibling])
            }
            manager.cancelCollageInteractions()
            let membership = Dictionary(uniqueKeysWithValues: manager.photos.map { ($0.id, $0.collageParentID) })
            XCTAssertFalse(manager.toggleAllVisibility())
            XCTAssertTrue(manager.photos.allSatisfy { !$0.isVisible })
            XCTAssertTrue(manager.windows.isEmpty)
            XCTAssertTrue(manager.rotationTimers.isEmpty)
            XCTAssertTrue(manager.collageLabelWindows.isEmpty)
            XCTAssertTrue(manager.toggleAllVisibility())
            manager.cancelCollageInteractions()
            XCTAssertTrue(manager.photos.allSatisfy(\.isVisible))
            XCTAssertEqual(Set(manager.windows.keys), Set(manager.photos.map(\.id)))
            let ids = Set(manager.photos.map(\.id))
            XCTAssertEqual(NSApp.windows.compactMap { $0 as? DesktopPhotoWindow }
                .filter { $0.photoId.map(ids.contains) == true }.count, ids.count,
                "Restoring a collage must not leave an untracked second panel for a member")
            for item in manager.photos {
                XCTAssertEqual(item.collageParentID, membership[item.id]!)
                XCTAssertEqual(manager.windows[item.id]?.level, manager.effectiveDepth(of: item).windowLevel)
            }
            for parent in parents {
                let frame = try XCTUnwrap(manager.windows[parent]?.photoFrame)
                for member in manager.collageMembers(parent) {
                    XCTAssertTrue(frame.contains(manager.collageFootprint(member)))
                }
                XCTAssertNotNil(manager.collageLabelWindows[parent])
            }
            let saved = try JSONDecoder().decode([PhotoItem].self, from:
                Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            XCTAssertTrue(saved.allSatisfy(\.isVisible))
            XCTAssertEqual(Set(saved.filter { $0.collageParentID != nil }.map(\.id)), Set(members))
        }
    }

    @MainActor
    func testFailedVisibilitySavePreservesPhotosCollageAndLabelWindows() throws {
        for target in ["photo", "member", "collage"] {
            for initiallyVisible in [true, false] {
                try withManager { manager in
                    let member = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
                    let sibling = try makePhoto(manager, frame: CGRect(x: 300, y: 120, width: 150, height: 180), styled: false)
                    let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                    for id in [member, sibling] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
                    let standalone = try makePhoto(manager, frame: CGRect(x: 600, y: 400, width: 120, height: 100), styled: false)
                    var settings = try XCTUnwrap(manager.photos.first { $0.id == parent }?.desktopCollage)
                    settings.caption = "Sample collage"
                    XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                    let id = target == "photo" ? standalone : (target == "member" ? member : parent)
                    if !initiallyVisible { manager.toggleVisibility(id) }
                    manager.cancelCollageInteractions()
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let windows = manager.windows
                    let frames = windows.mapValues(\.photoFrame)
                    let labels = manager.collageLabelWindows
                    let names = try FileManager.default.contentsOfDirectory(atPath: manager.storageDir.path)
                    let stored = try Dictionary(uniqueKeysWithValues: names.map { name in
                        (name, try Data(contentsOf: manager.storageDir.appendingPathComponent(name)))
                    })
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                    manager.toggleVisibility(id)
                    let context = "\(target), visible=\(initiallyVisible)"
                    XCTAssertEqual(try encoder.encode(manager.photos), before, context)
                    XCTAssertEqual(Set(manager.windows.keys), Set(windows.keys), context)
                    for (key, window) in windows {
                        XCTAssertTrue(manager.windows[key] === window, context)
                        XCTAssertEqual(manager.windows[key]?.photoFrame, frames[key], context)
                    }
                    XCTAssertEqual(Set(manager.collageLabelWindows.keys), Set(labels.keys), context)
                    for (key, window) in labels { XCTAssertTrue(manager.collageLabelWindows[key] === window, context) }
                    for (name, data) in stored {
                        XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(name)), data, context)
                    }
                }
            }
        }
    }

    @MainActor
    func testFailedDepthAndSpaceSavesKeepLivePlacementAndStandalonePreferences() throws {
        for target in ["photo", "member", "collage"] {
            for action in ["floating", "behind icons", "pin", "unpin"] {
                try withManager { manager in
                    let child = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
                    manager.setDepth(child, .aboveWidgets)
                    manager.setSpaceBound(child, true)
                    let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                    try attach(manager, photo: child, parent: parent, at: manager.windows[child]!.photoFrame)
                    let photo = try makePhoto(manager, frame: CGRect(x: 600, y: 400, width: 120, height: 100), styled: false)
                    var settings = try XCTUnwrap(manager.photos.first { $0.id == parent }?.desktopCollage)
                    settings.caption = "Sample placement"
                    XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
                    let id = target == "photo" ? photo : (target == "member" ? child : parent)
                    manager.setSpaceBound(id, action == "unpin")
                    manager.cancelCollageInteractions()
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let file = manager.storageDir.appendingPathComponent("photos.json")
                    let stored = try Data(contentsOf: file)
                    let windows = manager.windows
                    let levels = windows.mapValues(\.level)
                    let behaviors = windows.mapValues(\.collectionBehavior)
                    let locks = windows.mapValues {
                        ($0.contentView as? DraggablePhotoView)?.isLocked ?? ($0.contentView as? CollageSurfaceView)?.locked ?? false
                    }
                    let labels = manager.collageLabelWindows
                    let labelLevels = labels.mapValues(\.level)
                    let labelBehaviors = labels.mapValues(\.collectionBehavior)
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                    switch action {
                    case "floating": manager.setDepth(id, .floating)
                    case "behind icons": manager.setDepth(id, .behindIcons)
                    case "pin": manager.setSpaceBound(id, true)
                    default: manager.setSpaceBound(id, false)
                    }
                    let context = "\(target), \(action)"
                    XCTAssertEqual(try encoder.encode(manager.photos), before, context)
                    XCTAssertEqual(try Data(contentsOf: file), stored, context)
                    for (key, window) in windows {
                        XCTAssertTrue(manager.windows[key] === window, context)
                        XCTAssertEqual(window.level, levels[key], context)
                        XCTAssertEqual(window.collectionBehavior, behaviors[key], context)
                        let locked = (window.contentView as? DraggablePhotoView)?.isLocked ?? (window.contentView as? CollageSurfaceView)?.locked ?? false
                        XCTAssertEqual(locked, locks[key], context)
                    }
                    for (key, window) in labels {
                        XCTAssertTrue(manager.collageLabelWindows[key] === window, context)
                        XCTAssertEqual(window.level, labelLevels[key], context)
                        XCTAssertEqual(window.collectionBehavior, labelBehaviors[key], context)
                    }
                }
            }
        }
    }

    @MainActor
    func testFailedStackOrderSavePreservesModelAndWindowServerOrder() throws {
        for target in ["photo", "member", "collage"] {
            for forward in [true, false] {
                try withManager { manager in
                    let child = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
                    let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
                    try attach(manager, photo: child, parent: parent, at: manager.windows[child]!.photoFrame)
                    let photo = try makePhoto(manager, frame: CGRect(x: 600, y: 400, width: 120, height: 100), styled: false)
                    let root = target == "photo" ? photo : parent
                    let id = target == "member" ? child : root
                    for index in manager.photos.indices {
                        manager.photos[index].stackOrder = manager.photos[index].id == root ? (forward ? 0 : 100) : 50
                    }
                    XCTAssertTrue(manager.persist())
                    manager.cancelCollageInteractions()
                    manager.syncCollages()
                    let ids = Set(manager.windows.values.map(\.windowNumber))
                    @MainActor func order() throws -> [Int] {
                        NSApp.updateWindows()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                        let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
                        return rows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }.filter { ids.contains($0) }
                    }
                    let orderBefore = try order()
                    XCTAssertEqual(Set(orderBefore), ids)
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let file = manager.storageDir.appendingPathComponent("photos.json")
                    let stored = try Data(contentsOf: file)
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                    if forward { manager.bringToFront(id) } else { manager.sendToBack(id) }
                    let context = "\(target), forward=\(forward)"
                    XCTAssertEqual(try encoder.encode(manager.photos), before, context)
                    XCTAssertEqual(try Data(contentsOf: file), stored, context)
                    XCTAssertEqual(try order(), orderBefore, context)
                }
            }
        }
    }

    @MainActor
    func testCancelledDragLeavesModelAndDiskUnchanged() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            _ = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let data = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let original = manager.photos
            manager.beginCollageDrag(photo)
            manager.windows[photo]?.setPhotoOrigin(CGPoint(x: 390, y: 150))
            _ = manager.proposeCollageDrag(photo, frame: manager.windows[photo]!.photoFrame, bypassSnap: false)
            manager.cancelCollageDrag(photo)
            manager.collageFlights[photo]?.currentProgress = 1
            XCTAssertEqual(manager.windows[photo]?.photoFrame, NSRectFromString(original.first { $0.id == photo }!.frameString))
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), data)
        }
    }

    @MainActor
    func testFailedMembershipWriteRestoresPickupAndDoesNotEraseCorruptStore() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let pickup = manager.windows[photo]!.photoFrame
            let committedParent = manager.windows[parent]!.photoFrame
            manager.setDepth(parent, .aboveWidgets)
            let corrupt = Data("damaged".utf8)
            try corrupt.write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.beginCollageDrag(photo)
            let drop = pickup.offsetBy(dx: 320, dy: 0)
            manager.windows[photo]?.setPhotoFrame(manager.proposeCollageDrag(photo, frame: drop, bypassSnap: true) ?? drop)
            XCTAssertEqual(manager.collageDrags[photo]?.targetID, parent)
            XCTAssertTrue(manager.finishCollageDrag(photo))
            manager.collageFlights[photo]?.currentProgress = 1
            XCTAssertNil(manager.photos.first { $0.id == photo }?.collageParentID)
            XCTAssertEqual(manager.windows[photo]?.photoFrame, pickup)
            XCTAssertEqual(manager.windows[parent]?.photoFrame, committedParent)
            XCTAssertEqual(manager.windows[photo]?.level, NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1))
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), corrupt)
        }
    }

    @MainActor
    func testFailedGroupRemovalPreservesAllWindowsAndMembers() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.removePhoto(parent)
            XCTAssertEqual(manager.photos.count, 2)
            XCTAssertEqual(manager.photos.first { $0.id == photo }?.collageParentID, parent)
            XCTAssertNotNil(manager.windows[parent])
            XCTAssertNotNil(manager.windows[photo])
        }
    }

    @MainActor
    func testArchiveRemapsCollageAndChildIDsAndRetainsCaption() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            var settings = DesktopCollageSettings(skin: .polaroid); settings.caption = "Summer, 2026"
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let archive = manager.storageDir.appendingPathComponent("test.arras")
            try manager.exportLayout(to: archive)
            XCTAssertEqual(try manager.importLayout(from: archive, mode: .merge), 2)
            let importedParent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil && $0.id != parent })
            XCTAssertEqual(importedParent.desktopCollage?.caption, "Summer, 2026")
            XCTAssertEqual(manager.collageMembers(importedParent.id).count, 1)
            XCTAssertNotEqual(manager.collageMembers(importedParent.id)[0].id, photo)
        }
    }

    func testGapEditingPreservesRowsAndDoesNotRepackFreePlacements() {
        let frames = [CGRect(x: 100, y: 100, width: 180, height: 240), CGRect(x: 300, y: 220, width: 120, height: 120), CGRect(x: 700, y: 400, width: 140, height: 90)]
        let changed = CollageGeometry.changingGap(frames, from: 20, to: 40)
        XCTAssertEqual(changed[0], frames[0])
        XCTAssertEqual(changed[1].minX - changed[0].maxX, 40)
        XCTAssertEqual(changed[1].maxY, changed[0].maxY)
        XCTAssertEqual(changed[2], frames[2])
    }

    @MainActor
    func testScreenPointerDragDropsIntoCollage() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let window = manager.windows[photo]!
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            @MainActor func event(_ type: NSEvent.EventType, screen: CGPoint) throws -> NSEvent {
                try testMouseEvent(type, in: window, at: screen)
            }
            let start = CGPoint(x: 190, y: 240)
            let drop = CGPoint(x: 480, y: 240)
            view.mouseDown(with: try event(.leftMouseDown, screen: start))
            view.mouseDragged(with: try event(.leftMouseDragged, screen: drop))
            view.mouseUp(with: try event(.leftMouseUp, screen: drop))
            XCTAssertEqual(manager.photos.first { $0.id == photo }?.collageParentID, parent)
            XCTAssertEqual(window.photoFrame, CGRect(x: 390, y: 120, width: 180, height: 240))
        }
    }

    @MainActor
    func testGapSettingsAnimateNeighborsAndFailedApplyKeepsLayout() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: first, parent: parent, at: manager.windows[first]!.photoFrame)
            try attach(manager, photo: second, parent: parent, at: manager.windows[second]!.photoFrame)
            var settings = DesktopCollageSettings(); settings.gap = 40
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            manager.collageFlights[second]?.currentProgress = 1
            XCTAssertEqual(manager.windows[second]!.photoFrame.minX - manager.windows[first]!.photoFrame.maxX, 40)
            let unchanged = manager.windows[second]!.photoFrame
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            settings.gap = 70
            XCTAssertFalse(manager.applyCollageSettings(parent, settings: settings))
            XCTAssertEqual(manager.windows[second]!.photoFrame, unchanged)
            XCTAssertEqual(manager.photos.first { $0.id == parent }?.desktopCollage?.gap, 40)
        }
    }

    @MainActor
    func testMovingGroupSaveFailureRestoresSpaceFramesToo() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let index = manager.photos.firstIndex { $0.id == photo }!
            manager.photos[index].folderImageConfigs["other.png"] = FolderImageConfig(frameString: "{{30,40},{180,240}}", widgetWidth: 180)
            XCTAssertTrue(manager.persist())
            let previous = manager.photos[index]
            let groupFrame = manager.windows[parent]!.photoFrame
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.moveCollage(parent, to: groupFrame.offsetBy(dx: 50, dy: 25), finished: true)
            XCTAssertEqual(manager.photos[index].folderImageConfigs["other.png"]?.frameString, previous.folderImageConfigs["other.png"]?.frameString)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, NSRectFromString(previous.frameString))
            XCTAssertEqual(manager.windows[parent]!.photoFrame, groupFrame)
        }
    }

    @MainActor
    func testSpaceConfigurationsTravelWithPhotoAndGroup() throws {
        try withManager { manager in
            XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
            let photo = manager.photos[0].id
            let original = manager.windows[photo]!.photoFrame
            let secondName = manager.photos[0].spaceImageFilenames[1]
            manager.photos[0].folderImageConfigs[secondName] = FolderImageConfig(frameString: NSStringFromRect(original), widgetWidth: original.width)
            let parent = try makeContainer(manager, frame: CGRect(x: original.midX - 80, y: original.midY - 80, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: original)
            let group = manager.windows[parent]!.photoFrame
            manager.moveCollage(parent, to: group.offsetBy(dx: 53, dy: 27), finished: true)
            manager.nextFolderImage(photo)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, original.offsetBy(dx: 53, dy: 27))
            XCTAssertEqual(manager.photos.first { $0.id == photo }?.collageParentID, parent)
        }
    }

    @MainActor
    func testAnimatedMemberKeepsOriginalBytesAndPlayback() throws {
        try withManager { manager in
            XCTAssertTrue(manager.addStarterExample(.animated))
            let item = manager.photos[0]
            let frame = manager.windows[item.id]!.photoFrame
            let bytes = try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename))
            let parent = try makeContainer(manager, frame: CGRect(x: frame.midX - 80, y: frame.midY - 80, width: 160, height: 160))
            try attach(manager, photo: item.id, parent: parent, at: frame)
            let view = try XCTUnwrap(manager.windows[item.id]?.contentView as? DraggablePhotoView)
            XCTAssertNotNil(view.photoLayer.animatedFrames)
            manager.removePhoto(parent)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename)), bytes)
            XCTAssertNotNil(view.photoLayer.animatedFrames)
        }
    }

    @MainActor
    func testTransferBetweenContainersAndRemoveHiddenContainerKeepPhoto() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let first = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            let second = try makeContainer(manager, frame: CGRect(x: 600, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: first, at: manager.windows[photo]!.photoFrame)
            try attach(manager, photo: photo, parent: second, at: CGRect(x: 590, y: 120, width: 180, height: 240))
            XCTAssertTrue(manager.collageMembers(first).isEmpty)
            XCTAssertEqual(manager.collageMembers(second).count, 1)
            manager.toggleVisibility(second)
            XCTAssertNil(manager.windows[photo])
            manager.removePhoto(second)
            XCTAssertNil(manager.photos.first { $0.id == photo }?.collageParentID)
            XCTAssertNotNil(manager.windows[photo])
            XCTAssertEqual(manager.windows[photo]?.photoFrame, CGRect(x: 590, y: 120, width: 180, height: 240))
        }
    }


    @MainActor
    func testHoverExpandsBeforeReleaseWithoutMovingPhotoOrSavingMembership() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            let originalPhoto = manager.windows[photo]!.photoFrame
            let originalParent = manager.photos.first { $0.id == parent }!.frameString
            let data = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            manager.beginCollageDrag(photo)
            let proposed = CGRect(x: 410, y: 130, width: 180, height: 240)
            XCTAssertEqual(manager.proposeCollageDrag(photo, frame: proposed, bypassSnap: true), proposed)
            let expected = CollageGeometry.enclosing([CollageGeometry.footprint(manager.photos.first { $0.id == photo }!, frame: proposed)], fallback: .zero, settings: surface.settings)
            XCTAssertEqual(surface.photoFrame, expected)
            surface.transition?.currentProgress = 0.5
            XCTAssertGreaterThan(surface.displayedBounds.width, 160)
            XCTAssertTrue(surface.isPreviewing)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, originalPhoto)
            XCTAssertEqual(manager.photos.first { $0.id == parent }!.frameString, originalParent)
            XCTAssertNil(manager.photos.first { $0.id == photo }!.collageParentID)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), data)
        }
    }

    @MainActor
    func testHoverRetargetAndReleaseKeepEntryAnimationAndPhotoPlacement() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            manager.beginCollageDrag(photo)
            let first = CGRect(x: 410, y: 130, width: 180, height: 240)
            _ = manager.proposeCollageDrag(photo, frame: first, bypassSnap: true)
            let entry = surface.transition
            entry?.currentProgress = 0.4
            let last = first.offsetBy(dx: 8, dy: -6)
            _ = manager.proposeCollageDrag(photo, frame: last, bypassSnap: true)
            XCTAssertTrue(surface.transition === entry)
            entry?.currentProgress = 0.6
            let beforeRelease = surface.displayedBounds
            manager.windows[photo]!.setPhotoFrame(last)
            XCTAssertTrue(manager.finishCollageDrag(photo))
            XCTAssertEqual(surface.displayedBounds, beforeRelease)
            XCTAssertTrue(surface.transition === entry)
            XCTAssertFalse(surface.isPreviewing)
            entry?.currentProgress = 1
            XCTAssertEqual(surface.displayedBounds, surface.photoFrame)
            XCTAssertNil(surface.transition)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, last)
        }
    }

    @MainActor
    func testExpandedHoverDoesNotChasePhotoAndRestoresWhenLeavingOrQuitting() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 340, height: 200), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            let committed = surface.photoFrame
            manager.beginCollageDrag(photo)
            let inside = CGRect(x: 410, y: 120, width: 340, height: 200)
            _ = manager.proposeCollageDrag(photo, frame: inside, bypassSnap: true)
            let outside = inside.offsetBy(dx: 240, dy: 0)
            XCTAssertTrue(CollageGeometry.accepts(outside, body: surface.photoFrame, siblings: [], gap: 20))
            XCTAssertNil(manager.proposeCollageDrag(photo, frame: outside, bypassSnap: true))
            XCTAssertNil(manager.collageDrags[photo]?.targetID)
            XCTAssertEqual(surface.photoFrame, committed)
            XCTAssertFalse(surface.isCandidate)
            XCTAssertTrue(surface.isEmpty)
            _ = manager.proposeCollageDrag(photo, frame: inside, bypassSnap: true)
            manager.cancelCollageInteractions()
            XCTAssertEqual(surface.displayedBounds, committed)
            XCTAssertFalse(surface.isPreviewing)
            XCTAssertEqual(manager.photos.first { $0.id == parent }!.frameString, NSStringFromRect(committed))
            XCTAssertNil(manager.photos.first { $0.id == photo }!.collageParentID)
        }
    }

    @MainActor
    func testHoverSwitchingTargetsAndCancelRestoreBothContainers() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let first = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let second = try makeContainer(manager, frame: CGRect(x: 850, y: 150, width: 160, height: 160))
            let originals = [first, second].map { manager.windows[$0]!.photoFrame }
            manager.beginCollageDrag(photo)
            _ = manager.proposeCollageDrag(photo, frame: CGRect(x: 410, y: 130, width: 180, height: 240), bypassSnap: true)
            _ = manager.proposeCollageDrag(photo, frame: CGRect(x: 860, y: 130, width: 180, height: 240), bypassSnap: true)
            XCTAssertEqual(manager.collageDrags[photo]?.targetID, second)
            XCTAssertEqual(manager.windows[first]!.photoFrame, originals[0])
            manager.cancelCollageDrag(photo)
            XCTAssertEqual(manager.windows[second]!.photoFrame, originals[1])
            XCTAssertNil(manager.photos.first { $0.id == photo }!.collageParentID)
        }
    }

    @MainActor
    func testHoverRapidReversalKeepsEntireInterpolatedSurfaceInsideHost() {
        let surface = CollageDesktopWindow(settings: DesktopCollageSettings())
        defer { surface.cancelTransition(); surface.hidePhoto() }
        let start = CGRect(x: 0, y: 0, width: 160, height: 160)
        surface.setPhotoFrame(start)
        surface.preview(to: start.offsetBy(dx: 1000, dy: 0))
        guard let entry = surface.transition else { return } // Reduce Motion has no transition.
        entry.currentProgress = 0.5
        surface.preview(to: start.offsetBy(dx: 600, dy: 0))
        entry.currentProgress = 0.51
        XCTAssertTrue(surface.frame.contains(surface.displayedBounds))
        XCTAssertTrue(surface.transition === entry)
        entry.currentProgress = 1
        XCTAssertEqual(surface.displayedBounds, start.offsetBy(dx: 600, dy: 0))
    }

    @MainActor
    func testNativeGlassUsesSystemDefaultsAndCustomizationsRoundTrip() throws {
        let defaults = DesktopCollageSettings()
        XCTAssertEqual(defaults.glassStyle, .system)
        XCTAssertFalse(defaults.usesCustomTint)
        let legacyDefault = try JSONDecoder().decode(DesktopCollageSettings.self, from: Data(##"{"skin":"glass","tintHex":"#F5EFE3"}"##.utf8))
        XCTAssertFalse(legacyDefault.usesCustomTint)
        let legacyCustom = try JSONDecoder().decode(DesktopCollageSettings.self, from: Data(##"{"skin":"glass","tintHex":"#557799"}"##.utf8))
        XCTAssertTrue(legacyCustom.usesCustomTint)
        var custom = defaults
        custom.glassStyle = .clear; custom.usesCustomTint = true; custom.tintHex = "#557799"; custom.tintStrength = 0.42
        XCTAssertEqual(try JSONDecoder().decode(DesktopCollageSettings.self, from: JSONEncoder().encode(custom)), custom)
        if #available(macOS 26.0, *) {
            let view = CollageSurfaceView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
            let native = try XCTUnwrap(descendants(view).compactMap { $0 as? NSGlassEffectView }.first)
            view.update(body: view.bounds, settings: defaults, empty: true, candidate: false)
            XCTAssertEqual(native.style, .regular)
            XCTAssertNil(native.tintColor)
            XCTAssertFalse(try XCTUnwrap(native.contentView).subviews.compactMap { $0 as? NSTextField }.isEmpty)
            view.update(body: view.bounds, settings: custom, empty: true, candidate: false)
            XCTAssertEqual(native.style, .clear)
            XCTAssertEqual(try XCTUnwrap(native.tintColor).alphaComponent, 0.42, accuracy: 0.001)
        }
    }

    @MainActor
    func testSettingsGroupingAndDetachKeepPhotoAndRecoverFailedWrite() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            let orphan = try makePhoto(manager, frame: CGRect(x: 600, y: 120, width: 160, height: 100), styled: false)
            manager.photos[manager.photos.firstIndex { $0.id == orphan }!].collageParentID = UUID()
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            XCTAssertEqual(Set(manager.collageRootItems.map(\.id)), Set([parent, orphan]))
            XCTAssertEqual(manager.collageMembers(parent).map(\.id), [photo])
            let frame = manager.windows[photo]!.photoFrame
            let name = manager.photos.first { $0.id == photo }!.filename
            let bytes = try Data(contentsOf: manager.storageDir.appendingPathComponent(name))
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertFalse(manager.removeFromCollage(photo))
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, frame)
            try saved.write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.loadSaved()
            XCTAssertTrue(manager.removeFromCollage(photo))
            XCTAssertTrue(manager.collageRootItems.contains { $0.id == photo })
            XCTAssertTrue(manager.collageMembers(parent).isEmpty)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, frame)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(name)), bytes)
        }
    }

    @MainActor
    func testGroupMovementCarriesActiveGapMotionWithoutReturningToOldTarget() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: first, parent: parent, at: manager.windows[first]!.photoFrame)
            try attach(manager, photo: second, parent: parent, at: manager.windows[second]!.photoFrame)
            var settings = DesktopCollageSettings(); settings.gap = 80
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let flight = manager.collageFlights[second]
            flight?.currentProgress = 0.4
            let visible = manager.windows[second]!.photoFrame
            let destination = NSRectFromString(manager.photos.first { $0.id == second }!.frameString)
            let parentFrame = manager.windows[parent]!.photoFrame
            manager.moveCollage(parent, to: parentFrame.offsetBy(dx: 50, dy: 30), finished: true)
            XCTAssertEqual(manager.windows[second]!.photoFrame, visible.offsetBy(dx: 50, dy: 30))
            flight?.currentProgress = 1
            XCTAssertEqual(manager.windows[second]!.photoFrame, destination.offsetBy(dx: 50, dy: 30))
            XCTAssertEqual(NSRectFromString(manager.photos.first { $0.id == second }!.frameString), destination.offsetBy(dx: 50, dy: 30))
        }
    }

    @MainActor
    func testDetachingMemberDuringGapMotionFitsRemainingDestinations() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let third = try makePhoto(manager, frame: CGRect(x: 440, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for id in [first, second, third] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
            var settings = DesktopCollageSettings(); settings.gap = 80
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let destinations = manager.collageMembers(parent).filter { $0.id != first }.map { NSRectFromString($0.frameString) }
            manager.beginCollageDrag(first)
            XCTAssertNil(manager.proposeCollageDrag(first, frame: CGRect(x: 900, y: 500, width: 180, height: 240), bypassSnap: true))
            XCTAssertEqual(manager.windows[parent]!.photoFrame, CollageGeometry.enclosing(destinations, fallback: .zero, settings: settings))
            manager.cancelCollageDrag(first)
            XCTAssertTrue(manager.removeFromCollage(first))
            XCTAssertEqual(manager.windows[parent]!.photoFrame, CollageGeometry.enclosing(destinations, fallback: .zero, settings: settings))
            for flight in Array(manager.collageFlights.values) { flight.currentProgress = 1 }
            for id in [second, third] { XCTAssertTrue(manager.windows[parent]!.photoFrame.contains(manager.windows[id]!.photoFrame)) }
        }
    }


    @MainActor
    func testMemberClickWithoutDraggingPreservesMembershipAndDisk() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let data = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let frame = manager.windows[photo]!.photoFrame
            let window = manager.windows[photo]!
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: center))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: center))
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
            XCTAssertEqual(window.photoFrame, frame)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), data)
        }
    }

    @MainActor
    func testGapInsidePhotoShadowWindowMovesWholeCollageAndKeepsGestureTarget() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 100, width: 120, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for id in [first, second] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
            let window = manager.windows[first]!
            window.applyShadowSettings(enabled: true, blur: 24, opacity: 0.3)
            let group = manager.windows[parent]!
            (group as? CollageDesktopWindow)?.transition?.currentProgress = 1
            let frames = [parent, first, second].map { manager.windows[$0]!.photoFrame }
            let point = CGPoint(x: 290, y: 220)
            XCTAssertTrue(window.frame.contains(point))
            XCTAssertTrue(window.onBackgroundEventTarget?(point) === group)
            window.sendEvent(try mouseEvent(.leftMouseDown, in: window, at: point))
            XCTAssertNil(manager.collageDrags[first])
            for step in 1...8 {
                window.sendEvent(try mouseEvent(.leftMouseDragged, in: window, at: point.applying(CGAffineTransform(translationX: CGFloat(step) * 4, y: CGFloat(step) * 3)), modifiers: .option))
            }
            window.sendEvent(try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: point.x + 32, y: point.y + 24)))
            for (id, frame) in zip([parent, first, second], frames) {
                XCTAssertEqual(manager.windows[id]!.photoFrame, frame.offsetBy(dx: 32, dy: 24))
            }
            let actualPhoto = CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
            window.sendEvent(try mouseEvent(.leftMouseDown, in: window, at: actualPhoto))
            XCTAssertNotNil(manager.collageDrags[first])
            window.sendEvent(try mouseEvent(.leftMouseUp, in: window, at: actualPhoto))
            manager.toggleLock(parent)
            let saved = group.photoFrame
            let lockedGap = CGPoint(x: 322, y: 244)
            window.sendEvent(try mouseEvent(.leftMouseDown, in: window, at: lockedGap))
            window.sendEvent(try mouseEvent(.leftMouseDragged, in: window, at: CGPoint(x: 350, y: 260)))
            window.sendEvent(try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: 350, y: 260)))
            XCTAssertEqual(group.photoFrame, saved)
        }
    }

    @MainActor
    func testShadowCursorUpdateKeepsCollageHandAndLockedPhotoDoesNotClaimEmptyGap() throws {
        let previous = NSCursor.current
        defer { previous.set() }
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 100, width: 120, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for id in [first, second] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
            let window = manager.windows[first]!
            window.applyShadowSettings(enabled: true, blur: 24, opacity: 0.3)
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 1
            let view = window.contentView as! DraggablePhotoView
            let gap = CGPoint(x: 290, y: 220)
            window.sendEvent(try mouseEvent(.mouseMoved, in: window, at: gap))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            view.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: window, at: gap))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            let surface = group.contentView as! CollageSurfaceView
            XCTAssertTrue(try XCTUnwrap(surface.outerBorder.superlayer?.sublayers).suffix(4).allSatisfy { !$0.isHidden })
            view.mouseExited(with: try trackingEvent(.mouseExited, in: window, at: gap))
            XCTAssertTrue(try XCTUnwrap(surface.outerBorder.superlayer?.sublayers).suffix(4).allSatisfy { !$0.isHidden })
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            manager.toggleLock(first)
            view.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: window, at: gap))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            view.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: window, at: CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            XCTAssertTrue(try XCTUnwrap(surface.outerBorder.superlayer?.sublayers).suffix(4).allSatisfy { $0.isHidden }, "Moving onto a photo leaves the collage background hover")
            manager.toggleLock(parent)
            XCTAssertTrue(try XCTUnwrap(surface.outerBorder.superlayer?.sublayers).suffix(4).allSatisfy { $0.isHidden })
            view.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: window, at: gap))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            manager.toggleLock(parent)
            view.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: window, at: gap))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        }
    }

    @MainActor
    func testDirectCollageHoverTracksAnimatedBodyAndLateExitCannotResetDestinationCursor() throws {
        let previous = NSCursor.current
        defer { previous.set() }
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let group = manager.windows[parent] as! CollageDesktopWindow
            let surface = group.contentView as! CollageSurfaceView
            let original = group.photoFrame
            let enlarged = original.insetBy(dx: -100, dy: -100)
            group.preview(to: enlarged)
            surface.updateTrackingAreas()
            XCTAssertTrue(surface.trackingAreas.allSatisfy { $0.options.contains(.inVisibleRect) && $0.options.contains(.activeAlways) })
            let inHost = CGPoint(x: enlarged.midX, y: enlarged.minY + 20)
            surface.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: group, at: inHost))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            group.transition?.currentProgress = 1
            surface.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: group, at: inHost))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            let oldPhoto = manager.windows[photo]!
            (oldPhoto.contentView as! DraggablePhotoView).mouseExited(with: try trackingEvent(.mouseExited, in: oldPhoto, at: inHost))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow)
            NSCursor.crosshair.set()
            surface.mouseExited(with: try trackingEvent(.mouseExited, in: group, at: inHost))
            XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
            for corner in CollageResizeCorner.allCases {
                let point = corner.gripCenter(in: group.photoFrame, radius: group.settings.effectiveCornerRadius)
                surface.cursorUpdate(with: try trackingEvent(.cursorUpdate, in: group, at: point))
                XCTAssertNotEqual(NSCursor.current, NSCursor.arrow)
            }
        }
    }

    @MainActor
    func testNativeCollageContextMenuKeepsBackdropBehindPhotosWhileTracking() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 1
            var settings = group.settings
            settings.caption = "Menu stacking"
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let surface = group.contentView as! CollageSurfaceView
            let member = manager.windows[photo]!
            let label = try XCTUnwrap(manager.collageLabelWindows[parent])
            for depth in [WidgetDepth.onDesktop, .floating] {
                manager.setDepth(parent, depth)
                for locked in [false, true] {
                    if manager.photos.first(where: { $0.id == parent })!.isLocked != locked { manager.toggleLock(parent) }
                    try assertAbove(label, member)
                    try assertAbove(member, group)
                    let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                    let frame = group.photoFrame
                    let point = CGPoint(x: group.photoFrame.minX + 4, y: group.photoFrame.midY)
                    if !locked {
                        surface.mouseDown(with: try mouseEvent(.leftMouseDown, in: group, at: point))
                        surface.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: group, at: CGPoint(x: point.x + 30, y: point.y + 20), modifiers: .option))
                        XCTAssertNotNil(manager.collageMoveSnapshots[parent])
                    }
                    let observation = NativeCollageMenuObservation()
                    observation.surface = surface
                    observation.group = group
                    observation.member = member
                    observation.label = label
                    let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                        MainActor.assumeIsolated {
                            guard let menu = note.object as? NSMenu, menu.delegate === observation.surface else { return }
                            observation.menu = menu
                            observation.started = Date()
                            observation.titles = menu.items.map(\.title)
                            observation.hostWasActiveAtOpen = NSApp.isActive
                            observation.eventAtOpen = NSApp.currentEvent.map { String(describing: $0.type) }
                            observation.modeAtOpen = RunLoop.current.currentMode?.rawValue
                        }
                    }
                    let endToken = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
                        MainActor.assumeIsolated {
                            guard let menu = note.object as? NSMenu, menu === observation.menu else { return }
                            observation.trackingEndedAt = Date()
                            observation.eventAtClose = NSApp.currentEvent.map { event in
                                let subtype = event.type == .appKitDefined ? ", subtype=\(event.subtype.rawValue)" : ""
                                return String(describing: event.type) + subtype
                            }
                        }
                    }
                    defer {
                        NotificationCenter.default.removeObserver(token)
                        NotificationCenter.default.removeObserver(endToken)
                    }
                    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            observation.timerFirings += 1
                            guard let menu = observation.menu, let started = observation.started,
                                  let group = observation.group, let member = observation.member, let label = observation.label else { return }
                            let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                            let order = info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
                            observation.samples += 1
                            if let a = order.firstIndex(of: label.windowNumber), let b = order.firstIndex(of: member.windowNumber),
                               let c = order.firstIndex(of: group.windowNumber), a < b, b < c {
                                observation.validSamples += 1
                            } else {
                                observation.invalidOrders.append(order.filter { [label.windowNumber, member.windowNumber, group.windowNumber].contains($0) })
                            }
                            if Date().timeIntervalSince(started) >= 0.3 { menu.cancelTrackingWithoutAnimation() }
                        }
                    }
                    RunLoop.main.add(timer, forMode: .eventTracking)
                    RunLoop.main.add(timer, forMode: .modalPanel)
                    RunLoop.main.add(timer, forMode: .default)
                    defer { timer.invalidate() }
                    let currentEventType = NSApp.currentEvent?.type.rawValue
                    // Dispatch through AppKit at the live background: the test drag
                    // moved the original pickup point outside the window.
                    let currentBackground = CGPoint(x: group.photoFrame.minX + 4, y: group.photoFrame.midY)
                    let openingEvent = try mouseEvent(.rightMouseDown, in: group, at: currentBackground)
                    NSApp.postEvent(openingEvent, atStart: true)
                    let queued = try XCTUnwrap(NSApp.nextEvent(matching: .rightMouseDown,
                        until: Date().addingTimeInterval(0.2), inMode: .default, dequeue: true))
                    XCTAssertEqual(queued.type, openingEvent.type)
                    XCTAssertEqual(queued.windowNumber, openingEvent.windowNumber)
                    XCTAssertEqual(queued.locationInWindow.x, openingEvent.locationInWindow.x, accuracy: 0.01)
                    XCTAssertEqual(queued.locationInWindow.y, openingEvent.locationInWindow.y, accuracy: 0.01)
                    let current = try XCTUnwrap(NSApp.currentEvent)
                    XCTAssertEqual(current.type, queued.type)
                    XCTAssertEqual(current.windowNumber, queued.windowNumber)
                    XCTAssertEqual(current.timestamp, queued.timestamp, accuracy: 0.000001)
                    NSApp.sendEvent(queued)
                    timer.invalidate()
                    let trackingDuration = observation.trackingEndedAt.flatMap { ended in observation.started.map { ended.timeIntervalSince($0) } }
                    XCTAssertGreaterThan(observation.samples, 0,
                                         "Must observe actual native menu tracking; depth=\(depth), locked=\(locked), started=\(String(describing: observation.started)), active at open=\(observation.hostWasActiveAtOpen), active after=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), current event type=\(String(describing: currentEventType)), tracking duration=\(String(describing: trackingDuration)), timer firings=\(observation.timerFirings), event at open/close=\(String(describing: observation.eventAtOpen))/\(String(describing: observation.eventAtClose)), run-loop mode at open=\(String(describing: observation.modeAtOpen))")
                    XCTAssertEqual(observation.validSamples, observation.samples,
                                   "Menu at \(depth), locked=\(locked): expected [\(label.windowNumber), \(member.windowNumber), \(group.windowNumber)], invalid orders \(observation.invalidOrders)")
                    XCTAssertEqual(observation.titles, ["Edit Collage…", locked ? "Unlock Position" : "Lock Position", "Remove Collage, Keep Photos"])
                    XCTAssertEqual(group.photoFrame, frame)
                    XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
                    XCTAssertTrue(manager.collageLabelWindows[parent] === label)
                    XCTAssertTrue(manager.collageMoveSnapshots.isEmpty)
                    XCTAssertNil(member.parent)
                    XCTAssertNil(label.parent)
                    try assertAbove(label, member)
                    try assertAbove(member, group)
                }
            }
        }
    }

    @MainActor
    func testCollageContextMenuDismissesClickAtOpeningPointWithoutChangingTheScene() throws {
        let originalPolicy = NSApp.activationPolicy()
        print("Synthetic menu host activation policy: \(originalPolicy.rawValue)")
        _ = NSApp.setActivationPolicy(.accessory)
        defer { _ = NSApp.setActivationPolicy(originalPolicy) }
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let group = manager.windows[parent] as! CollageDesktopWindow
            group.transition?.currentProgress = 1
            let surface = group.contentView as! CollageSurfaceView
            let member = manager.windows[photo]!
            var editRequests = 0
            var removeRequests = 0
            group.onEdit = { editRequests += 1 }
            group.onRemove = { removeRequests += 1 }
            for depth in [WidgetDepth.onDesktop, .floating] {
                // Queued NSEvents are local synthetic input. Activate their recipient;
                // physical inactive-app menu acceptance is recorded separately.
                NSApp.activate(ignoringOtherApps: true)
                let activationDeadline = Date().addingTimeInterval(1)
                while !NSApp.isActive && Date() < activationDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                guard NSApp.isActive else {
                    throw XCTSkip("macOS did not activate the synthetic menu test host; physical inactive-app acceptance remains separate")
                }
                manager.setDepth(parent, depth)
                try assertAbove(member, group)
                let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                let frame = group.photoFrame
                let observation = NativeCollageMenuObservation()
                observation.surface = surface
                observation.group = group
                let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated {
                        guard let menu = note.object as? NSMenu, menu.delegate === observation.surface else { return }
                        observation.menu = menu
                        observation.started = Date()
                        observation.hostWasActiveAtOpen = NSApp.isActive
                    }
                }
                let endToken = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated {
                        guard let menu = note.object as? NSMenu, menu === observation.menu else { return }
                        observation.trackingEndedAt = Date()
                    }
                }
                defer {
                    NotificationCenter.default.removeObserver(token)
                    NotificationCenter.default.removeObserver(endToken)
                }
                let point = CGPoint(x: frame.minX + 4, y: frame.midY)
                // Queue events only in this test host. Native menu tracking must
                // handle a second click without moving the user's real pointer.
                observation.releaseEvent = try mouseEvent(.rightMouseUp, in: group, at: point)
                let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let menu = observation.menu, let started = observation.started,
                              let group = observation.group, let release = observation.releaseEvent else { return }
                        // Do not time out a menu that has already ended tracking.
                        guard observation.trackingEndedAt == nil else { return }
                        let elapsed = Date().timeIntervalSince(started)
                        if elapsed >= 0.05, !observation.releasedOpeningButton {
                            observation.releasedOpeningButton = true
                            NSApp.postEvent(release, atStart: false)
                        }
                        if elapsed >= 0.1, !observation.postedDismissClick {
                            let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                            if let record = info.first(where: {
                                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
                                    && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == NSWindow.Level.popUpMenu.rawValue
                            }), let number = (record[kCGWindowNumber as String] as? NSNumber)?.intValue,
                               let dictionary = record[kCGWindowBounds as String] as? NSDictionary,
                               let bounds = CGRect(dictionaryRepresentation: dictionary), let screen = NSScreen.screens.first {
                                let menuFrame = CGRect(x: bounds.minX, y: screen.frame.maxY - bounds.maxY,
                                                       width: bounds.width, height: bounds.height)
                                observation.nativeMenuID = number
                                observation.openingPointInsideMenu = menuFrame.contains(point)
                                let clickWindow = menuFrame.contains(point) ? number : group.windowNumber
                                let location = NSApp.window(withWindowNumber: clickWindow)?.convertPoint(fromScreen: point)
                                    ?? CGPoint(x: point.x - menuFrame.minX, y: point.y - menuFrame.minY)
                                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                    if let click = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                                     windowNumber: clickWindow, context: nil, eventNumber: 0,
                                                                     clickCount: 1, pressure: 1) {
                                        NSApp.postEvent(click, atStart: false)
                                    }
                                }
                                observation.postedDismissClick = true
                            }
                        }
                        if elapsed >= 0.6 {
                            observation.cancelledByTimeout = true
                            menu.cancelTrackingWithoutAnimation()
                        }
                    }
                }
                for mode in [RunLoop.Mode.eventTracking, .modalPanel, .default] { RunLoop.main.add(timer, forMode: mode) }
                defer { timer.invalidate() }
                surface.rightMouseDown(with: try mouseEvent(.rightMouseDown, in: group, at: point))
                timer.invalidate()
                XCTAssertTrue(observation.postedDismissClick, "Must exercise the native menu's click handling")
                XCTAssertNotNil(observation.nativeMenuID)
                XCTAssertNotNil(observation.trackingEndedAt, "Native menu tracking must end after dismissal")
                let trackingDuration = observation.trackingEndedAt.flatMap { ended in observation.started.map { ended.timeIntervalSince($0) } }
                XCTAssertFalse(observation.cancelledByTimeout, "Clicking the opening point must dismiss the menu at \(depth), inside menu=\(String(describing: observation.openingPointInsideMenu)), active at open=\(observation.hostWasActiveAtOpen), menu ID=\(String(describing: observation.nativeMenuID)), tracking ended after=\(String(describing: trackingDuration))")
                XCTAssertEqual(editRequests, 0)
                XCTAssertEqual(removeRequests, 0)
                XCTAssertEqual(group.photoFrame, frame)
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
                try assertAbove(member, group)
            }
        }
    }

    @MainActor
    func testCollageHitRegionIncludesAllBordersAndConvertsSuperviewCoordinates() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let surface = CollageSurfaceView(frame: CGRect(x: 37, y: 51, width: 420, height: 350))
        host.addSubview(surface)
        let body = CGRect(x: 14, y: 14, width: 380, height: 300)
        surface.update(body: body, settings: DesktopCollageSettings(), empty: false, candidate: false)
        let points = [CGPoint(x: body.minX, y: body.midY), CGPoint(x: body.maxX, y: body.midY),
                      CGPoint(x: body.midX, y: body.minY), CGPoint(x: body.midX, y: body.maxY),
                      CGPoint(x: body.midX, y: body.midY)]
        for point in points {
            XCTAssertTrue(surface.hitTest(surface.convert(point, to: host)) === surface)
        }
        XCTAssertNil(surface.hitTest(surface.convert(CGPoint(x: body.minX, y: body.minY), to: host)))
        XCTAssertNil(surface.hitTest(surface.convert(CGPoint(x: 1, y: body.midY), to: host)))
    }

    @MainActor
    func testInterruptedGapGestureCannotRedirectNextPhotoDragOrFallThroughAfterRemoval() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 100, width: 120, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for id in [first, second] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
            let window = manager.windows[first]!
            window.applyShadowSettings(enabled: true, blur: 24, opacity: 0.3)
            let group = manager.windows[parent]!
            (group as? CollageDesktopWindow)?.transition?.currentProgress = 1
            let gap = CGPoint(x: 290, y: 220)
            let otherFrame = manager.windows[second]!.photoFrame
            window.sendEvent(try mouseEvent(.leftMouseDown, in: window, at: gap))
            let center = CGPoint(x: window.photoFrame.midX, y: window.photoFrame.midY)
            window.sendEvent(try mouseEvent(.leftMouseDown, in: window, at: center))
            window.sendEvent(try mouseEvent(.leftMouseDragged, in: window, at: CGPoint(x: center.x + 15, y: center.y), modifiers: .option))
            window.sendEvent(try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: center.x + 15, y: center.y)))
            XCTAssertEqual(window.photoFrame.minX, 115)
            XCTAssertEqual(manager.windows[second]!.photoFrame, otherFrame)
            XCTAssertTrue(manager.collageMoveSnapshots.isEmpty)
            let point = CGPoint(x: window.photoFrame.minX - 10, y: window.photoFrame.midY)
            window.sendEvent(try mouseEvent(.leftMouseDown, in: window, at: point))
            let saved = window.photoFrame
            group.hidePhoto()
            window.sendEvent(try mouseEvent(.leftMouseDragged, in: window, at: CGPoint(x: point.x + 30, y: point.y)))
            window.sendEvent(try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: point.x + 30, y: point.y)))
            XCTAssertEqual(window.photoFrame, saved)
        }
    }

    @MainActor
    func testDoubleClickRepairsPhotosBeforeAndAfterDeferredEditorPresentation() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: true)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let background = manager.windows[parent] as! CollageDesktopWindow
            background.transition?.currentProgress = 1
            let view = background.contentView as! CollageSurfaceView
            let photoWindow = manager.windows[photo]!
            let frame = photoWindow.photoFrame
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            var editors: [CollageEditorWindowController] = []
            defer { editors.forEach { $0.close() } }
            background.onEdit = {
                let editor = CollageEditorWindowController(manager: manager, id: parent) {}
                editor.window?.level = WidgetDepth.onDesktop.windowLevel
                editor.window?.orderFront(nil)
                editor.window?.contentView?.layoutSubtreeIfNeeded()
                editors.append(editor)
                background.order(.above, relativeTo: photoWindow.windowNumber)
            }
            background.order(.above, relativeTo: photoWindow.windowNumber)
            let point = CGPoint(x: background.photoFrame.minX + 3, y: background.photoFrame.midY)
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: background, at: point, clicks: 2))
            XCTAssertTrue(editors.isEmpty)
            XCTAssertTrue(photoWindow.isVisible)
            XCTAssertEqual(photoWindow.contentView!.alphaValue, 1)
            try assertAbove(photoWindow, background)
            let editorDeadline = Date().addingTimeInterval(1)
            while editors.isEmpty && Date() < editorDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertEqual(editors.count, 1)
            XCTAssertTrue(manager.windows[photo] === photoWindow)
            XCTAssertTrue(photoWindow.isVisible)
            XCTAssertEqual(photoWindow.contentView!.alphaValue, 1)
            XCTAssertEqual(photoWindow.photoFrame, frame)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), saved)
        }
    }

    @MainActor
    func testDoubleClickAdvancesSpaceWithoutDetaching() throws {
        try withManager { manager in
            XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
            let photo = manager.photos[0].id
            manager.setRotationInterval(photo, "click")
            manager.setDepth(photo, .onDesktop)
            let window = manager.windows[photo]!
            let frame = window.photoFrame
            let parent = try makeContainer(manager, frame: CGRect(x: frame.midX - 80, y: frame.midY - 80, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: frame)
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: center))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: center))
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: center, clicks: 2))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: center, clicks: 2))
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.folderImageIndex, 1)
            XCTAssertEqual(window.photoFrame, frame)
        }
    }

    @MainActor
    func testFirstEscapeEventShrinksSourceBeforeReleaseAndCommitDoesNotRestart() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for photo in [first, second] { try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame) }
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            let full = surface.photoFrame
            let data = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let expected = CollageGeometry.enclosing([manager.windows[second]!.photoFrame], fallback: full, settings: surface.settings)
            manager.beginCollageDrag(first)
            let outside = CGRect(x: 800, y: 500, width: 180, height: 240)
            XCTAssertNil(manager.proposeCollageDrag(first, frame: outside, bypassSnap: true))
            XCTAssertEqual(surface.photoFrame, expected)
            let collapse = surface.transition
            collapse?.currentProgress = 0.5
            XCTAssertLessThan(surface.displayedBounds.width, full.width)
            XCTAssertEqual(manager.photos.first { $0.id == first }!.collageParentID, parent)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), data)
            let displayed = surface.displayedBounds
            manager.windows[first]!.setPhotoFrame(outside)
            XCTAssertTrue(manager.finishCollageDrag(first))
            XCTAssertTrue(surface.transition === collapse)
            XCTAssertEqual(surface.displayedBounds, displayed)
            XCTAssertNil(manager.photos.first { $0.id == first }!.collageParentID)
            XCTAssertEqual(manager.windows[second]!.photoFrame, CGRect(x: 300, y: 220, width: 120, height: 120))
        }
    }

    @MainActor
    func testLastMemberEscapeShowsEmptyContainerAndCancelRestoresSource() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            let full = surface.photoFrame
            manager.beginCollageDrag(photo)
            _ = manager.proposeCollageDrag(photo, frame: CGRect(x: 800, y: 500, width: 180, height: 240), bypassSnap: true)
            XCTAssertTrue(surface.isEmpty)
            XCTAssertEqual(surface.photoFrame, CGRect(origin: full.origin, size: CollageGeometry.emptySize))
            manager.cancelCollageDrag(photo)
            XCTAssertFalse(surface.isEmpty)
            XCTAssertEqual(surface.photoFrame, full)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
        }
    }

    @MainActor
    func testEscapedSourceReentryUsesRemainingContentNotVacatedArea() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for photo in [first, second] { try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame) }
            try attach(manager, photo: second, parent: parent, at: CGRect(x: 400, y: 220, width: 120, height: 120))
            manager.beginCollageDrag(first)
            _ = manager.proposeCollageDrag(first, frame: CGRect(x: 800, y: 500, width: 180, height: 240), bypassSnap: true)
            XCTAssertNil(manager.proposeCollageDrag(first, frame: CGRect(x: 100, y: 100, width: 180, height: 240), bypassSnap: true))
            let adjacent = CGRect(x: 200, y: 100, width: 180, height: 240)
            XCTAssertEqual(manager.proposeCollageDrag(first, frame: adjacent, bypassSnap: true), adjacent)
            XCTAssertEqual(manager.collageDrags[first]?.targetID, parent)
            XCTAssertFalse((manager.windows[parent] as? CollageDesktopWindow)!.isCandidate)
            manager.windows[first]!.setPhotoFrame(adjacent)
            XCTAssertTrue(manager.finishCollageDrag(first))
            XCTAssertEqual(manager.photos.first { $0.id == first }!.collageParentID, parent)
        }
    }

    @MainActor
    func testLiveTransferPreviewsBothContainersAndCancellationRestoresBoth() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let source = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            let target = try makeContainer(manager, frame: CGRect(x: 800, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: source, at: manager.windows[photo]!.photoFrame)
            let full = manager.windows[source]!.photoFrame
            let empty = manager.windows[target]!.photoFrame
            manager.beginCollageDrag(photo)
            let drop = CGRect(x: 810, y: 120, width: 180, height: 240)
            _ = manager.proposeCollageDrag(photo, frame: drop, bypassSnap: true)
            XCTAssertEqual(manager.collageDrags[photo]?.targetID, target)
            XCTAssertEqual(manager.windows[source]!.photoFrame.size, CollageGeometry.emptySize)
            XCTAssertGreaterThan(manager.windows[target]!.photoFrame.height, empty.height)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, source)
            manager.cancelCollageDrag(photo)
            XCTAssertEqual(manager.windows[source]!.photoFrame, full)
            XCTAssertEqual(manager.windows[target]!.photoFrame, empty)
        }
    }

    @MainActor
    func testSourceEscapeSaveFailureAndShutdownRestoreCommittedBounds() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let full = manager.windows[parent]!.photoFrame
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            manager.beginCollageDrag(photo)
            let outside = CGRect(x: 800, y: 500, width: 180, height: 240)
            _ = manager.proposeCollageDrag(photo, frame: outside, bypassSnap: true)
            manager.windows[photo]!.setPhotoFrame(outside)
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            XCTAssertTrue(manager.finishCollageDrag(photo))
            XCTAssertEqual(manager.windows[parent]!.photoFrame, full)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
            try saved.write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.loadSaved()
            manager.beginCollageDrag(photo)
            _ = manager.proposeCollageDrag(photo, frame: outside, bypassSnap: true)
            manager.cancelCollageInteractions()
            XCTAssertEqual(manager.windows[parent]!.photoFrame, full)
            XCTAssertEqual(manager.windows[photo]!.photoFrame, CGRect(x: 100, y: 100, width: 180, height: 240))
        }
    }

    @MainActor
    func testActiveAddingWidgetStaysAboveOtherMembersAndGlass() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 600, y: 200, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: first, parent: parent, at: manager.windows[first]!.photoFrame)
            manager.beginCollageDrag(second)
            _ = manager.proposeCollageDrag(second, frame: CGRect(x: 120, y: 120, width: 120, height: 120), bypassSnap: true)
            try assertAbove(manager.windows[second]!, manager.windows[first]!)
            try assertAbove(manager.windows[first]!, manager.windows[parent]!)
        }
    }

    @MainActor
    func testSavedPaperCollageRestoresBehindIndependentPhotosAtDesktopDepth() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 200, y: 200, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 180, y: 180, width: 240, height: 300))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            settings.applyPreset(.whitePolaroid)
            settings.caption = "A slower weekend"
            manager.setSpaceBound(parent, true)
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            for _ in 0..<3 {
                manager.loadSaved()
                let background = try XCTUnwrap(manager.windows[parent])
                let member = try XCTUnwrap(manager.windows[photo])
                XCTAssertEqual(background.level, WidgetDepth.onDesktop.windowLevel)
                XCTAssertEqual(member.level, background.level)
                try assertAbove(member, background)
                for active in [true, false] {
                    manager.setSettingsWindowActive(active)
                    manager.syncCollages()
                    try assertAbove(member, background)
                    if let label = manager.collageLabelWindows[parent] {
                        try assertAbove(label, member)
                    }
                }
            }
        }
    }

    @MainActor
    func testFloatingPaperCollageKeepsDepthAndPhotosAcrossSettingsActivation() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 200, y: 200, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 180, y: 180, width: 240, height: 300))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            settings.applyPreset(.whitePolaroid)
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            manager.setDepth(parent, .floating)
            let background = manager.windows[parent]!
            let member = manager.windows[photo]!
            for _ in 0..<4 {
                for active in [true, false] {
                    manager.setSettingsWindowActive(active)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                    XCTAssertEqual(background.level, WidgetDepth.floating.windowLevel)
                    XCTAssertEqual(member.level, background.level)
                    XCTAssertTrue(member.isVisible)
                    try assertAbove(member, background)
                }
            }
        }
    }

    @MainActor
    func testLockedCollageClickAndOrderingKeepPhotosCrispAboveGlass() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            manager.toggleLock(parent)
            let background = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            let view = try XCTUnwrap(background.contentView as? CollageSurfaceView)
            let point = CGPoint(x: background.photoFrame.minX + 4, y: background.photoFrame.midY)
            let event = try mouseEvent(.leftMouseDown, in: background, at: point)
            XCTAssertTrue(view.shouldDelayWindowOrdering(for: event))
            background.order(.above, relativeTo: manager.windows[photo]!.windowNumber)
            view.mouseDown(with: event)
            try assertAbove(manager.windows[photo]!, background)
            background.orderFront(nil)
            try assertAbove(manager.windows[photo]!, background)
            XCTAssertTrue(manager.photos.first { $0.id == parent }!.isLocked)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
        }
    }

    @MainActor
    func testInheritedUnlockTargetsCollageAndPreservesPersonalLocks() throws {
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for photo in [first, second] { try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame) }
            manager.toggleLock(first)
            manager.toggleLock(parent)
            let firstView = try XCTUnwrap(manager.windows[first]!.contentView as? DraggablePhotoView)
            let secondView = try XCTUnwrap(manager.windows[second]!.contentView as? DraggablePhotoView)
            XCTAssertEqual(secondView.lockActionTitle, "Unlock Collage")
            manager.toggleLock(second)
            XCTAssertFalse(manager.photos.first { $0.id == parent }!.isLocked)
            XCTAssertTrue(manager.photos.first { $0.id == first }!.isLocked)
            XCTAssertFalse(manager.photos.first { $0.id == second }!.isLocked)
            XCTAssertTrue(firstView.isLocked)
            XCTAssertFalse(secondView.isLocked)
            XCTAssertFalse(secondView.isLockedByCollage)
            XCTAssertEqual(firstView.lockActionTitle, "Unlock Position")
            XCTAssertEqual(manager.collageMembers(parent).count, 2)
        }
    }

    @MainActor
    func testFailedLockSaveAndLockingDuringDragPreserveMembershipAndBounds() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let full = manager.windows[parent]!.photoFrame
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.toggleLock(parent)
            XCTAssertFalse(manager.photos.first { $0.id == parent }!.isLocked)
            XCTAssertFalse((manager.windows[photo]!.contentView as! DraggablePhotoView).isLocked)
            try saved.write(to: manager.storageDir.appendingPathComponent("photos.json"))
            manager.loadSaved()
            manager.beginCollageDrag(photo)
            _ = manager.proposeCollageDrag(photo, frame: CGRect(x: 800, y: 500, width: 180, height: 240), bypassSnap: true)
            manager.toggleLock(parent)
            XCTAssertNil(manager.collageDrags[photo])
            XCTAssertEqual(manager.windows[parent]!.photoFrame, full)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.collageParentID, parent)
            XCTAssertTrue(manager.photos.first { $0.id == parent }!.isLocked)
        }
    }

    @MainActor
    func testNewContainerAvoidsOccupiedPhotoAndDoesNotCoverItsInput() throws {
        try withManager { manager in
            let screen = NSScreen.main!.visibleFrame
            let photo = try makePhoto(manager, frame: CGRect(x: screen.midX - 170, y: screen.midY - 100, width: 340, height: 200), styled: false)
            let parent = try XCTUnwrap(manager.addDesktopCollage())
            manager.setDepth(parent, .onDesktop)
            XCTAssertFalse(manager.windows[parent]!.photoFrame.intersects(manager.windows[photo]!.photoFrame))
            try assertAbove(manager.windows[photo]!, manager.windows[parent]!)
        }
    }

    @MainActor
    func testOrdinarySnappingIgnoresCollageBackgroundAndOptionBypassesLocks() throws {
        try withManager { manager in
            let suite = "ArrasCollageSnapTests-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let engine = SnapEngine(defaults: defaults)
            engine.isEnabled = true; engine.includesOtherApps = false
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            _ = try makeContainer(manager, frame: CGRect(x: 400, y: 350, width: 160, height: 160))
            let window = manager.windows[photo]!
            engine.beginDrag(for: window)
            let proposed = CGPoint(x: 405, y: 377)
            let result = engine.snappedOrigin(for: window, proposedOrigin: proposed, size: window.photoFrame.size, matInset: 0, modifiers: [], dragStart: proposed)
            XCTAssertEqual(result.origin.x, proposed.x)
            let option = CGPoint(x: 3, y: 3)
            let free = engine.snappedOrigin(for: window, proposedOrigin: option, size: window.photoFrame.size, matInset: 0, modifiers: .option, dragStart: option)
            XCTAssertEqual(free.origin, option)
            XCTAssertTrue(free.guides.isEmpty)
            engine.endDrag()
        }
    }

    @MainActor
    func testNativeDragHandoffOutOfCollageKeepsRawPointerPosition() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            _ = try makeContainer(manager, frame: CGRect(x: 400, y: 150, width: 160, height: 160))
            let window = manager.windows[photo]!
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: CGPoint(x: 190, y: 240)))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, at: CGPoint(x: 496, y: 240)))
            XCTAssertEqual(window.photoFrame.minX, 406)
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, at: CGPoint(x: 730, y: 240)))
            XCTAssertNil(manager.collageDrags[photo]?.targetID)
            XCTAssertEqual(window.photoFrame.minX, 640)
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: 730, y: 240)))
            XCTAssertNil(manager.photos.first { $0.id == photo }!.collageParentID)
        }
    }

    @MainActor
    func testEscapingMemberRetainsInteractiveDepthUntilDetachedCommit() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 120, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let index = manager.photos.firstIndex { $0.id == photo }!
            manager.photos[index].depth = .behindIcons
            manager.syncCollages()
            let window = manager.windows[photo]!
            let outside = CGRect(x: 800, y: 500, width: 180, height: 240)
            manager.beginCollageDrag(photo)
            XCTAssertNil(manager.proposeCollageDrag(photo, frame: outside, bypassSnap: true))
            XCTAssertFalse(window.ignoresMouseEvents)
            XCTAssertEqual(window.level, WidgetDepth.onDesktop.windowLevel)
            XCTAssertNotNil(manager.proposeCollageDrag(photo, frame: window.photoFrame, bypassSnap: true))
            XCTAssertFalse(window.ignoresMouseEvents)
            XCTAssertNil(manager.proposeCollageDrag(photo, frame: outside, bypassSnap: true))
            window.setPhotoFrame(outside)
            XCTAssertTrue(manager.finishCollageDrag(photo))
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertEqual(window.level, WidgetDepth.behindIcons.windowLevel)
            XCTAssertNil(manager.photos[index].collageParentID)
        }
    }

    @MainActor
    func testClickDuringGapMotionResumesDestinationWithoutWritingIntermediateFrame() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "This transition-in-progress check requires system animations; Reduce Motion intentionally completes synchronously.")
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let second = try makePhoto(manager, frame: CGRect(x: 300, y: 220, width: 120, height: 120), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for id in [first, second] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
            var settings = DesktopCollageSettings(); settings.gap = 80
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let flight = try XCTUnwrap(manager.collageFlights[second])
            flight.currentProgress = 0.5
            let destination = NSRectFromString(manager.photos.first { $0.id == second }!.frameString)
            let disk = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            let window = manager.windows[second]!
            let visible = window.photoFrame
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            let center = CGPoint(x: visible.midX, y: visible.midY)
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: center))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: center))
            XCTAssertEqual(window.photoFrame, visible)
            let resumed = try XCTUnwrap(manager.collageFlights[second])
            XCTAssertFalse(resumed === flight)
            resumed.currentProgress = 1
            XCTAssertEqual(window.photoFrame, destination)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), disk)
            settings.gap = 20
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let nextFlight = try XCTUnwrap(manager.collageFlights[second])
            nextFlight.currentProgress = 0.5
            let nextDestination = NSRectFromString(manager.photos.first { $0.id == second }!.frameString)
            manager.beginCollageDrag(second)
            manager.cancelCollageInteractions()
            XCTAssertEqual(window.photoFrame, nextDestination)
            manager.beginCollageDrag(first)
            XCTAssertNil(manager.proposeCollageDrag(first, frame: CGRect(x: 900, y: 500, width: 180, height: 240), bypassSnap: true))
            XCTAssertEqual(manager.windows[parent]!.photoFrame, CollageGeometry.enclosing([nextDestination], fallback: .zero, settings: settings))
        }
    }

    @MainActor
    func testDraggingSpaceDuringGapMotionTranslatesSavedSlotsFromTheirDestination() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "This transition-in-progress check requires system animations; Reduce Motion intentionally completes synchronously.")
        try withManager { manager in
            let first = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            XCTAssertTrue(manager.addStarterExample(.rotatingSpace))
            let second = manager.photos.last!.id
            manager.setDepth(second, .onDesktop)
            let frame = CGRect(x: 300, y: 220, width: 120, height: 120)
            manager.windows[second]!.setPhotoFrame(frame)
            manager.storeCollageFrame(second, frame)
            let index = manager.photos.firstIndex { $0.id == second }!
            let names = manager.photos[index].spaceImageFilenames
            for name in names { manager.photos[index].folderImageConfigs[name] = FolderImageConfig(frameString: NSStringFromRect(frame), widgetWidth: frame.width) }
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            for id in [first, second] { try attach(manager, photo: id, parent: parent, at: manager.windows[id]!.photoFrame) }
            var settings = DesktopCollageSettings(); settings.gap = 80
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let flight = try XCTUnwrap(manager.collageFlights[second])
            flight.currentProgress = 0.5
            let destination = NSRectFromString(manager.photos[index].frameString)
            let slots = manager.photos[index].folderImageConfigs
            manager.beginCollageDrag(second)
            let proposed = destination.offsetBy(dx: 40, dy: 0)
            let accepted = try XCTUnwrap(manager.proposeCollageDrag(second, frame: proposed, bypassSnap: true))
            manager.windows[second]!.setPhotoFrame(accepted)
            XCTAssertTrue(manager.finishCollageDrag(second))
            for name in names {
                XCTAssertEqual(NSRectFromString(manager.photos[index].folderImageConfigs[name]!.frameString), NSRectFromString(slots[name]!.frameString).offsetBy(dx: 40, dy: 0))
            }
        }
    }

    func testCollageRetentionAllowsCornersWithoutWideningEntryOrSnapping() {
        let portrait = CGRect(x: 1000, y: 400, width: 220, height: 280)
        let body = portrait.insetBy(dx: -28, dy: -28)
        let left = CGRect(x: 612, y: 480, width: 340, height: 200)
        XCTAssertFalse(CollageGeometry.accepts(left, body: body, siblings: [portrait], gap: 20))
        XCTAssertTrue(CollageGeometry.retains(left, body: body, siblings: [portrait], gap: 20))
        XCTAssertEqual(CollageGeometry.snapped(left, siblings: [portrait], gap: 20), left)
        let corner = CGRect(x: 620, y: 720, width: 340, height: 200)
        XCTAssertTrue(CollageGeometry.retains(corner, body: body, siblings: [portrait], gap: 20))
        XCTAssertFalse(CollageGeometry.retains(corner.offsetBy(dx: -40, dy: 40), body: body, siblings: [portrait], gap: 20))
    }

    @MainActor
    func testWideWidgetNativePathStaysAcceptedAcrossPortraitTopAndLeftThenCollapsesOnEscape() throws {
        try withManager { manager in
            let portrait = try makePhoto(manager, frame: CGRect(x: 1000, y: 400, width: 220, height: 280))
            let wide = try makePhoto(manager, frame: CGRect(x: 500, y: 200, width: 340, height: 200), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 1030, y: 450, width: 160, height: 160))
            try attach(manager, photo: portrait, parent: parent, at: manager.windows[portrait]!.photoFrame)
            let footprint = manager.collageFootprint(manager.photos.first { $0.id == portrait }!)
            let surface = try XCTUnwrap(manager.windows[parent] as? CollageDesktopWindow)
            let saved = surface.photoFrame
            let window = manager.windows[wide]!
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            let start = window.photoFrame
            let pointerOffset = CGPoint(x: start.width / 2, y: start.height / 2)
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: CGPoint(x: start.midX, y: start.midY)))
            let overlap = CGRect(x: footprint.minX + 20, y: footprint.maxY - 150, width: start.width, height: start.height)
            let corner = CGRect(x: footprint.minX - start.width - 40, y: footprint.maxY + 35, width: start.width, height: start.height)
            let left = CGRect(x: corner.minX, y: footprint.maxY - start.height, width: start.width, height: start.height)
            for segment in [(overlap, corner), (corner, left)] {
                for step in 0...20 {
                    let frame = CollageGeometry.interpolated(segment.0, segment.1, progress: Double(step) / 20)
                    let pointer = CGPoint(x: frame.minX + pointerOffset.x, y: frame.minY + pointerOffset.y)
                    view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, at: pointer, modifiers: .option))
                    XCTAssertEqual(manager.collageDrags[wide]?.targetID, parent)
                    XCTAssertEqual(window.photoFrame.size, start.size)
                }
            }
            XCTAssertNil(manager.photos.first { $0.id == wide }!.collageParentID)
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: left.midX, y: left.midY)))
            XCTAssertEqual(manager.photos.first { $0.id == wide }!.collageParentID, parent)
            XCTAssertEqual(window.photoFrame, left)
            let joined = surface.photoFrame
            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: window, at: CGPoint(x: left.midX, y: left.midY)))
            let outside = left.offsetBy(dx: -700, dy: -300)
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: window, at: CGPoint(x: outside.midX, y: outside.midY), modifiers: .option))
            XCTAssertNil(manager.collageDrags[wide]?.targetID)
            XCTAssertEqual(surface.photoFrame, saved)
            XCTAssertLessThan(surface.photoFrame.width, joined.width)
            XCTAssertEqual(manager.photos.first { $0.id == wide }!.collageParentID, parent)
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: window, at: CGPoint(x: outside.midX, y: outside.midY)))
            XCTAssertNil(manager.photos.first { $0.id == wide }!.collageParentID)
        }
    }

    @MainActor
    func testEditorRequestsDeliverEveryReopenAndDesktopRequest() throws {
        try withManager { manager in
            let first = try makeContainer(manager, frame: CGRect(x: 300, y: 200, width: 160, height: 160))
            let second = try makeContainer(manager, frame: CGRect(x: 700, y: 200, width: 160, height: 160))
            let received = CollageEditorRequestRecorder()
            let token = NotificationCenter.default.addObserver(forName: .openDesktopCollageSettings, object: nil, queue: .main) { notification in
                guard let id = notification.object as? UUID else { return }
                MainActor.assumeIsolated { received.ids.append(id) }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            manager.requestCollageEditor(first)
            manager.requestCollageEditor(first)
            (manager.windows[second] as? CollageDesktopWindow)?.onEdit?()
            manager.requestCollageEditor(UUID())
            XCTAssertEqual(received.ids, [first, first, second])
            XCTAssertEqual(manager.collageEditorID, second)
        }
    }

    @MainActor
    func testGroupSettingsApplyAtomicallyAndFailedSavePreservesRuntimeAndIndividualPreferences() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 180, height: 240), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 150, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let originalChild = manager.photos.first { $0.id == photo }!
            var settings = DesktopCollageSettings(skin: .polaroid); settings.caption = "A good day"
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings, depth: .aboveWidgets, isSpaceBound: true))
            let item = manager.photos.first { $0.id == parent }!
            XCTAssertEqual(item.desktopCollage, settings)
            XCTAssertEqual(item.depth, .aboveWidgets)
            XCTAssertTrue(item.isSpaceBound)
            for id in [parent, photo] {
                XCTAssertEqual(manager.windows[id]!.level, WidgetDepth.aboveWidgets.windowLevel)
                XCTAssertTrue(manager.windows[id]!.collectionBehavior.contains(.moveToActiveSpace))
            }
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.depth, originalChild.depth)
            XCTAssertEqual(manager.photos.first { $0.id == photo }!.isSpaceBound, originalChild.isSpaceBound)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let saved = try encoder.encode(manager.photos)
            try Data("damaged".utf8).write(to: manager.storageDir.appendingPathComponent("photos.json"))
            settings.caption = "Unsaved"
            XCTAssertFalse(manager.applyCollageSettings(parent, settings: settings, depth: .behindIcons, isSpaceBound: false))
            XCTAssertEqual(try encoder.encode(manager.photos), saved)
            XCTAssertEqual(manager.windows[parent]!.level, WidgetDepth.aboveWidgets.windowLevel)
            XCTAssertFalse((manager.windows[photo]!.contentView as! DraggablePhotoView).isLocked)
        }
    }

    @MainActor
    func testHostedLabelCanvasReusesPhotosAcrossLayoutMaterialAndCaptionChanges() throws {
        try withManager { manager in
            let parent = try makeContainer(manager, frame: CGRect(x: 400, y: 350, width: 160, height: 160))
            let wide = try makePhoto(manager, frame: CGRect(x: 440, y: 390, width: 340, height: 200))
            try attach(manager, photo: wide, parent: parent, at: manager.windows[wide]!.photoFrame)
            let portrait = try makePhoto(manager, frame: CGRect(x: 800, y: 390, width: 200, height: 280))
            let w = manager.collageFootprint(manager.photos.first { $0.id == wide }!)
            let p = manager.collageFootprint(manager.photos.first { $0.id == portrait }!)
            try attach(manager, photo: portrait, parent: parent, at: manager.windows[portrait]!.photoFrame.offsetBy(dx: w.maxX + 20 - p.minX, dy: w.minY - p.minY))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 694, height: 550),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CollageLabelWizard(manager: manager, id: parent,
                settings: .constant(DesktopCollageSettings()), selection: .constant(CollageTextLabel.captionID), onClose: {}))
            defer { window.close() }
            window.level = WidgetDepth.onDesktop.windowLevel
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let preview = try XCTUnwrap(descendants(window.contentView!, of: CollagePreviewView.self).first)
            let deadline = Date().addingTimeInterval(1)
            while preview.previewPhotos.count < 2 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            let originals = preview.previewPhotos
            XCTAssertEqual(originals.count, 2)
            guard originals.count == 2 else { return }
            XCTAssertNotEqual(originals[0].frame.origin, originals[1].frame.origin)
            let frames = originals.map(\.frame)
            let identities = Set(originals.map(ObjectIdentifier.init))
            for iteration in 0..<24 {
                var settings = DesktopCollageSettings(skin: CollageSkin.allCases[iteration % CollageSkin.allCases.count])
                settings.caption = iteration % 2 == 0 ? "A good day" : ""
                settings.padding = CGFloat(12 + iteration)
                preview.configure(manager: manager, id: parent, settings: settings)
                preview.setFrameSize(CGSize(width: 450 - iteration, height: 190 + iteration))
                preview.needsLayout = true
                preview.layoutSubtreeIfNeeded()
                // No synchronous hierarchy mutation while the host lays out.
                XCTAssertEqual(Set(preview.previewPhotos.map(ObjectIdentifier.init)), identities)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                XCTAssertEqual(Set(preview.previewPhotos.map(ObjectIdentifier.init)), identities)
                XCTAssertEqual(preview.previewPhotos.map(\.frame), frames)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let settled = preview.renderGeneration
            for _ in 0..<5 {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                XCTAssertEqual(preview.renderGeneration, settled)
            }
            XCTAssertTrue(manager.removeFromCollage(portrait))
            preview.configure(manager: manager, id: parent, settings: DesktopCollageSettings())
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let remaining = preview.previewPhotos
            XCTAssertEqual(remaining.count, 1)
            XCTAssertTrue(identities.contains(ObjectIdentifier(remaining[0])))
            try attach(manager, photo: portrait, parent: parent, at: manager.windows[portrait]!.photoFrame)
            preview.configure(manager: manager, id: parent, settings: DesktopCollageSettings())
            let refreshDeadline = Date().addingTimeInterval(1)
            while preview.previewPhotos.count != 2 && Date() < refreshDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(preview.previewPhotos.count, 2)
            manager.toggleVisibility(portrait)
            preview.configure(manager: manager, id: parent, settings: DesktopCollageSettings())
            let hideDeadline = Date().addingTimeInterval(1)
            while preview.previewPhotos.count != 1 && Date() < hideDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(preview.previewPhotos.count, 1, "Hidden photos must not appear on the placement canvas")
        }
    }

    @MainActor
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @MainActor
    func testHiddenLargeMemberDoesNotSnapOrExpandNewSmallPhoto() throws {
        try withManager { manager in
            let large = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 600, height: 500), styled: false)
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 100, width: 160, height: 160))
            try attach(manager, photo: large, parent: parent, at: manager.windows[large]!.photoFrame)
            let saved = manager.photos.first { $0.id == large }!.frameString
            manager.toggleVisibility(large)
            XCTAssertTrue((manager.windows[parent] as? CollageDesktopWindow)!.isEmpty)
            XCTAssertNil(manager.windows[large])
            let body = NSRectFromString(manager.photos.first { $0.id == parent }!.frameString)
            XCTAssertLessThan(body.width, 600)
            let small = try makePhoto(manager, frame: CGRect(x: 900, y: 500, width: 80, height: 80), styled: false)
            // This is near the hidden photo's left edge: it must not snap to it.
            let drop = CGRect(x: 103, y: body.midY - 40, width: 80, height: 80)
            manager.beginCollageDrag(small)
            XCTAssertEqual(manager.proposeCollageDrag(small, frame: drop, bypassSnap: false), drop)
            XCTAssertEqual(manager.collageDrags[small]?.targetID, parent)
            manager.windows[small]?.setPhotoFrame(drop)
            XCTAssertTrue(manager.finishCollageDrag(small))
            let settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            let expected = CollageGeometry.enclosing([drop], fallback: body, settings: settings)
            XCTAssertEqual(NSRectFromString(manager.photos.first { $0.id == parent }!.frameString), expected)
            XCTAssertEqual(manager.collageMembers(parent).count, 2)
            var draft = settings; draft.gap += 20
            let layout = try XCTUnwrap(manager.collageAppearanceLayout(parent, settings: draft))
            XCTAssertNil(layout.frames[large])
            XCTAssertEqual(layout.frames[small], drop)
            // Simulate a pre-fix save retaining the hidden photo's oversized bounds.
            let parentIndex = manager.photos.firstIndex { $0.id == parent }!
            manager.photos[parentIndex].frameString = NSStringFromRect(
                CollageGeometry.enclosing([NSRectFromString(saved), drop], fallback: expected, settings: settings))
            XCTAssertTrue(manager.persist())
            manager.loadSaved()
            XCTAssertEqual(NSRectFromString(manager.photos.first { $0.id == parent }!.frameString), expected)
            XCTAssertNil(manager.windows[large])
            manager.toggleVisibility(large)
            XCTAssertEqual(manager.photos.first { $0.id == large }!.frameString, saved)
            XCTAssertNotNil(manager.windows[large])
            XCTAssertEqual(NSRectFromString(manager.photos.first { $0.id == parent }!.frameString),
                           CollageGeometry.enclosing([NSRectFromString(saved), drop], fallback: expected, settings: settings))
        }
    }

    @MainActor
    func testTemporaryHidingPreservesCollageLayout() throws {
        try withManager { manager in
            let photo = try makePhoto(manager, frame: CGRect(x: 100, y: 100, width: 300, height: 200))
            let parent = try makeContainer(manager, frame: CGRect(x: 100, y: 100, width: 160, height: 160))
            try attach(manager, photo: photo, parent: parent, at: manager.windows[photo]!.photoFrame)
            let before = manager.photos.first { $0.id == parent }!.frameString
            let index = manager.photos.firstIndex { $0.id == photo }!
            manager.photos[index].isHiddenForPresence = true
            manager.photos[index].isHiddenForDisplay = true
            manager.fitCollageModel(parent)
            XCTAssertEqual(manager.photos.first { $0.id == parent }!.frameString, before)
            XCTAssertEqual(manager.collageLayoutMembers(parent).map(\.id), [photo])
        }
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try testMouseEvent(type, in: window, at: point, clicks: clicks, modifiers: modifiers)
    }

    @MainActor
    private func trackingEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    @MainActor
    private func assertAbove(_ upper: NSWindow, _ lower: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        // AppKit submits desktop window orders on the next main-loop turn.
        NSApp.updateWindows()
        let deadline = Date().addingTimeInterval(0.5)
        var order: [Int] = []
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let info = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
            order = info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            if let a = order.firstIndex(of: upper.windowNumber), let b = order.firstIndex(of: lower.windowNumber), a < b { break }
        } while Date() < deadline
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: upper.windowNumber)), try XCTUnwrap(order.firstIndex(of: lower.windowNumber)), file: file, line: line)
    }

    @MainActor
    private func withManager(_ body: (PhotoManager) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasDesktopCollageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = PhotoManager(storageDirectory: root)
        defer {
            manager.cancelCollageInteractions()
            manager.windows.values.forEach { $0.hidePhoto() }; manager.windows.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
        try body(manager)
    }
    @MainActor
    private func makePhoto(_ manager: PhotoManager, frame: CGRect, styled: Bool = true) throws -> UUID {
        let image = NSImage(size: frame.size, flipped: false) { bounds in NSColor.systemTeal.setFill(); bounds.fill(); return true }
        var item = PhotoItem(filename: UUID().uuidString + ".png", width: frame.width)
        item.frameString = NSStringFromRect(frame)
        item.depth = .onDesktop
        item.shadowEnabled = false
        if styled { item.matWidth = 12; item.tiltDegrees = 3; item.cornerRadius = 14 }
        try StarterArtwork.pngData(for: image).write(to: manager.storageDir.appendingPathComponent(item.filename))
        manager.photos.append(item)
        manager.createWindow(for: item, content: .still(image))
        XCTAssertTrue(manager.persist())
        return item.id
    }
    @MainActor
    private func makeContainer(_ manager: PhotoManager, frame: CGRect) throws -> UUID {
        let id = try XCTUnwrap(manager.addDesktopCollage())
        manager.setDepth(id, .onDesktop)
        manager.moveCollage(id, to: frame, finished: true)
        return id
    }
    @MainActor
    private func attach(_ manager: PhotoManager, photo: UUID, parent: UUID, at frame: CGRect) throws {
        manager.beginCollageDrag(photo)
        let proposed = try XCTUnwrap(manager.proposeCollageDrag(photo, frame: frame, bypassSnap: false))
        XCTAssertEqual(manager.collageDrags[photo]?.targetID, parent)
        manager.windows[photo]?.setPhotoFrame(proposed)
        XCTAssertTrue(manager.finishCollageDrag(photo))
    }
}

@MainActor
private final class CollageEditorRequestRecorder { var ids: [UUID] = [] }

@MainActor
private final class NativeCollageMenuObservation {
    weak var surface: CollageSurfaceView?
    weak var group: CollageDesktopWindow?
    weak var member: DesktopPhotoWindow?
    weak var label: CollageLabelWindow?
    var releaseEvent: NSEvent?
    weak var menu: NSMenu?
    var started: Date?
    var samples = 0
    var validSamples = 0
    var titles: [String] = []
    var invalidOrders: [[Int]] = []
    var releasedOpeningButton = false
    var postedDismissClick = false
    var cancelledByTimeout = false
    var nativeMenuID: Int?
    var openingPointInsideMenu: Bool?
    var hostWasActiveAtOpen = false
    var trackingEndedAt: Date?
    var timerFirings = 0
    var eventAtOpen: String?
    var eventAtClose: String?
    var modeAtOpen: String?
}
