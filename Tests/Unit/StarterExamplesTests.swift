import AppKit
import XCTest
import ImageIO
import SwiftUI
@testable import Arras

final class StarterExamplesTests: XCTestCase {
    func testWebPPlaybackPreservesUnequalDelaysAndFiniteRepeatCount() throws {
        // Two 8×6 solid-color frames, 40ms + 160ms, repeat count 3.
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAABwAABQAAQU5JTQYAAAAAAAAAAwBBTk1GKAAAAAAAAAAAAAcAAAUAACgAAAJWUDhMDwAAAC8HQAEABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAcAAAUAAKAAAABWUDhMDwAAAC8HQAEABxDR//4HIqL/AQA="))
        let frames = try XCTUnwrap(AnimatedImageIO.decodeForPlayback(data: data))
        XCTAssertEqual(frames.images.count, 2)
        XCTAssertEqual(frames.delays[0], 0.04, accuracy: 0.001)
        XCTAssertEqual(frames.delays[1], 0.16, accuracy: 0.001)
        XCTAssertEqual(frames.loopCount, 3)
    }

    func testLargeAnimationKeepsTimingWithinDecodedMemoryBudget() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 640, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let frame = try XCTUnwrap(bitmap.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 120, nil))
        for _ in 0..<120 {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: 0.04]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let started = ProcessInfo.processInfo.systemUptime
        let decoded = try XCTUnwrap(AnimatedImageIO.decodeForPlayback(data: data as Data))
        print("Animation stress: 120 × 640px frames; retained bytes: \(decoded.images.reduce(0) { $0 + $1.bytesPerRow * $1.height }); decode seconds: \(ProcessInfo.processInfo.systemUptime - started)")
        XCTAssertEqual(decoded.images.count, 120)
        XCTAssertEqual(decoded.totalDuration, 4.8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(decoded.images.reduce(0) { $0 + $1.bytesPerRow * $1.height }, 64 * 1024 * 1024)
        XCTAssertLessThan(try XCTUnwrap(decoded.images.first).width, 640)
        let imported = try XCTUnwrap(NSImage(data: data as Data))
        let representation = try XCTUnwrap(imported.representations.first as? NSBitmapImageRep)
        representation.setProperty(.currentFrame, withValue: 5)
        let recovered = try XCTUnwrap(AnimatedImageIO.extractFrames(from: imported))
        XCTAssertEqual(recovered.images.count, 120)
        XCTAssertEqual(recovered.totalDuration, 4.8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(recovered.images.reduce(0) { $0 + $1.bytesPerRow * $1.height }, 64 * 1024 * 1024)
        XCTAssertEqual(representation.value(forProperty: .currentFrame) as? Int, 5)
    }

    @MainActor
    func testEveryStarterLoadsAsOrdinaryPersistedWidget() throws {
        for example in StarterExample.allCases {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(example, makeVisible: false), example.title)
                XCTAssertEqual(manager.photos.count, example.itemCount, example.title)
                XCTAssertTrue(manager.photos.allSatisfy { !$0.isVisible })
                let children = manager.photos.filter { $0.desktopCollage == nil }
                XCTAssertEqual(children.count, example.frames.count)
                for item in children {
                    XCTAssertEqual(item.media.kind, example == .animated ? .animatedImage : .still)
                    let filenames = item.spaceImageFilenames.isEmpty ? [item.filename] : item.spaceImageFilenames
                    XCTAssertEqual(filenames.count, example == .rotatingSpace ? 3 : 1)
                    for filename in filenames {
                        XCTAssertNotNil(PhotoContent.load(from: manager.storageDir.appendingPathComponent(filename)), filename)
                    }
                }
                if example.isGrouped {
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    XCTAssertTrue(parent.filename.isEmpty)
                    XCTAssertEqual(manager.collageMembers(parent.id).count, example.frames.count)
                    XCTAssertTrue(children.allSatisfy { $0.collageParentID == parent.id })
                    let settings = try XCTUnwrap(parent.desktopCollage)
                    XCTAssertFalse(settings.caption.isEmpty)
                    if example == .moodboard {
                        XCTAssertEqual(settings.skin, .transparent)
                        XCTAssertGreaterThan(settings.borderWidth, 0)
                        XCTAssertFalse(settings.labels.isEmpty)
                    }
                }
                let reloaded = PhotoManager(storageDirectory: manager.storageDir)
                XCTAssertEqual(reloaded.photos.map(\.id), manager.photos.map(\.id))
                XCTAssertEqual(reloaded.photos.map(\.collageParentID), manager.photos.map(\.collageParentID))
                XCTAssertEqual(reloaded.photos.map(\.desktopCollage), manager.photos.map(\.desktopCollage))
                XCTAssertEqual(reloaded.photos.map(\.spaceImageFilenames), manager.photos.map(\.spaceImageFilenames))
                XCTAssertTrue(reloaded.windows.isEmpty)
            }
        }
    }

    @MainActor
    func testEveryStarterCanBeEditedAndDeletedThroughNormalFlow() throws {
        for example in StarterExample.allCases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let manager = PhotoManager(storageDirectory: directory)
            XCTAssertTrue(manager.addStarterExample(example, makeVisible: false))
            let original = manager.photos
            for item in original {
                manager.renamePhoto(item.id, to: "My picture")
                if item.desktopCollage == nil {
                    manager.replacePhoto(item.id, with: artwork(color: .systemBlue))
                }
                XCTAssertEqual(manager.photos.first { $0.id == item.id }?.customName, "My picture")
                let childNames = manager.collageMembers(item.id).map(\.filename)
                manager.removePhoto(item.id)
                for filename in childNames {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
                }
            }
            XCTAssertTrue(manager.photos.isEmpty)
            XCTAssertTrue(PhotoManager(storageDirectory: directory).photos.isEmpty)
            try manager.discardRemovedWidgets()
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("starter-") })
        }
    }

    @MainActor
    func testExamplesCreateRealWindowsAtTheirSavedPositions() throws {
        for example in StarterExample.allCases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let manager = PhotoManager(storageDirectory: directory)
            XCTAssertTrue(manager.addStarterExample(example))
            XCTAssertEqual(manager.windows.count, example.itemCount)
            for item in manager.photos {
                let window = try XCTUnwrap(manager.windows[item.id])
                let expected = NSRectFromString(item.frameString)
                XCTAssertEqual(window.photoFrame.width, expected.width, accuracy: 1)
                XCTAssertEqual(window.photoFrame.height, expected.height, accuracy: 1)
                XCTAssertEqual(window.photoFrame.origin.x, expected.origin.x, accuracy: 1)
                XCTAssertEqual(window.photoFrame.origin.y, expected.origin.y, accuracy: 1)
                XCTAssertTrue(window.isVisible)
            }
            if example.isGrouped {
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                XCTAssertTrue(manager.windows[parent.id] is CollageDesktopWindow)
                XCTAssertNotNil(manager.collageLabelWindows[parent.id])
                let childWindows = manager.collageMembers(parent.id).map { manager.windows[$0.id]! }
                let before = childWindows.map(\.photoFrame)
                manager.moveCollage(parent.id, to: manager.windows[parent.id]!.photoFrame.offsetBy(dx: 20, dy: 15), finished: true)
                for (window, frame) in zip(childWindows, before) {
                    XCTAssertEqual(window.photoFrame, frame.offsetBy(dx: 20, dy: 15))
                }
            }
            for id in manager.photos.map(\.id) { manager.removePhoto(id) }
            XCTAssertTrue(manager.windows.isEmpty)
        }
    }

    @MainActor
    func testAnimationAndSpaceUseExistingPlaybackContent() throws {
        let data = try StarterArtwork.animatedGIFData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 60)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double), 0.04, accuracy: 0.001)
        XCTAssertLessThan(data.count, 1_000_000)
        for name in ["StarterCoast", "StarterBotanical", "StarterArchitecture"] {
            XCTAssertNotNil(NSImage(named: name), "Missing bundled example artwork: " + name)
        }
        let portrait = StarterArtwork.image(for: .polaroid)
        let landscape = StarterArtwork.image(for: .minimal)
        XCTAssertLessThan(portrait.size.width, portrait.size.height)
        XCTAssertGreaterThan(landscape.size.width, landscape.size.height)
        for example in StarterExample.allCases {
            let preview = try XCTUnwrap(StarterArtwork.previews[example])
            XCTAssertFalse(try StarterArtwork.pngData(for: preview).isEmpty)
            let evidence = XCTAttachment(image: preview)
            evidence.name = "Example preview — " + example.title
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            XCTAssertTrue(manager.addStarterExample(.galleryWall, makeVisible: false))
            attachView(ContentView(manager: manager).frame(width: 520, height: 760), name: "Photos library with collage")
            if let collage = manager.photos.first(where: { $0.desktopCollage != nil }) {
                attachView(DesktopCollageRow(item: collage, manager: manager).frame(width: 480), name: "Compact collage group")
            }
            manager.photos.removeAll()
            attachView(PrivacyView(manager: manager).frame(width: 460, height: 1400), name: "Privacy at minimum width")
            attachView(PreferencesView(manager: manager, navigation: SettingsNavigation()).frame(width: 460, height: 1400), name: "Preferences at minimum width")
            attachView(SavedSetupsView(manager: manager), name: "Empty saved setups")
            attachView(StarterExamplesView(manager: manager), name: "Example chooser")
            XCTAssertTrue(manager.addStarterExample(.polaroid, makeVisible: false))
            let photo = try XCTUnwrap(manager.photos.first)
            attachView(FrameInspector(item: photo, manager: manager), name: "Photo appearance with six looks")
            let thumbnail = try XCTUnwrap(manager.thumbnail(for: photo, size: 600))
            var renderedLooks = Set<Data>()
            for preset in StylePreset.allCases {
                let rendered = try XCTUnwrap(PhotoAppearancePreview.image(photo: preset.applying(to: photo),
                                                                          thumbnail: thumbnail,
                                                                          size: NSSize(width: 500, height: 220)))
                let png = try StarterArtwork.pngData(for: rendered)
                XCTAssertTrue(renderedLooks.insert(png).inserted, "Duplicate visual look: \(preset)")
                let evidence = XCTAttachment(image: rendered)
                evidence.name = "Photo look — " + preset.displayName
                evidence.lifetime = .keepAlways
                add(evidence)
            }

            attachView(CollageSettingsView(manager: manager, id: UUID(), previewSession: UUID(),
                                          editorDraft: CollageEditorDraft(item: nil), onClose: {}, onApply: {}),
                       name: "Visual collage looks")
        }
    }

    @MainActor
    private func attachView<V: View>(_ view: V, name: String) {
        let host = NSHostingView(rootView: view.padding(12).background(Color(nsColor: .windowBackgroundColor)))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not render " + name); return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testStarterAddsWithoutReplacingExistingWidgets() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var existing = PhotoItem(filename: "existing.png")
        existing.isVisible = false
        existing.customName = "Keep me"
        try StarterArtwork.pngData(for: artwork(color: .systemGreen))
            .write(to: directory.appendingPathComponent(existing.filename))
        manager.photos = [existing]
        XCTAssertTrue(manager.persist())

        XCTAssertTrue(manager.addStarterExample(.moodboard, makeVisible: false))
        XCTAssertEqual(manager.photos.first?.id, existing.id)
        XCTAssertEqual(manager.photos.first?.customName, "Keep me")
        XCTAssertEqual(manager.photos.count, 1 + StarterExample.moodboard.itemCount)
        let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
        XCTAssertEqual(manager.collageMembers(parent.id).count, 3)
        XCTAssertEqual(PhotoManager(storageDirectory: directory).photos.map(\.id), manager.photos.map(\.id))
    }

    @MainActor
    func testFailedStarterLeavesExistingModelAndFilesUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var existing = PhotoItem(filename: "existing.png")
        existing.isVisible = false
        existing.customName = "Keep me"
        try StarterArtwork.pngData(for: artwork(color: .systemGreen))
            .write(to: directory.appendingPathComponent(existing.filename))
        manager.photos = [existing]
        XCTAssertTrue(manager.persist())

        try Data("corrupt".utf8).write(
            to: directory.appendingPathComponent("photos.json"),
            options: .atomic
        )
        for example in StarterExample.allCases {
            XCTAssertFalse(manager.addStarterExample(example), example.title)
            XCTAssertEqual(manager.photos.map(\.id), [existing.id])
            XCTAssertTrue(manager.windows.isEmpty)
            XCTAssertTrue(manager.collageLabelWindows.isEmpty)
            XCTAssertTrue(manager.rotationTimers.isEmpty)
        }
        XCTAssertEqual(manager.photos.map(\.customName), ["Keep me"])
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(remainingFiles.contains { $0.hasPrefix("starter-") })
        XCTAssertTrue(remainingFiles.contains("existing.png"))
        XCTAssertTrue(remainingFiles.contains("photos-corrupt"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), Data("corrupt".utf8))
    }

    private func artwork(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 80, height: 60), flipped: false) { bounds in
            color.setFill()
            bounds.fill()
            return true
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasStarterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
