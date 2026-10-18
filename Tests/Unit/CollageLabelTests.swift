import AppKit
import XCTest
@testable import Arras

final class CollageLabelTests: XCTestCase {
    func testLegacyCaptionAndUnknownStylesDecodeWithoutLosingCollage() throws {
        let old = try JSONDecoder().decode(DesktopCollageSettings.self, from: Data(##"{"skin":"polaroid","caption":"September","tintHex":"#F5EFE3"}"##.utf8))
        XCTAssertEqual(old.captionStyle, .caption)
        XCTAssertTrue(old.labels.isEmpty)
        XCTAssertEqual(old.tintHex, "#F5EFE3")
        XCTAssertEqual(old.captionBandHeight(for: 400), 44)
        let future = try JSONDecoder().decode(CollageLabelStyle.self, from: Data(#"{"font":"future","weight":"future","alignment":"future","placement":"future"}"#.utf8))
        XCTAssertEqual(future.font, .modern)
        XCTAssertEqual(future.weight, .regular)
        XCTAssertEqual(future.alignment, .center)
        XCTAssertEqual(future.placement, .free)
    }

    func testRichLabelsRoundTripAndNormalizeInvalidGeometryAndIDs() throws {
        var settings = DesktopCollageSettings()
        settings.caption = "A good day"
        var style = CollageLabelStyle()
        style.font = .handwritten; style.fontSize = 31; style.italic = true
        style.rotationDegrees = -12; style.positionX = 0.25; style.positionY = 0.8
        style.colorHex = "#BA4A32"; style.tracking = 1.5; style.lineSpacing = 6; style.shadow = true
        settings.labels = [CollageTextLabel(text: "Kept close", style: style)]
        XCTAssertEqual(try JSONDecoder().decode(DesktopCollageSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.labels.append(settings.labels[0])
        settings.labels.append(CollageTextLabel(id: CollageTextLabel.captionID))
        settings.labels[0].style.fontSize = .infinity
        settings.labels[0].style.positionX = .nan
        settings.labels[0].style.fontFileName = "../outside.ttf"
        settings.normalize()
        XCTAssertEqual(Set(settings.textLabels.map(\.id)).count, 4)
        XCTAssertEqual(settings.labels[0].style.fontSize, 24)
        XCTAssertEqual(settings.labels[0].style.positionX, 0.5)
        XCTAssertNil(settings.labels[0].style.fontFileName)
        settings.setLabelText(String(repeating: "x", count: 200), for: CollageTextLabel.captionID)
        XCTAssertEqual(settings.caption.count, 180)
    }

    func testPresetsHaveCrispPaperAndPreserveEveryLabelAndScale() {
        var settings = DesktopCollageSettings()
        settings.caption = "September"
        settings.compositionScale = 1.7
        settings.labels = [CollageTextLabel(text: "Anywhere")]
        let labels = settings.textLabels
        for preset in CollagePreset.allCases {
            settings.borderWidth = 9
            settings.usesCustomTint = true
            settings.tintStrength = 0.8
            settings.applyPreset(preset)
            XCTAssertEqual(settings.borderWidth, 0)
            XCTAssertFalse(settings.usesCustomTint)
            XCTAssertEqual(settings.tintStrength, 0.16)
            XCTAssertEqual(settings.textLabels, labels)
            XCTAssertEqual(settings.compositionScale, 1.7)
            if preset == .whitePolaroid { XCTAssertEqual(settings.tintHex, "#FFFFFF"); XCTAssertEqual(settings.cornerRadius, 2) }
            if preset == .ink { XCTAssertEqual(settings.tintHex, "#202226") }
            if preset == .systemGlass { XCTAssertFalse(settings.usesCustomTint); XCTAssertEqual(settings.glassStyle, .system) }
        }
    }

    func testFreeCaptionMetricsCannotGrowTheComposition() {
        var settings = DesktopCollageSettings(skin: .polaroid)
        settings.caption = "A day, kept close"
        settings.captionStyle.placement = .free
        let photo = CGRect(x: 40, y: 80, width: 280, height: 180)
        let before = CollageGeometry.enclosing([photo], fallback: .zero, settings: settings)
        settings.captionStyle.fontSize = 96; settings.captionStyle.widthFraction = 0.15
        settings.captionStyle.rotationDegrees = 90
        let after = CollageGeometry.enclosing([photo], fallback: .zero, settings: settings)
        XCTAssertEqual(after, before)
    }

    func testMovingLargeCaptionKeepsFrozenStripAndReloadedPlacementStable() throws {
        var settings = DesktopCollageSettings()
        settings.caption = "Two lines\nKept close"
        settings.captionStyle.fontSize = 64
        let footprint = CGRect(x: 120, y: 320, width: 340, height: 240)
        let before = CollageGeometry.enclosing([footprint], fallback: .zero, settings: settings)
        settings.reserveCaptionStripForFreePlacement(width: before.width)
        settings.captionStyle.placement = .free
        settings.captionStyle.positionX = 0.25; settings.captionStyle.positionY = 0.75
        XCTAssertEqual(CollageGeometry.enclosing([footprint], fallback: .zero, settings: settings), before)
        settings.captionStyle.fontSize = 96; settings.captionStyle.widthFraction = 0.2
        XCTAssertEqual(CollageGeometry.enclosing([footprint], fallback: .zero, settings: settings), before)
        XCTAssertEqual(try JSONDecoder().decode(DesktopCollageSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testDockedMultilineAndRotatedCaptionsReserveMeasuredSpace() {
        var settings = DesktopCollageSettings(skin: .polaroid)
        settings.caption = "The first line\nThe second line"
        settings.captionStyle.fontSize = 42
        settings.captionStyle.lineSpacing = 12
        let body = CollageGeometry.enclosing([CGRect(x: 80, y: 240, width: 300, height: 240)], fallback: .zero, settings: settings)
        let label = CollageLabelLayout.layouts(settings: settings, in: body)[0]
        XCTAssertGreaterThan(settings.captionBandHeight(for: body.width), 44)
        XCTAssertLessThanOrEqual(label.rect.maxY, 240 - settings.effectivePadding / 2 + 0.1)
        XCTAssertGreaterThanOrEqual(label.rect.minY, body.minY)
        settings.captionStyle.rotationDegrees = 45
        XCTAssertGreaterThan(settings.captionBandHeight(for: body.width), label.rect.height)
    }

    func testLongNarrowDockedCaptionFitsItsStripWithoutCoveringPhotosOrGrowingOffscreen() {
        var settings = DesktopCollageSettings(skin: .polaroid)
        settings.caption = String(repeating: "A memory ", count: 20)
        settings.captionStyle.fontSize = 96; settings.captionStyle.widthFraction = 0.15
        settings.normalize()
        let photo = CGRect(x: 100, y: 300, width: 300, height: 200)
        let body = CollageGeometry.enclosing([photo], fallback: .zero, settings: settings)
        XCTAssertLessThanOrEqual(settings.captionBandHeight(for: body.width), 240)
        XCTAssertLessThanOrEqual(body.height, photo.height + settings.padding * 2 + 240)
        let label = CollageLabelLayout.layouts(settings: settings, in: body)[0]
        XCTAssertLessThanOrEqual(label.rect.maxY, photo.minY - settings.padding / 2 + 1)
        XCTAssertGreaterThanOrEqual(label.rect.minY, body.minY)
        XCTAssertLessThan((label.text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 96)
    }

    func testRotatedFreeLabelsStayInsideBodyAndShareScaleAndHitGeometry() {
        var settings = DesktopCollageSettings()
        var style = CollageLabelStyle()
        style.fontSize = 32; style.rotationDegrees = 35; style.positionX = 1; style.positionY = 1
        settings.labels = [CollageTextLabel(text: "Keep this memory", style: style)]
        let body = CGRect(x: 10, y: 20, width: 480, height: 320)
        let layout = CollageLabelLayout.layouts(settings: settings, in: body)[0]
        let rotated = layout.rect.applying(CGAffineTransform(translationX: -layout.rect.midX, y: -layout.rect.midY)
            .concatenating(CGAffineTransform(rotationAngle: layout.rotation))
            .concatenating(CGAffineTransform(translationX: layout.rect.midX, y: layout.rect.midY)))
        XCTAssertTrue(body.insetBy(dx: -0.01, dy: -0.01).contains(rotated))
        XCTAssertTrue(layout.contains(CGPoint(x: layout.rect.midX, y: layout.rect.midY)))
        XCTAssertFalse(layout.contains(CGPoint(x: body.minX - 20, y: body.minY - 20)))
        let miniature = CollageLabelLayout.layouts(settings: settings, in: CGRect(x: 5, y: 10, width: 240, height: 160), previewScale: 0.5)[0]
        XCTAssertEqual(miniature.rect.midX, layout.rect.midX / 2, accuracy: 1)
        XCTAssertEqual(miniature.rect.midY, layout.rect.midY / 2, accuracy: 1)
        XCTAssertEqual((miniature.text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 16)
    }

    func testFontFamiliesWeightsCustomFaceAndMissingFontFallback() throws {
        var style = CollageLabelStyle()
        let weights = [CollageLabelWeight.regular, .medium, .semibold, .bold].map { weight -> NSFont in
            style.weight = weight; return CollageTypography.font(for: style)
        }
        XCTAssertEqual(Set(weights.map { $0.fontDescriptor.object(forKey: .traits).map(String.init(describing:)) ?? $0.fontName }).count, 4)
        let families = CollageLabelFont.allCases.filter { $0 != .custom }.map { font -> String in
            style.font = font; style.weight = .regular; return CollageTypography.font(for: style).fontName
        }
        XCTAssertEqual(Set(families).count, 5)
        style.font = .custom; style.fontName = "Georgia-BoldItalic"; style.weight = .original; style.italic = true
        XCTAssertEqual(CollageTypography.font(for: style).fontName, "Georgia-BoldItalic")
        style.fontName = "Arras-Intentionally-Missing"
        let fallback = CollageTypography.font(for: style)
        XCTAssertEqual(fallback.pointSize, style.fontSize)
        XCTAssertEqual(style.fontName, "Arras-Intentionally-Missing")
    }

    @MainActor
    func testForegroundTextTracksVisibleBoundsResizeOpacityDepthAndCapture() throws {
        try fixture { manager, parent, members in
            let group = manager.windows[parent] as! CollageDesktopWindow
            let overlay = try XCTUnwrap(manager.collageLabelWindows[parent])
            XCTAssertTrue(overlay.ignoresMouseEvents)
            XCTAssertFalse(overlay.canBecomeKey)
            XCTAssertNil(overlay.contentView!.hitTest(CGPoint(x: 10, y: 10)))
            frame(overlay.frame, group.displayedBounds)
            let original = group.photoFrame
            manager.moveCollage(parent, to: original.offsetBy(dx: 50, dy: 30), finished: true)
            frame(overlay.frame, group.displayedBounds)
            XCTAssertTrue(manager.collageLabelWindows[parent] === overlay)
            XCTAssertNotNil(manager.beginCollageResize(parent))
            manager.resizeCollage(parent, scale: 1.4, corner: .topRight, finished: false)
            frame(overlay.frame, group.displayedBounds)
            let layout = (overlay.contentView as! CollageTextView).layouts.last!
            XCTAssertEqual((layout.text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 24 * 1.4, accuracy: 0.01)
            manager.cancelCollageInteractions()
            manager.setOpacity(parent, 0.6)
            XCTAssertEqual(overlay.alphaValue, 0.6, accuracy: 0.001)
            manager.setDepth(parent, .floating)
            XCTAssertTrue(manager.collageLabelWindows[parent] === overlay)
            XCTAssertEqual(overlay.level, group.level)
            XCTAssertEqual(overlay.collectionBehavior, group.collectionBehavior)
            let oldCapture = manager.excludeFromScreenCapture
            defer { manager.setExcludeFromScreenCapture(oldCapture) }
            manager.setExcludeFromScreenCapture(true)
            XCTAssertEqual(overlay.sharingType, .none)
            manager.setExcludeFromScreenCapture(false)
            XCTAssertFalse(manager.excludeFromScreenCapture)
            XCTAssertEqual(overlay.sharingType, group.sharingType)
            manager.enforceCollageOrdering(parent)
            NSApp.updateWindows(); pump()
            let info = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
            let order = info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
            for member in members {
                XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: overlay.windowNumber)), try XCTUnwrap(order.firstIndex(of: manager.windows[member]!.windowNumber)))
            }
        }
    }

    @MainActor
    func testHideRemovalAndDraftCancellationDoNotLeaveOrphanText() throws {
        try fixture { manager, parent, _ in
            let committed = manager.photos.first { $0.id == parent }!.desktopCollage!
            let session = UUID()
            manager.beginCollageAppearancePreview(parent, session: session)
            var draft = committed; draft.caption = "Temporary"; draft.labels[0].text = "Draft label"
            manager.previewCollageAppearance(parent, session: session, settings: draft)
            settle(manager)
            XCTAssertEqual((manager.collageLabelWindows[parent]!.contentView as! CollageTextView).layouts.last?.label.text, "Draft label")
            manager.endCollageAppearancePreview(parent, session: session, animated: false)
            XCTAssertEqual((manager.collageLabelWindows[parent]!.contentView as! CollageTextView).layouts.last?.label.text, committed.labels[0].text)
            let overlay = manager.collageLabelWindows[parent]!
            var blank = committed; blank.caption = ""; blank.labels = []
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: blank)); settle(manager)
            manager.enforceCollageOrdering(parent)
            XCTAssertFalse(overlay.isVisible)
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: committed)); settle(manager)
            XCTAssertTrue(manager.collageLabelWindows[parent] === overlay)
            XCTAssertTrue(overlay.isVisible)
            manager.toggleVisibility(parent)
            XCTAssertFalse(overlay.isVisible)
            XCTAssertNil(manager.collageLabelWindows[parent])
            manager.toggleVisibility(parent)
            XCTAssertTrue(manager.collageLabelWindows[parent]?.isVisible == true)
            let next = manager.collageLabelWindows[parent]!
            manager.removePhoto(parent)
            XCTAssertFalse(next.isVisible)
            XCTAssertNil(manager.collageLabelWindows[parent])
        }
    }

    @MainActor
    func testNativePlacementDragUsesSharedGeometryAndEscapeRestoresStyle() throws {
        try fixture { manager, parent, _ in
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            let id = settings.labels[0].id
            let canvas = CollagePreviewView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
            let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            defer { window.orderOut(nil); window.contentView = nil }
            canvas.onMoveLabel = { label, center in
                var style = settings.labelStyle(for: label); style.placement = .free
                style.positionX = center.x; style.positionY = center.y; settings.setLabelStyle(style, for: label)
                canvas.configure(manager: manager, id: parent, settings: settings, selectedLabel: label)
            }
            canvas.onRestoreLabel = { label, style in settings.setLabelStyle(style, for: label) }
            canvas.configure(manager: manager, id: parent, settings: settings, selectedLabel: id)
            canvas.layoutSubtreeIfNeeded()
            let deadline = Date(timeIntervalSinceNow: 2)
            while canvas.renderGeneration == 0 && Date() < deadline { pump() }
            let hit = try XCTUnwrap(canvas.labelLayouts.first { $0.label.id == id })
            let point = CGPoint(x: hit.rect.midX, y: hit.rect.midY)
            let original = settings.labelStyle(for: id)
            canvas.mouseDown(with: try mouse(.leftMouseDown, window, point))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, window, CGPoint(x: point.x + 50, y: point.y + 20)))
            XCTAssertGreaterThan(settings.labelStyle(for: id).positionX, original.positionX)
            XCTAssertGreaterThan(settings.labelStyle(for: id).positionY, original.positionY)
            canvas.cancelOperation(nil)
            XCTAssertEqual(settings.labelStyle(for: id), original)
            XCTAssertEqual(manager.photos.first { $0.id == parent }!.desktopCollage!.labels[0].style, original)
        }
    }

    @MainActor
    func testFontImportArchiveRoundTripRemapsAssetsAndInvalidFilesLeaveSceneAlone() throws {
        try fixture { manager, parent, _ in
            let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf")
            let imported = try CollageFontLibrary.importFont(from: source, into: manager.storageDir)
            XCTAssertTrue(CollageFontLibrary.isManagedFilename(imported.fileName))
            XCTAssertTrue(imported.names.contains("Georgia"))
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            settings.labels[0].style.font = .custom; settings.labels[0].style.fontName = "Georgia"
            settings.labels[0].style.fontFileName = imported.fileName; settings.labels[0].style.weight = .original
            XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings))
            let archive = manager.storageDir.appendingPathComponent("fonts.arras")
            try manager.exportLayout(to: archive)
            XCTAssertEqual(try manager.importLayout(from: archive, mode: .merge), 3)
            let copy = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil && $0.id != parent })
            let newStyle = copy.desktopCollage!.labels[0].style
            XCTAssertEqual(newStyle.fontName, "Georgia")
            XCTAssertNotEqual(newStyle.fontFileName, imported.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: CollageFontLibrary.directory(in: manager.storageDir).appendingPathComponent(newStyle.fontFileName!).path))
            let before = manager.photos.count
            let assets = try FileManager.default.contentsOfDirectory(atPath: CollageFontLibrary.directory(in: manager.storageDir).path)
            XCTAssertThrowsError(try CollageFontLibrary.importFont(data: Data("not a font".utf8), extension: "ttf", into: manager.storageDir))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: CollageFontLibrary.directory(in: manager.storageDir).path).sorted(), assets.sorted())
            XCTAssertEqual(manager.photos.count, before)
            try FileManager.default.removeItem(at: imported.url)
            XCTAssertThrowsError(try manager.exportLayout(to: manager.storageDir.appendingPathComponent("missing.arras")))
            XCTAssertEqual(manager.photos.count, before)
        }
    }

    @MainActor
    func testCrossDisplayCompositionImportKeepsGapTypographyAndImageConfigurationsTogether() throws {
        try fixture { manager, parent, members in
            var originals = [manager.photos.first { $0.id == parent }!] + members.map { id in manager.photos.first { $0.id == id }! }
            let alternate = CGRect(x: 180, y: 210, width: 240, height: 180)
            originals[1].folderImageConfigs["alternate.png"] = FolderImageConfig(frameString: NSStringFromRect(alternate), widgetWidth: 240)
            let body = NSRectFromString(originals[0].frameString)
            let target = CGRect(x: 200, y: 300, width: body.width * 1.8, height: body.height * 1.8)
            let transformed = manager.adaptImportedCollage(originals, to: target, in: CGRect(x: 0, y: 0, width: 2000, height: 1800))
            XCTAssertEqual(transformed[0].desktopCollage!.compositionScale, 1.8, accuracy: 0.001)
            let one = NSRectFromString(transformed[1].frameString), two = NSRectFromString(transformed[2].frameString)
            XCTAssertEqual(two.minX - one.maxX, 36, accuracy: 0.001)
            let changed = CollageGeometry.changingGap([one, two], from: 36, to: 54)
            XCTAssertEqual(changed[1].minX - changed[0].maxX, 54, accuracy: 0.001)
            XCTAssertEqual(transformed[0].desktopCollage!.labels, originals[0].desktopCollage!.labels)
            XCTAssertEqual(transformed[1].cornerRadius, originals[1].cornerRadius * 1.8, accuracy: 0.001)
            XCTAssertEqual(transformed[1].matWidth, originals[1].matWidth * 1.8, accuracy: 0.001)
            let config = try XCTUnwrap(transformed[1].folderImageConfigs["alternate.png"])
            XCTAssertEqual(config.widgetWidth, 432, accuracy: 0.001)
            let newBody = NSRectFromString(transformed[0].frameString)
            let expected = CollageGeometry.scaled(alternate, around: body.origin, by: 1.8)
                .offsetBy(dx: newBody.minX - body.minX, dy: newBody.minY - body.minY)
            XCTAssertEqual(NSRectFromString(config.frameString).minX, expected.minX, accuracy: 0.001)
            XCTAssertEqual(NSRectFromString(config.frameString).minY, expected.minY, accuracy: 0.001)
            XCTAssertEqual(NSRectFromString(config.frameString).size, expected.size)
        }
    }

    @MainActor
    func testPaperPresetsAndLabelCanvasRenderArtifactsWithMatchingText() throws {
        try fixture { manager, parent, _ in
            let canvas = CollagePreviewView(frame: CGRect(x: 0, y: 0, width: 680, height: 410))
            canvas.appearance = NSAppearance(named: .aqua)
            canvas.onMoveLabel = { _, _ in }
            var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
            for preset in [CollagePreset.whitePolaroid, .gallery, .ink] {
                settings.applyPreset(preset)
                settings.caption = "September, kept close."
                settings.labels[0].style.font = .handwritten
                settings.labels[0].style.rotationDegrees = -5
                canvas.configure(manager: manager, id: parent, settings: settings, selectedLabel: settings.labels[0].id)
                canvas.layoutSubtreeIfNeeded(); pump()
                XCTAssertEqual(canvas.labelLayouts.map(\.label.text), settings.textLabels.map(\.text))
                let board = canvas.subviews[0]
                XCTAssertEqual(NSColor(cgColor: board.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!.alphaComponent, 1)
                if preset == .whitePolaroid { XCTAssertEqual(NSColor(cgColor: board.layer!.backgroundColor!)!.usingColorSpace(.sRGB)!.redComponent, 1, accuracy: 0.001) }

            }
        }
    }

    @MainActor
    private func fixture(_ body: (PhotoManager, UUID, [UUID]) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollageLabels-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: directory)
        defer {
            manager.cancelCollageInteractions(endAppearancePreviews: true)
            manager.windows.values.forEach { $0.hidePhoto() }; manager.windows.removeAll()
            manager.collageLabelWindows.values.forEach { $0.orderOut(nil) }; manager.collageLabelWindows.removeAll()
            try? FileManager.default.removeItem(at: directory)
        }
        var ids: [UUID] = []
        for frame in [CGRect(x: 150, y: 220, width: 200, height: 230), CGRect(x: 370, y: 300, width: 260, height: 150)] {
            let image = NSImage(size: frame.size, flipped: false) { bounds in
                NSColor(calibratedRed: 0.9, green: 0.83, blue: 0.68, alpha: 1).setFill(); bounds.fill()
                NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 40, dy: 40)).fill(); return true
            }
            var item = PhotoItem(filename: UUID().uuidString + ".png", width: frame.width)
            item.frameString = NSStringFromRect(frame); item.cornerRadius = 4
            try StarterArtwork.pngData(for: image).write(to: manager.storageDir.appendingPathComponent(item.filename))
            manager.photos.append(item); manager.createWindow(for: item, content: .still(image)); ids.append(item.id)
        }
        let parent = try XCTUnwrap(manager.addDesktopCollage(skin: .polaroid))
        for id in ids { manager.photos[manager.photos.firstIndex { $0.id == id }!].collageParentID = parent }
        manager.fitCollageModel(parent); manager.fitCollageWindow(parent, animated: false); manager.syncCollages()
        var settings = manager.photos.first { $0.id == parent }!.desktopCollage!
        settings.caption = "September"
        var style = CollageLabelStyle(); style.widthFraction = 0.45; style.positionY = 0.75
        settings.labels = [CollageTextLabel(text: "A good day", style: style)]
        XCTAssertTrue(manager.applyCollageSettings(parent, settings: settings)); settle(manager)
        try body(manager, parent, ids)
    }

    @MainActor private func settle(_ manager: PhotoManager) {
        for flight in Array(manager.collageFlights.values) { flight.currentProgress = 1 }
        for group in manager.windows.values.compactMap({ $0 as? CollageDesktopWindow }) { group.transition?.currentProgress = 1 }
    }
    @MainActor private func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06)) }
    private func frame(_ actual: CGRect, _ expected: CGRect) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
    }
    private func mouse(_ type: NSEvent.EventType, _ window: NSWindow, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .option, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

extension CollageLabelTests {
    func testExplicitFontCleanupPreservesReferencedFontsAndUnmanagedFiles() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasFontCleanup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf")
        let retained = try CollageFontLibrary.importFont(from: source, into: storage)
        let unused = try CollageFontLibrary.importFont(from: source, into: storage)
        let unmanaged = CollageFontLibrary.directory(in: storage).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unmanaged)
        XCTAssertEqual(try CollageFontLibrary.removeUnused(in: storage, retaining: [retained.fileName]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))
        XCTAssertEqual(try CollageFontLibrary.removeUnused(in: storage, retaining: [retained.fileName]), 0)
        var item = PhotoItem(filename: "")
        item.desktopCollage = DesktopCollageSettings()
        item.desktopCollage!.captionStyle.fontFileName = retained.fileName
        let store = storage.appendingPathComponent("photos.json")
        try JSONEncoder().encode([item]).write(to: store)
        XCTAssertEqual(try CollageFontLibrary.removeUnused(in: storage, retaining: []), 0)
        try Data("broken".utf8).write(to: store)
        XCTAssertThrowsError(try CollageFontLibrary.removeUnused(in: storage, retaining: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.url.path))
    }
}
