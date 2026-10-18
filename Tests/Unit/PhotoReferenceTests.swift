import AppKit
import AVFoundation
import CoreImage
import XCTest
@testable import Arras

final class PhotoReferenceTests: XCTestCase {
    func testLegacyDecodeNormalizationAndSafeSourceLinks() throws {
        let empty = try JSONDecoder().decode(PhotoReferenceSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.hasImageEdits)
        var edits = empty
        edits.quarterTurns = -5
        edits.cropWidth = 0.4
        edits.cropX = 0.9
        edits.cropHeight = .infinity
        edits.cropY = .nan
        XCTAssertEqual(edits.normalized.quarterTurns, 3)
        XCTAssertEqual(edits.normalized.cropX, 0.6)
        XCTAssertEqual(edits.normalized.cropHeight, 1)
        XCTAssertEqual(edits.normalized.cropY, 0)
        for unsafe in ["file:///tmp/photo", "javascript:alert(1)", "https://user:secret@example.com"] {
            edits.sourceURL = unsafe
            XCTAssertNil(edits.webURL)
        }
        edits.sourceURL = "https://example.com/reference"
        XCTAssertNotNil(edits.webURL)
        let key = edits.renderKey
        edits.note = "Different notes"
        XCTAssertEqual(edits.renderKey, key)
        var photo = PhotoItem(filename: "original.png")
        photo.reference = edits.normalized
        let decoded = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(photo))
        XCTAssertEqual(decoded.reference, photo.reference)
    }

    func testCropRotationFlipAndGrayscaleUseOriginalCoordinates() throws {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 2))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let original = blue.composited(over: red)
        var settings = PhotoReferenceSettings()
        settings.cropX = 0.5
        settings.cropWidth = 0.5
        settings.quarterTurns = 1
        var result = PhotoReferenceRenderer.filtered(original, settings: settings)
        XCTAssertEqual(result.extent, CGRect(x: 0, y: 0, width: 2, height: 2))
        var pixel = [UInt8](repeating: 0, count: 4)
        func sample(_ image: CIImage) -> [UInt8] {
            PhotoReferenceRenderer.context.render(image, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel
        }
        XCTAssertGreaterThan(sample(result)[0], 240)
        settings = PhotoReferenceSettings()
        XCTAssertGreaterThan(sample(PhotoReferenceRenderer.filtered(original, settings: settings))[2], 240)
        settings.flipHorizontal = true
        XCTAssertGreaterThan(sample(PhotoReferenceRenderer.filtered(original, settings: settings))[0], 240)
        settings.grayscale = true
        result = PhotoReferenceRenderer.filtered(original, settings: settings)
        let gray = sample(result)
        XCTAssertEqual(Int(gray[0]), Int(gray[1]), accuracy: 1)
        XCTAssertEqual(Int(gray[1]), Int(gray[2]), accuracy: 1)
        settings.quarterTurns = 1
        XCTAssertEqual(PhotoReferenceRenderer.outputSize(for: CGSize(width: 4, height: 2), settings: settings), CGSize(width: 2, height: 4))
    }

    func testAnimatedEditsPreserveTimingAndOriginalFrames() throws {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4))
        let cg = try XCTUnwrap(PhotoReferenceRenderer.context.createCGImage(source, from: source.extent))
        let poster = NSImage(cgImage: cg, size: source.extent.size)
        let frames = AnimatedImageFrames(images: [cg, cg], delays: [0.1, 0.3], loopCount: 2)
        var settings = PhotoReferenceSettings()
        settings.quarterTurns = 1
        let edited = PhotoReferenceRenderer.content(.animated(frames, representative: poster), settings: settings)
        guard case .animated(let output, let image) = edited else { return XCTFail("Lost animation") }
        XCTAssertEqual(output.delays, frames.delays)
        XCTAssertEqual(output.loopCount, 2)
        XCTAssertEqual(output.images.count, 2)
        XCTAssertEqual(output.images[0].width, 4)
        XCTAssertEqual(output.images[0].height, 8)
        XCTAssertEqual(image.size, CGSize(width: 4, height: 8))
        XCTAssertEqual(cg.width, 8)
        XCTAssertEqual(poster.size, CGSize(width: 8, height: 4))
    }

    func testMovieCompositionRendersCropAndRotationAtSourceResolution() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adapter.pixelBufferPool)
        var allocated: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &allocated), kCVReturnSuccess)
        let buffer = try XCTUnwrap(allocated)
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 32))
        PhotoReferenceRenderer.context.render(blue.composited(over: red), to: buffer)
        for _ in 0..<100 where !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(input.isReadyForMoreMediaData)
        XCTAssertTrue(adapter.append(buffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        let asset = AVURLAsset(url: url)
        var edits = PhotoReferenceSettings()
        edits.cropX = 0.5
        edits.cropWidth = 0.5
        edits.quarterTurns = 1
        let composition = try await PhotoReferenceRenderer.videoComposition(for: asset, settings: edits)
        XCTAssertEqual(composition.renderSize, CGSize(width: 32, height: 32))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.appliesPreferredTrackTransform = true
        let rendered = try await generator.image(at: .zero).image
        XCTAssertEqual(rendered.width, 32)
        XCTAssertEqual(rendered.height, 32)
        let result = CIImage(cgImage: rendered)
        var pixel = [UInt8](repeating: 0, count: 4)
        PhotoReferenceRenderer.context.render(result, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 16, y: 16, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertGreaterThan(pixel[2], 220, "The cropped movie should contain the blue half")
        XCTAssertLessThan(pixel[0], 30)
    }

    @MainActor
    func testRotationRefitsVisibleCanvasAndSurvivesWindowRecreation() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let photo = try XCTUnwrap(manager.photos.first)
            let originalWindow = try XCTUnwrap(manager.windows[photo.id])
            let original = originalWindow.photoFrame
            var edits = photo.reference
            edits.quarterTurns = 1
            try manager.applyReference(edits, to: photo.id, replacing: photo.reference)
            let rotated = try XCTUnwrap(manager.windows[photo.id]).photoFrame
            XCTAssertEqual(rotated.origin, original.origin)
            XCTAssertEqual(rotated.width, original.width, accuracy: 0.01)
            XCTAssertEqual(rotated.height, original.width * original.width / original.height, accuracy: 0.1)
            let edited = try XCTUnwrap(manager.photos.first)
            manager.windows.removeValue(forKey: edited.id)?.hidePhoto()
            manager.createWindow(for: edited, content: try XCTUnwrap(manager.loadDisplayContent(for: edited)))
            XCTAssertEqual(manager.windows[edited.id]?.photoFrame, rotated)
            try manager.applyReference(photo.reference, to: photo.id, replacing: edits)
            XCTAssertEqual(try XCTUnwrap(manager.windows[photo.id]).photoFrame.height, original.height, accuracy: 0.1)
        }
    }

    @MainActor
    func testReferenceRotationRefitsAndSavesVisibleAndHiddenCollages() throws {
        for hidden in [false, true] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.galleryWall, makeVisible: !hidden))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                // Hide the group, preserving the members' individual visibility.
                // Individually hidden members intentionally do not expand its bounds.
                for index in manager.photos.indices where manager.photos[index].collageParentID == parent.id {
                    manager.photos[index].isVisible = true
                }
                let members = manager.collageMembers(parent.id)
                let item = try XCTUnwrap(members.first { NSRectFromString($0.frameString).width > NSRectFromString($0.frameString).height })
                let content = try XCTUnwrap(manager.loadDisplayContent(for: item))
                var original = manager.windows[item.id]?.photoFrame ?? NSRectFromString(item.frameString)
                original.size.height = original.width * content.size.height / content.size.width
                manager.windows[item.id]?.setPhotoFrame(original)
                manager.storeCollageFrame(item.id, original)
                if hidden {
                    let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == item.id })
                    manager.photos[index].displayIdentifier = "reference-hidden-display"
                    manager.photos[index].savedDisplayFrames = ["reference-hidden-display": NSStringFromRect(original),
                                                               "other-display": "{{10, 20}, {90, 60}}"]
                }
                manager.fitCollageModel(parent.id)
                manager.fitCollageWindow(parent.id, animated: false)
                XCTAssertTrue(manager.persist())
                let originalBounds = NSRectFromString(try XCTUnwrap(manager.photos.first { $0.id == parent.id }).frameString)
                let siblings = manager.photos.filter { $0.collageParentID == parent.id && $0.id != item.id }
                let siblingFrames = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, manager.windows[$0.id]?.photoFrame) })
                let siblingWindows = siblings.compactMap { manager.windows[$0.id] }
                let originalBytes = try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename))
                var edits = item.reference
                edits.quarterTurns = 1
                try manager.applyReference(edits, to: item.id, replacing: item.reference)
                (manager.windows[parent.id] as? CollageDesktopWindow)?.transition?.currentProgress = 1
                let stored = try JSONDecoder().decode([PhotoItem].self,
                    from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                let rotated = try XCTUnwrap(stored.first { $0.id == item.id })
                let resized = NSRectFromString(rotated.frameString)
                let bounds = NSRectFromString(try XCTUnwrap(stored.first { $0.id == parent.id }).frameString)
                XCTAssertEqual(rotated.collageParentID, parent.id)
                XCTAssertEqual(rotated.reference, edits)
                XCTAssertEqual(resized.height, original.width * content.size.width / content.size.height, accuracy: 0.01)
                XCTAssertGreaterThan(bounds.height, originalBounds.height)
                XCTAssertTrue(bounds.contains(resized), "Saved backdrop must enclose the rotated member, including while hidden")
                if hidden {
                    XCTAssertEqual(rotated.displayIdentifier, "reference-hidden-display")
                    XCTAssertEqual(rotated.savedDisplayFrames["reference-hidden-display"], rotated.frameString)
                    XCTAssertEqual(rotated.savedDisplayFrames["other-display"], "{{10, 20}, {90, 60}}")
                }
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename)), originalBytes)
                for sibling in siblings {
                    XCTAssertEqual(try photoDictionary(try XCTUnwrap(stored.first { $0.id == sibling.id })) as NSDictionary,
                                   try photoDictionary(sibling) as NSDictionary)
                    XCTAssertEqual(manager.windows[sibling.id]?.photoFrame, siblingFrames[sibling.id] ?? nil)
                }
                for window in siblingWindows { XCTAssertTrue(manager.windows[try XCTUnwrap(window.photoId)] === window) }
                if hidden { XCTAssertTrue(manager.windows.isEmpty) }
                else {
                    XCTAssertEqual(manager.windows[parent.id]?.photoFrame, bounds)
                    XCTAssertEqual(manager.windows[item.id]?.photoFrame.height ?? 0, resized.height, accuracy: 1)
                }
                try manager.applyReference(item.reference, to: item.id, replacing: edits)
                (manager.windows[parent.id] as? CollageDesktopWindow)?.transition?.currentProgress = 1
                let restored = try JSONDecoder().decode([PhotoItem].self,
                    from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                XCTAssertEqual(NSRectFromString(try XCTUnwrap(restored.first { $0.id == parent.id }).frameString), originalBounds,
                               "Removing the rotation must also shrink the saved backdrop")
                XCTAssertEqual(manager.photos.first { $0.id == parent.id }?.desktopCollage, parent.desktopCollage)
                if hidden { XCTAssertTrue(manager.windows.isEmpty) }
                else { XCTAssertEqual(manager.windows[parent.id]?.photoFrame, originalBounds) }
            }
        }
    }

    @MainActor
    func testReferenceEditsPreserveAffectedNativeGesturesAndAllowUnrelatedEdits() throws {
        for grouped in [false, true] {
            for resizing in [false, true] {
                try withTestLibrary { manager in
                    if grouped { XCTAssertTrue(manager.addStarterExample(.galleryWall)) }
                    else { XCTAssertTrue(manager.addStarterExample(.minimal)) }
                    let item = try XCTUnwrap(manager.photos.first { $0.desktopCollage == nil })
                    if let parent = item.collageParentID, manager.photos.first(where: { $0.id == parent })?.isLocked == true {
                        manager.toggleLock(parent)
                    }
                    if manager.photos.first(where: { $0.id == item.id })?.isLocked == true { manager.toggleLock(item.id) }
                    XCTAssertTrue(manager.addStarterExample(.minimal))
                    let other = try XCTUnwrap(manager.photos.last)
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
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                    let frame = window.photoFrame
                    let image = try XCTUnwrap(view.photoLayer.image)
                    var edits = item.reference
                    edits.quarterTurns = 1
                    XCTAssertThrowsError(try manager.applyReference(edits, to: item.id, replacing: item.reference))
                    XCTAssertEqual(try encoder.encode(manager.photos), before)
                    XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored)
                    XCTAssertTrue(manager.windows[item.id] === window)
                    XCTAssertEqual(window.photoFrame, frame)
                    XCTAssertTrue(view.photoLayer.image === image)
                    XCTAssertNotNil(manager.collageDrags[item.id])
                    try manager.applyReference(edits, to: other.id, replacing: other.reference)
                    XCTAssertEqual(manager.photos.first { $0.id == other.id }?.reference, edits)
                    XCTAssertTrue(manager.windows[item.id] === window)
                    XCTAssertEqual(window.photoFrame, frame)
                    XCTAssertNotNil(manager.collageDrags[item.id])
                    view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: moved))
                    manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                    XCTAssertNil(manager.collageDrags[item.id])
                    let current = try XCTUnwrap(manager.photos.first { $0.id == item.id })
                    try manager.applyReference(edits, to: item.id, replacing: current.reference)
                    XCTAssertEqual(manager.photos.first { $0.id == item.id }?.reference, edits)
                }
            }
        }
    }

    @MainActor
    func testReferenceNotesAndUnchangedApplyKeepNativeMediaAndResizeHistory() throws {
        for example in [StarterExample.minimal, .animated, .rotatingSpace, .galleryWall] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(example))
                let photo = try XCTUnwrap(manager.photos.first { $0.desktopCollage == nil })
                if let parent = photo.collageParentID, manager.photos.first(where: { $0.id == parent })?.isLocked == true {
                    manager.toggleLock(parent)
                }
                if manager.photos.first(where: { $0.id == photo.id })?.isLocked == true { manager.toggleLock(photo.id) }
                let window = try XCTUnwrap(manager.windows[photo.id])
                let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
                let pickup = CGPoint(x: window.photoFrame.maxX - 1, y: window.photoFrame.maxY - 1)
                let moved = CGPoint(x: pickup.x + 18, y: pickup.y + 12)
                view.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: pickup))
                view.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: window, at: moved, modifiers: .option))
                XCTAssertEqual(manager.collageDrags[photo.id]?.resized, true)
                view.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: moved))
                manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                XCTAssertTrue(manager.canUndoArrangement)
                let image = try XCTUnwrap(view.photoLayer.image)
                let ids = Set(manager.photos.map(\.id))
                let placement = manager.arrangementSnapshot(ids: ids)
                let frame = window.photoFrame
                let filename = photo.spaceImageFilenames[safe: photo.folderImageIndex] ?? photo.filename
                let sourceBytes = try Data(contentsOf: manager.storageDir.appendingPathComponent(filename))
                var reference = photo.reference
                for changeNotes in [false, true] {
                    var edits = reference
                    if changeNotes { edits.note = "Sample reference notes"; edits.sourceURL = "https://example.com/sample" }
                    try manager.applyReference(edits, to: photo.id, replacing: reference)
                    XCTAssertTrue(manager.windows[photo.id] === window, example.rawValue)
                    XCTAssertTrue(window.contentView === view, example.rawValue)
                    XCTAssertTrue(view.photoLayer.image === image, example.rawValue)
                    XCTAssertEqual(view.referenceSettings, edits, example.rawValue)
                    XCTAssertEqual(window.photoFrame, frame, example.rawValue)
                    XCTAssertEqual(manager.arrangementSnapshot(ids: ids), placement, example.rawValue)
                    XCTAssertTrue(manager.canUndoArrangement, example.rawValue)
                    let stored = try JSONDecoder().decode([PhotoItem].self,
                        from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                    XCTAssertEqual(stored.first { $0.id == photo.id }?.reference, edits)
                    XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(filename)), sourceBytes)
                    reference = edits
                }
                XCTAssertTrue(manager.undoArrangement())
                manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                XCTAssertEqual(manager.photos.first { $0.id == photo.id }?.reference, reference)
                XCTAssertTrue(manager.redoArrangement())
                XCTAssertEqual(manager.photos.first { $0.id == photo.id }?.reference, reference)
            }
        }
    }

    @MainActor
    func testHiddenPhotoEditsPersistWithoutChangingMediaOrPlacementAndRejectStaleDraft() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let photo = try XCTUnwrap(manager.photos.first)
            let url = manager.storageDir.appendingPathComponent(photo.filename)
            let bytes = try Data(contentsOf: url)
            var edits = PhotoReferenceSettings()
            edits.quarterTurns = 1
            edits.note = "Reference note"
            try manager.applyReference(edits, to: photo.id, replacing: photo.reference)
            XCTAssertNil(manager.windows[photo.id])
            XCTAssertEqual(NSRectFromString(manager.photos[0].frameString).origin, NSRectFromString(photo.frameString).origin)
            XCTAssertEqual(NSRectFromString(manager.photos[0].frameString).width, NSRectFromString(photo.frameString).width)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            XCTAssertEqual(saved[0].reference, edits)
            XCTAssertThrowsError(try manager.applyReference(PhotoReferenceSettings(), to: photo.id, replacing: photo.reference))
            XCTAssertEqual(manager.photos[0].reference, edits)
        }
    }

    @MainActor
    func testDuplicateAndArchiveKeepEditsWhileAppearanceCopyKeepsTargetContent() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let photo = try XCTUnwrap(manager.photos.first)
            var edits = PhotoReferenceSettings()
            edits.flipVertical = true
            edits.note = "Original context"
            edits.sourceURL = "https://example.com/art"
            try manager.applyReference(edits, to: photo.id, replacing: photo.reference)
            manager.duplicatePhoto(photo.id)
            let duplicate = try XCTUnwrap(manager.photos.first { $0.id != photo.id })
            XCTAssertEqual(duplicate.reference, edits)
            try manager.applyReference(PhotoReferenceSettings(), to: duplicate.id, replacing: edits)
            XCTAssertTrue(manager.copyAppearance(of: photo.id))
            XCTAssertTrue(manager.pasteAppearance(to: [duplicate.id]))
            XCTAssertEqual(manager.photos.first { $0.id == duplicate.id }?.reference, PhotoReferenceSettings())
            let archive = manager.storageDir.appendingPathComponent("reference.arras")
            try manager.exportWidget(photo.id, to: archive)
            try withTestLibrary { target in
                XCTAssertEqual(try target.importLayout(from: archive, mode: .merge), 1)
                XCTAssertEqual(target.photos.first?.reference, edits)
                let imported = try XCTUnwrap(target.photos.first)
                XCTAssertEqual(try Data(contentsOf: target.storageDir.appendingPathComponent(imported.filename)),
                               try Data(contentsOf: manager.storageDir.appendingPathComponent(photo.filename)))
            }
        }
    }

    @MainActor
    func testFailedSaveRollsBackReferenceEdits() throws {
        for example in [StarterExample.minimal, .galleryWall] {
            for (visible, metadataOnly) in [(false, false), (false, true), (true, false), (true, true)] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(example, makeVisible: visible))
                    let photo = try XCTUnwrap(manager.photos.first { $0.desktopCollage == nil })
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let before = try encoder.encode(manager.photos)
                    let windows = manager.windows
                    let frames = windows.mapValues(\.photoFrame)
                    let store = manager.storageDir.appendingPathComponent("photos.json")
                    let unreadableStore = Data("broken".utf8)
                    try unreadableStore.write(to: store)
                    var edits = photo.reference
                    if metadataOnly { edits.note = "Unsaved notes"; edits.sourceURL = "https://example.com/unsaved" }
                    else { edits.quarterTurns = 1; edits.cropWidth = 0.75 }
                    XCTAssertThrowsError(try manager.applyReference(edits, to: photo.id, replacing: photo.reference))
                    XCTAssertEqual(try encoder.encode(manager.photos), before)
                    XCTAssertEqual(try Data(contentsOf: store), unreadableStore)
                    XCTAssertEqual(Set(manager.windows.keys), Set(windows.keys))
                    for (id, window) in windows {
                        XCTAssertTrue(manager.windows[id] === window)
                        XCTAssertEqual(window.photoFrame, frames[id])
                    }
                }
            }
        }
    }
}
