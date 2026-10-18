import AppKit
import XCTest
@testable import Arras

final class ImportPipelineTests: XCTestCase {
    @MainActor
    func testHistoricalCombinedPhotoArchiveMigratesEveryImageAndReexportsOnlySlideshowFields() throws {
        try withTestLibrary { source in
            var item = PhotoItem(filename: "")
            item.isVisible = false
            item.customName = "Saved images"
            item.spaceImageFilenames = ["a.bmp", "b.bmp"]
            source.photos = [item]
            let payload = try bmpData()
            for name in item.spaceImageFilenames {
                try payload.write(to: source.storageDir.appendingPathComponent(name))
            }
            let archive = source.storageDir.appendingPathComponent("old.arras")
            try source.exportLayout(to: archive)
            let reader = try SimpleZipReader(data: Data(contentsOf: archive))
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(reader.entryData(named: "manifest.json"))) as? [String: Any])
            var raw = try photoDictionary(item)
            raw.removeValue(forKey: "spaceImageFilenames")
            raw["isLivingCollage"] = true
            raw["livingCollageImageFilenames"] = item.spaceImageFilenames
            raw["livingCollageLayout"] = "adaptive"
            raw["livingCollageCropMode"] = "intentional"
            manifest["photos"] = [raw]
            var writer = SimpleZipWriter()
            writer.addEntry(name: "manifest.json", data: try JSONSerialization.data(withJSONObject: manifest))
            for name in item.spaceImageFilenames {
                writer.addEntry(name: "images/" + name, data: try XCTUnwrap(reader.entryData(named: "images/" + name)))
            }
            try writer.write(to: archive)
            try withTestLibrary { target in
                let preflight = try target.preflightImportLayout(from: archive)
                XCTAssertEqual(preflight.candidates.first?.typeName, "Space")
                XCTAssertEqual(try target.commitImport(preflight, selectedIDs: [0], mode: .merge), 1)
                let imported = try XCTUnwrap(target.photos.first)
                XCTAssertNotEqual(imported.id, item.id)
                XCTAssertEqual(imported.spaceImageFilenames.count, 2)
                for name in imported.spaceImageFilenames {
                    XCTAssertFalse(item.spaceImageFilenames.contains(name))
                    XCTAssertEqual(try Data(contentsOf: target.storageDir.appendingPathComponent(name)), payload)
                }
                let exported = target.storageDir.appendingPathComponent("new.arras")
                try target.exportLayout(to: exported)
                let newReader = try SimpleZipReader(data: Data(contentsOf: exported))
                let json = String(decoding: try XCTUnwrap(newReader.entryData(named: "manifest.json")), as: UTF8.self)
                XCTAssertFalse(json.lowercased().contains("livingcollage"))
                XCTAssertTrue(json.contains("spaceImageFilenames"))
            }
        }
    }

    @MainActor
    func testLegacyArchiveImportsChildrenAndDropsOnlyTheEmptyRetiredContainer() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let photo = try XCTUnwrap(manager.photos.first)
            let archive = manager.storageDir.appendingPathComponent("old.arras")
            try manager.exportWidget(photo.id, to: archive)
            let reader = try SimpleZipReader(data: Data(contentsOf: archive))
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(reader.entryData(named: "manifest.json"))) as? [String: Any])
            var child = try photoDictionary(photo)
            var container = PhotoItem(filename: ""); container.isVisible = false
            var oldContainer = try photoDictionary(container)
            oldContainer["composition"] = ["material": "bubble"]
            child["compositionParentID"] = container.id.uuidString
            child["compositionPinned"] = true
            manifest["photos"] = [oldContainer, child]; manifest["itemCount"] = 2
            var writer = SimpleZipWriter()
            writer.addEntry(name: "manifest.json", data: try JSONSerialization.data(withJSONObject: manifest))
            writer.addEntry(name: "images/" + photo.filename, data: try XCTUnwrap(reader.entryData(named: "images/" + photo.filename)))
            try writer.write(to: archive)
            let preflight = try manager.preflightImportLayout(from: archive)
            XCTAssertEqual(preflight.candidates.count, 1)
            XCTAssertEqual(try manager.commitImport(preflight, selectedIDs: Set(preflight.candidates.map(\.id)), mode: .merge), 1)
            XCTAssertEqual(manager.photos.count, 2)
            XCTAssertTrue(manager.photos.allSatisfy { !$0.filename.isEmpty && $0.desktopCollage == nil })
        }
    }

    @MainActor
    func testWidgetExportDoesNotReadUnrelatedCollageFonts() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let photo = try XCTUnwrap(manager.photos.first)
            var unrelated = PhotoItem(filename: ""); unrelated.isVisible = false
            var settings = DesktopCollageSettings()
            settings.captionStyle.fontFileName = UUID().uuidString + ".ttf"
            unrelated.desktopCollage = settings
            manager.photos.append(unrelated)
            let archive = manager.storageDir.appendingPathComponent("one-photo.arras")
            XCTAssertNoThrow(try manager.exportWidget(photo.id, to: archive))
            let reader = try SimpleZipReader(data: Data(contentsOf: archive))
            XCTAssertNil(reader.entryData(named: "fonts/" + settings.captionStyle.fontFileName!))
        }
    }


    func testBatchResultSeparatesStatusesAndUsesOneSummaryFormat() {
        let result = ImportBatchResult(entries: [
            .init(source: "good.webp", status: .accepted),
            .init(source: "notes.txt", status: .skipped, reason: "Unsupported"),
            .init(source: "broken.bmp", status: .failed, reason: "Unreadable")
        ])

        XCTAssertEqual(result.acceptedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.summary(for: "image"), "Accepted 1 image. Skipped 1. Failed 1.")
        XCTAssertEqual(result.failed.first?.source, "broken.bmp")
        XCTAssertEqual(result.presentationMessage(for: "image"),
                       "Accepted 1 image. Skipped 1. Failed 1.\n\nbroken.bmp: Unreadable\nnotes.txt: Unsupported")
    }

    func testImportProblemsKeepFailuresVisibleAndBoundTheAlert() {
        let skips = (1...20).map { ImportBatchResult.Entry(source: "Extra \($0)", status: .skipped, reason: "Cache limit reached.") }
        let result = ImportBatchResult(entries: skips + [
            .init(source: "Album", status: .failed, reason: "Choose Relink Folder to restore access."),
            .init(source: "No detail", status: .failed, reason: "  \n")
        ])
        let lines = result.presentationMessage().components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Accepted 0 photos. Skipped 20. Failed 2.")
        XCTAssertEqual(lines[2], "Album: Choose Relink Folder to restore access.")
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.last, "Plus 18 more issues.")
        XCTAssertEqual(ImportBatchResult(entries: [.init(source: "good.png", status: .accepted)]).presentationMessage(), "Accepted 1 photo.")
    }

    @MainActor
    func testBrokenMediaImportExplainsFailureWithoutCreatingAWidget() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        let result = await manager.importPhotos(data: [Data("broken image".utf8)], sourceNames: ["Sample.png"])
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(manager.photos.isEmpty)
        XCTAssertTrue(manager.windows.isEmpty)
        let reason = try XCTUnwrap(result.failed.first?.reason)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(result.presentationMessage().contains("Sample.png: \(reason)"))
    }

    @MainActor
    func testWebPAndBMPAreAdvertisedAsImageInputs() {
        XCTAssertTrue(PhotoManager.importableTypes.contains { $0.conforms(to: .webP) })
        XCTAssertTrue(PhotoManager.importableTypes.contains { $0.conforms(to: .bmp) })
    }

    @MainActor
    func testMovieContainersAreAdvertisedSeparatelyAndUseTheUnifiedGate() {
        XCTAssertTrue(PhotoImportPolicy.videoTypes.contains { $0.conforms(to: .movie) })
        XCTAssertTrue(PhotoImportPolicy.isVideo(URL(fileURLWithPath: "/tmp/clip.mov")))
        XCTAssertTrue(PhotoImportPolicy.isVideo(URL(fileURLWithPath: "/tmp/clip.mp4")))
        XCTAssertTrue(PhotoImportPolicy.isVideo(URL(fileURLWithPath: "/tmp/clip.m4v")))
        XCTAssertTrue(PhotoImportPolicy.isImportable(URL(fileURLWithPath: "/tmp/clip.mp4")))
        XCTAssertFalse(PhotoImportPolicy.isVideo(URL(fileURLWithPath: "/tmp/clip.jpg")))
    }

    func testWebPAndBMPBytesSurvivePreparationAndRenderThroughImageIO() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let webP = try webPData()
        let bmp = try bmpData()

        for (data, name, ext) in [(webP, "sample.webp", "webp"), (bmp, "sample.bmp", "bmp")] {
            let prepared = try XCTUnwrap(PhotoIngest.prepare(data: data, in: directory, originalName: name))
            XCTAssertEqual(prepared.url.pathExtension, ext)
            XCTAssertNotNil(PhotoContent.load(from: prepared.url))
        }
    }

    @MainActor
    func testDataImportPreservesProvidedSourceName() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        defer {
            manager.windows.values.forEach { $0.hidePhoto() }
            manager.windows.removeAll()
        }

        let result = await manager.importPhotos(
            data: [try bmpData()],
            sourceNames: ["Family Holiday 2026.bmp"]
        )

        XCTAssertEqual(result.acceptedCount, 1)
        XCTAssertEqual(manager.photos.first?.customName, "Family Holiday 2026.bmp")
    }

    @MainActor
    func testWebPBMPreserveArchiveRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasArchiveImportTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let webP = try webPData()
        let bmp = try bmpData()
        let webPFile = try XCTUnwrap(PhotoIngest.prepare(data: webP, in: sourceDirectory, originalName: "webp"))
        let bmpFile = try XCTUnwrap(PhotoIngest.prepare(data: bmp, in: sourceDirectory, originalName: "bmp"))

        var first = PhotoItem(filename: webPFile.filename)
        first.isVisible = false
        var second = PhotoItem(filename: bmpFile.filename)
        second.isVisible = false

        let source = PhotoManager(storageDirectory: sourceDirectory)
        source.photos = [first, second]
        let archive = root.appendingPathComponent("images.arras")
        try source.exportLayout(to: archive)

        let target = PhotoManager(storageDirectory: targetDirectory)
        XCTAssertEqual(try target.importLayout(from: archive, mode: .merge), 2)
        XCTAssertEqual(target.photos.count, 2)
        XCTAssertEqual(
            Set(target.photos.map { ($0.filename as NSString).pathExtension }),
            Set(["webp", "bmp"])
        )
        XCTAssertTrue(target.photos.allSatisfy {
            PhotoContent.load(from: targetDirectory.appendingPathComponent($0.filename)) != nil
        })
    }

    func testArchiveRoutingAcceptsCurrentAndLegacyExtensionsCaseInsensitively() {
        XCTAssertTrue(BackupFormat.isArchiveURL(URL(fileURLWithPath: "/tmp/layout.ARRAS")))
        XCTAssertTrue(BackupFormat.isArchiveURL(URL(fileURLWithPath: "/tmp/layout.tableau")))
        XCTAssertFalse(BackupFormat.isArchiveURL(URL(fileURLWithPath: "/tmp/layout.zip")))
        XCTAssertTrue(BackupFormat.importTypes.contains { $0 == BackupFormat.layoutType })
    }

    func testArchiveQualityStatementDoesNotClaimUnavailableOriginals() {
        let metadata = ArchiveExportMetadata(
            scope: .widget,
            archivalQuality: true,
            media: [
                ArchiveMediaRecord(
                    filename: "legacy.jpg",
                    data: Data("stored bytes".utf8),
                    fidelity: .unknown
                )
            ],
            statement: ArchiveExportMetadata.statement(
                archivalQuality: true,
                sourceStatus: .provenanceUnavailable
            )
        )

        XCTAssertEqual(metadata.sourceStatus, .provenanceUnavailable)
        XCTAssertTrue(metadata.statement.contains("no original-quality claim"))
        XCTAssertFalse(metadata.statement.localizedCaseInsensitiveContains("original file included"))
    }

    @MainActor
    func testArchiveExportRejectsMediaReferencesOutsideStore() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: root.appendingPathComponent("outside.bmp"))
        let manager = PhotoManager(storageDirectory: storage)
        var item = PhotoItem(filename: "../outside.bmp")
        item.isVisible = false
        manager.photos = [item]

        XCTAssertThrowsError(try manager.exportLayout(to: root.appendingPathComponent("bad.arras"))) {
            XCTAssertEqual($0 as? LayoutArchiveError, .missingStoredMedia("../outside.bmp"))
        }
    }

    @MainActor
    func testPerWidgetExportIncludesAllSlideshowMediaAndPreflightDescribesIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let payload = try bmpData()
        let hero = "hero.bmp"
        let detail = "detail.webp"
        try payload.write(to: sourceDirectory.appendingPathComponent(hero))
        try payload.write(to: sourceDirectory.appendingPathComponent(detail))

        let source = PhotoManager(storageDirectory: sourceDirectory)
        var collage = PhotoItem(filename: "")
        collage.isVisible = false
        collage.customName = "Triptych"
        collage.spaceImageFilenames = [hero, detail]
        collage.mediaFidelity = [hero: .sourceBytes, detail: .transformed]
        source.photos = [collage]

        let archive = root.appendingPathComponent("triptych.arras")
        let report = try source.exportWidget(collage.id, to: archive, archivalQuality: true)
        XCTAssertEqual(report.scope, .widget)
        XCTAssertEqual(report.widgetCount, 1)
        XCTAssertEqual(report.mediaCount, 2)
        XCTAssertEqual(report.sourceStatus, .someTransformed)

        let target = PhotoManager(storageDirectory: targetDirectory)
        let preflight = try target.preflightImportLayout(from: archive)
        XCTAssertEqual(preflight.candidates.count, 1)
        XCTAssertEqual(preflight.candidates[0].typeName, "Space")
        XCTAssertEqual(preflight.candidates[0].displayName, "Triptych")
        XCTAssertEqual(preflight.candidates[0].mediaCount, 2)
        XCTAssertEqual(preflight.manifest.exportMetadata?.scope, .widget)
        preflight.cleanup()
    }

    @MainActor
    func testPreflightCommitCanSelectSubsetAndReplaceSafely() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let payload = try bmpData()
        try payload.write(to: sourceDirectory.appendingPathComponent("one.bmp"))
        try payload.write(to: sourceDirectory.appendingPathComponent("two.bmp"))
        let source = PhotoManager(storageDirectory: sourceDirectory)
        var first = PhotoItem(filename: "one.bmp")
        first.isVisible = false
        first.customName = "One"
        first.mediaFidelity["one.bmp"] = .sourceBytes
        var second = PhotoItem(filename: "two.bmp")
        second.isVisible = false
        second.customName = "Two"
        second.mediaFidelity["two.bmp"] = .sourceBytes
        source.photos = [first, second]

        let archive = root.appendingPathComponent("subset.arras")
        try source.exportLayout(to: archive, archivalQuality: true)

        let target = PhotoManager(storageDirectory: targetDirectory)
        var existing = PhotoItem(filename: "existing.bmp")
        existing.isVisible = false
        existing.customName = "Keep only until replace"
        target.photos = [existing]
        XCTAssertTrue(target.persist())

        let preflight = try target.preflightImportLayout(from: archive)
        XCTAssertEqual(preflight.candidates.count, 2)
        let selected = try XCTUnwrap(preflight.candidates.first)
        XCTAssertEqual(try target.commitImport(preflight, selectedIDs: [selected.id], mode: .replace), 1)
        XCTAssertEqual(target.photos.count, 1)
        XCTAssertEqual(target.photos.first?.customName, "One")
        XCTAssertNotEqual(target.photos.first?.id, first.id)
        XCTAssertTrue(target.photos.first?.filename.hasSuffix(".bmp") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preflight.stagingDirectory.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasArchiveFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func webPData() throws -> Data {
        try XCTUnwrap(Data(
            base64Encoded: "UklGRjgAAABXRUJQVlA4ICwAAACQAQCdASoCAAIAAgA0JaACdLoAA5gA/vmTb/+QH/+QH/+QH/8gP+IXeyAwAA=="
        ))
    }

    private func bmpData() throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        return try XCTUnwrap(bitmap?.representation(using: .bmp, properties: [:]))
    }
}
