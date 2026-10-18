import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Arras

final class MediaReplacementTests: XCTestCase {
    @MainActor
    func testFailedReplacementNeverChangesNativeMediaOrCollageGeometry() async throws {
        for scenario in ["photo", "slideshow", "fixed slideshow", "member", "member slideshow"] {
            let root = try temporaryDirectory()
            let manager = PhotoManager(storageDirectory: root.appendingPathComponent("store"))
            defer {
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            let slideshow = scenario.contains("slideshow")
            XCTAssertTrue(manager.addStarterExample(slideshow ? .rotatingSpace : .minimal))
            let id = try XCTUnwrap(manager.photos.first?.id)
            if slideshow { manager.setRotationInterval(id, "click") }
            if scenario == "fixed slideshow" { manager.setFolderSizeMode(id, "fixed") }
            var parent: UUID?
            if scenario.contains("member") {
                parent = try XCTUnwrap(manager.addDesktopCollage())
                let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == id })
                manager.photos[index].collageParentID = parent
                manager.syncCollages()
            }
            XCTAssertTrue(manager.persist())
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(manager.photos)
            let window = try XCTUnwrap(manager.windows[id])
            let view = try XCTUnwrap(window.contentView as? DraggablePhotoView)
            let image = try XCTUnwrap(view.photoLayer.image)
            let frame = window.photoFrame
            let parentFrame = parent.flatMap { manager.windows[$0]?.photoFrame }
            let playlists = manager.spaceImages
            var geometryChanges = 0
            let callback = window.onVisualGeometryChanged
            window.onVisualGeometryChanged = { geometryChanges += 1; callback?() }
            let source = root.appendingPathComponent("portrait.png")
            try StarterArtwork.pngData(for: StarterArtwork.image(for: .polaroid)).write(to: source)
            let damaged = Data("{ replacement save refused".utf8)
            let produced = root.appendingPathComponent("prepared.json")
            manager.prepareImportedURL = { url, directory in
                guard let prepared = PhotoIngest.prepare(contentsOf: url, in: directory) else { return nil }
                do {
                    try JSONEncoder().encode(prepared.managedURLs.map(\.lastPathComponent)).write(to: produced)
                    try damaged.write(to: directory.appendingPathComponent("photos.json"), options: .atomic)
                    return prepared
                } catch { return nil }
            }

            let result = await manager.replacePhoto(id, with: source)

            XCTAssertEqual(result.failedCount, 1, scenario)
            XCTAssertEqual(try encoder.encode(manager.photos), before, scenario)
            XCTAssertTrue(view.photoLayer.image === image, scenario)
            XCTAssertEqual(window.photoFrame, frame, scenario)
            XCTAssertEqual(geometryChanges, 0, scenario)
            XCTAssertEqual(manager.spaceImages, playlists, scenario)
            if let parent { XCTAssertEqual(manager.windows[parent]?.photoFrame, parentFrame, scenario) }
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), damaged)
            let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: produced))
            for name in names { XCTAssertFalse(FileManager.default.fileExists(atPath: manager.storageDir.appendingPathComponent(name).path)) }
        }
    }

    @MainActor
    func testReplacementPersistsEditedGeometryForHiddenPhotosAndSavedSetups() async throws {
        for scenario in ["visible", "hidden", "member"] {
            let root = try temporaryDirectory()
            let manager = PhotoManager(storageDirectory: root.appendingPathComponent("store"))
            defer {
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let id = try XCTUnwrap(manager.photos.first?.id)
            var edits = PhotoReferenceSettings()
            edits.quarterTurns = 1
            edits.cropWidth = 0.5
            manager.photos[0].reference = edits
            manager.photos[0].isVisible = scenario != "hidden"
            var parent: UUID?
            if scenario == "member" {
                parent = try XCTUnwrap(manager.addDesktopCollage())
                let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == id })
                manager.photos[index].collageParentID = parent
            }
            XCTAssertTrue(manager.restoreDesktopSetupItems(manager.photos))
            if let frame = manager.windows[id]?.photoFrame { manager.storeCollageFrame(id, frame) }
            if let parent { manager.fitCollageModel(parent); manager.fitCollageWindow(parent, animated: false) }
            XCTAssertTrue(manager.persist())
            let item = try XCTUnwrap(manager.photos.first { $0.id == id })
            let beforeFrame = manager.windows[id]?.photoFrame ?? NSRectFromString(item.frameString)
            let source = root.appendingPathComponent("portrait.png")
            try StarterArtwork.pngData(for: StarterArtwork.image(for: .polaroid)).write(to: source)
            let content = try XCTUnwrap(PhotoContent.load(from: source))
            let rendered = PhotoReferenceRenderer.outputSize(for: content.size, settings: edits)
            let height = beforeFrame.width * rendered.height / rendered.width
            let expected = CGRect(x: beforeFrame.minX, y: beforeFrame.maxY - height, width: beforeFrame.width, height: height)

            let result = await manager.replacePhoto(id, with: source)

            XCTAssertEqual(result.acceptedCount, 1, scenario)
            let stored = try JSONDecoder().decode([PhotoItem].self,
                from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            let replaced = try XCTUnwrap(stored.first { $0.id == id })
            assertReplacementFrame(NSRectFromString(replaced.frameString), matches: expected, context: scenario)
            XCTAssertEqual(replaced.collageParentID, parent)
            XCTAssertEqual(replaced.reference, edits)
            if scenario == "hidden" { XCTAssertNil(manager.windows[id]); manager.toggleVisibility(id) }
            assertReplacementFrame(manager.windows[id]?.photoFrame, matches: expected, context: scenario)
            let setup = try manager.saveDesktopSetup(named: "Replacement geometry")
            manager.resize(id, to: expected.width * 0.6)
            try manager.activateDesktopSetup(setup)
            assertReplacementFrame(manager.windows[id]?.photoFrame, matches: expected, context: scenario)
            XCTAssertEqual(manager.photos.first { $0.id == id }?.collageParentID, parent)
        }
    }

    private func assertReplacementFrame(_ actual: CGRect?, matches expected: CGRect, context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("Missing frame: " + context, file: file, line: line) }
        // Native view creation rounds its initial image height to a point.
        // Preserve placement/aspect within that rounding, never a stale canvas.
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, context, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, context, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, context, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, context, file: file, line: line)
    }

    @MainActor
    func testFailedDuplicatePreservesModelsWindowsAndManagedMedia() throws {
        for example in [StarterExample.minimal, .animated, .rotatingSpace] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(example))
                let original = try XCTUnwrap(manager.photos.first)
                let window = try XCTUnwrap(manager.windows[original.id])
                let frame = window.photoFrame
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let before = try encoder.encode(manager.photos)
                let windows = Set(manager.windows.keys)
                let playlists = Set(manager.spaceImages.keys)
                let timers = Set(manager.rotationTimers.keys)
                defer {
                    manager.rotationTimers.values.forEach { $0.cancel() }
                    manager.rotationTimers.removeAll()
                }
                @MainActor func mediaFiles() throws -> [String: Data] {
                    let urls = try FileManager.default.contentsOfDirectory(at: manager.storageDir,
                        includingPropertiesForKeys: [.isRegularFileKey])
                    return try Dictionary(uniqueKeysWithValues: urls.filter {
                        guard $0.lastPathComponent != "photos.json" else { return false }
                        return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                    }.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
                }
                let media = try mediaFiles()
                let damaged = Data("{ unreadable layout".utf8)
                let store = manager.storageDir.appendingPathComponent("photos.json")
                try damaged.write(to: store, options: .atomic)

                manager.duplicatePhoto(original.id)

                XCTAssertEqual(try encoder.encode(manager.photos), before, example.rawValue)
                XCTAssertEqual(Set(manager.windows.keys), windows, example.rawValue)
                XCTAssertTrue(manager.windows[original.id] === window, example.rawValue)
                XCTAssertEqual(window.photoFrame, frame, example.rawValue)
                XCTAssertEqual(Set(manager.spaceImages.keys), playlists, example.rawValue)
                XCTAssertEqual(Set(manager.rotationTimers.keys), timers, example.rawValue)
                XCTAssertEqual(try mediaFiles(), media, example.rawValue)
                XCTAssertEqual(try Data(contentsOf: store), damaged, example.rawValue)
            }
        }
    }

    @MainActor
    func testDuplicateHiddenSlideshowLoadsItsSnapshotAndOffsetsEveryImageFrame() throws {
        for linkedToPhotos in [false, true] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.rotatingSpace, makeVisible: false))
                var original = try XCTUnwrap(manager.photos.first)
                original.folderSizeMode = "dynamic"
                original.rotationInterval = "click"
                original.folderImageIndex = 1
                original.customName = "Sample slideshow"
                let screen = try XCTUnwrap(NSScreen.main).visibleFrame
                let origin = CGPoint(x: screen.midX - 120, y: screen.midY - 100)
                for (index, name) in original.spaceImageFilenames.enumerated() {
                    let frame = CGRect(x: origin.x + CGFloat(index * 12), y: origin.y + CGFloat(index * 8),
                                       width: 180 + CGFloat(index * 10), height: 120 + CGFloat(index * 10))
                    original.folderImageConfigs[name] = FolderImageConfig(frameString: NSStringFromRect(frame), widgetWidth: frame.width)
                }
                original.frameString = try XCTUnwrap(original.folderImageConfigs[original.spaceImageFilenames[1]]).frameString
                original.widgetWidth = NSRectFromString(original.frameString).width
                if linkedToPhotos {
                    original.photosLibrarySource = PhotosLibrarySource(localIdentifier: "fixture-album", collectionType: .userAlbum,
                                                                      displayName: "Sample album")
                    original.photosLibraryAssets = original.spaceImageFilenames.map {
                        PhotosLibraryAsset(localIdentifier: "fixture-" + $0, displayName: "Sample image", managedFilename: $0)
                    }
                }
                manager.photos = [original]
                XCTAssertTrue(manager.persist())
                XCTAssertNil(manager.spaceImages[original.id])
                XCTAssertNil(manager.windows[original.id])
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let originalBytes = try encoder.encode(original)

                manager.duplicatePhoto(original.id)

                let duplicate = try XCTUnwrap(manager.photos.first { $0.id != original.id })
                XCTAssertEqual(try encoder.encode(try XCTUnwrap(manager.photos.first { $0.id == original.id })), originalBytes)
                XCTAssertTrue(duplicate.isVisible)
                XCTAssertNil(duplicate.collageParentID)
                XCTAssertEqual(duplicate.spaceImageFilenames, original.spaceImageFilenames)
                XCTAssertEqual(duplicate.photosLibrarySource, original.photosLibrarySource)
                XCTAssertEqual(duplicate.photosLibraryAssets, original.photosLibraryAssets)
                XCTAssertEqual(manager.spaceImages[duplicate.id]?.map(\.lastPathComponent), original.spaceImageFilenames)
                for name in original.spaceImageFilenames {
                    let source = try XCTUnwrap(original.folderImageConfigs[name])
                    let copied = try XCTUnwrap(duplicate.folderImageConfigs[name])
                    XCTAssertEqual(NSRectFromString(copied.frameString), NSRectFromString(source.frameString).offsetBy(dx: 30, dy: -30))
                    XCTAssertEqual(copied.widgetWidth, source.widgetWidth)
                }
                let expected = NSRectFromString(original.frameString).offsetBy(dx: 30, dy: -30)
                let window = try XCTUnwrap(manager.windows[duplicate.id])
                XCTAssertEqual(window.photoFrame, expected)
                let saved = try JSONDecoder().decode([PhotoItem].self,
                    from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                let savedDuplicate = try XCTUnwrap(saved.first { $0.id == duplicate.id })
                XCTAssertEqual(savedDuplicate.folderImageConfigs, duplicate.folderImageConfigs)
                XCTAssertEqual(NSRectFromString(savedDuplicate.frameString), expected)
            }
        }
    }

    @MainActor
    func testURLReplacementPreservesAnimatedGIFBytesInSpace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let oldName = "old.gif"
        try gifData(colors: [.red, .blue]).write(to: storage.appendingPathComponent(oldName))

        let manager = PhotoManager(storageDirectory: storage)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = [oldName]
        space.folderImageIndex = 0
        manager.photos = [space]
        XCTAssertTrue(manager.persist())

        let replacementData = try gifData(colors: [.green, .yellow])
        let replacementURL = root.appendingPathComponent("animated replacement.gif")
        try replacementData.write(to: replacementURL)
        let result = await manager.replacePhoto(space.id, with: replacementURL)

        XCTAssertEqual(result.acceptedCount, 1)
        let newName = try XCTUnwrap(manager.photos.first?.spaceImageFilenames.first)
        XCTAssertEqual((newName as NSString).pathExtension.lowercased(), "gif")
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(newName)), replacementData)
        guard case .animated? = PhotoContent.load(from: storage.appendingPathComponent(newName)) else {
            return XCTFail("The replacement GIF should remain animated")
        }
    }

    @MainActor
    func testURLReplacementRollsBackAndCleansPreparedMediaWhenStoreBecomesCorrupt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let oldName = "old.gif"
        try gifData(colors: [.red, .blue]).write(to: storage.appendingPathComponent(oldName))

        let manager = PhotoManager(storageDirectory: storage)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = [oldName]
        manager.photos = [space]
        XCTAssertTrue(manager.persist())
        try Data("{ corrupt".utf8).write(
            to: storage.appendingPathComponent("photos.json"),
            options: .atomic
        )

        let replacementURL = root.appendingPathComponent("new.gif")
        try gifData(colors: [.green, .yellow]).write(to: replacementURL)
        let result = await manager.replacePhoto(space.id, with: replacementURL)

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(manager.photos.first?.spaceImageFilenames, [oldName])
        let managedGIFs = try FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "gif" }
        XCTAssertEqual(managedGIFs.map(\.lastPathComponent), [oldName])
    }

    @MainActor
    func testLinkedSourceRejectsManualReplaceAndAppendWithoutAdoptingMedia() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let oldName = "linked.gif"
        try gifData(colors: [.red, .blue]).write(to: storage.appendingPathComponent(oldName))

        let manager = PhotoManager(storageDirectory: storage)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = [oldName]
        space.liveFolderSource = LiveFolderSource(
            sourcePath: "/Volumes/Photos/Family Album",
            displayName: "Family Album"
        )
        manager.photos = [space]
        XCTAssertTrue(manager.persist())
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: storage.path))

        let candidate = root.appendingPathComponent("manual.gif")
        try gifData(colors: [.green, .yellow]).write(to: candidate)
        let replacement = await manager.replacePhoto(space.id, with: candidate)
        let append = await manager.appendPhotosToSpace(space.id, urls: [candidate])

        XCTAssertEqual(replacement.skippedCount, 1)
        XCTAssertEqual(append.failedCount, 1)
        XCTAssertEqual(manager.photos.first?.spaceImageFilenames, [oldName])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: storage.path)), before)
    }


    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasMediaReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func gifData(colors: [NSColor]) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.gif.identifier as CFString,
            colors.count,
            nil
        ))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for color in colors {
            let image = NSImage(size: NSSize(width: 4, height: 4))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
            image.unlockFocus()
            var proposed = NSRect(origin: .zero, size: image.size)
            let frame = try XCTUnwrap(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
