import AppKit
import XCTest
@testable import Arras

final class PersistenceIntegrationTests: XCTestCase {
    @MainActor
    func testManagerPersistsAndReloadsLayoutInIsolatedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "integration.jpg", width: 360)
        item.customName = "Integration"
        item.isVisible = false
        item.frameString = "{{40, 60}, {360, 240}}"
        manager.photos = [item]
        manager.persist()

        let reloaded = PhotoManager(storageDirectory: directory)

        XCTAssertEqual(reloaded.photos.count, 1)
        XCTAssertEqual(reloaded.photos.first?.id, item.id)
        XCTAssertEqual(reloaded.photos.first?.customName, "Integration")
        XCTAssertEqual(reloaded.photos.first?.frameString, item.frameString)
        XCTAssertTrue(reloaded.windows.isEmpty)
    }

    @MainActor
    func testBackupRoundTripRestoresAnInvisibleWidgetAndItsImage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let source = PhotoManager(storageDirectory: sourceDirectory)
        var item = PhotoItem(filename: "source.jpg", width: 280)
        item.customName = "Backup round trip"
        item.isVisible = false
        item.stackOrder = 42
        item.matWidth = 18
        item.matColorHex = "#123456"
        item.shapeMask = PhotoShapeMask.arch.rawValue
        item.borderStyle = PhotoBorderStyle.dashed.rawValue
        item.borderGradientEnabled = true
        item.borderGradientColorHex = "#ABCDEF"
        item.tiltDegrees = -4
        item.stylePreset = StylePreset.modern.rawValue
        item.scheduleEnabled = true
        item.scheduleStartMinutes = 22 * 60
        item.scheduleEndMinutes = 6 * 60
        item.scheduleWeekdays = 0b010_1010
        item.displayIdentifier = "exporting-machine"
        item.savedDisplayFrames = ["exporting-machine": "{{1, 2}, {3, 4}}"]
        item.isHiddenForDisplay = true
        item.isHiddenForPresence = true
        source.photos = [item]
        try jpegData(for: testImage(size: NSSize(width: 280, height: 200), color: .systemBlue))
            .write(to: sourceDirectory.appendingPathComponent(item.filename))

        let archive = root.appendingPathComponent("layout.arras")
        try source.exportLayout(to: archive)

        let target = PhotoManager(storageDirectory: targetDirectory)
        XCTAssertEqual(try target.importLayout(from: archive, mode: .merge), 1)
        let imported = try XCTUnwrap(target.photos.first)
        XCTAssertEqual(imported.customName, "Backup round trip")
        XCTAssertEqual(imported.stackOrder, 42)
        XCTAssertEqual(imported.matWidth, 18)
        XCTAssertEqual(imported.matColorHex, "#123456")
        XCTAssertEqual(imported.shapeMask, PhotoShapeMask.arch.rawValue)
        XCTAssertEqual(imported.borderStyle, PhotoBorderStyle.dashed.rawValue)
        XCTAssertTrue(imported.borderGradientEnabled)
        XCTAssertEqual(imported.borderGradientColorHex, "#ABCDEF")
        XCTAssertEqual(imported.tiltDegrees, -4)
        XCTAssertEqual(imported.stylePreset, StylePreset.modern.rawValue)
        XCTAssertTrue(imported.scheduleEnabled)
        XCTAssertEqual(imported.scheduleStartMinutes, 22 * 60)
        XCTAssertEqual(imported.scheduleEndMinutes, 6 * 60)
        XCTAssertEqual(imported.scheduleWeekdays, 0b010_1010)
        XCTAssertNil(imported.displayIdentifier)
        XCTAssertTrue(imported.savedDisplayFrames.isEmpty)
        XCTAssertFalse(imported.isHiddenForDisplay)
        let importedName = imported.filename
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent(importedName).path))
    }

    @MainActor
    func testInvalidReplacementBackupDoesNotEraseCurrentLayout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        // Export a valid layout, then corrupt its stored payload without changing the ZIP
        // offsets. This models a truncated/damaged backup received from another Mac while
        // keeping export's own missing-media failure covered separately below.
        let source = PhotoManager(storageDirectory: sourceDirectory)
        var damagedItem = PhotoItem(filename: "damaged.jpg")
        damagedItem.isVisible = false
        source.photos = [damagedItem]
        let validPayload = try jpegData(for: testImage(size: NSSize(width: 240, height: 160), color: .systemOrange))
        try validPayload.write(to: sourceDirectory.appendingPathComponent(damagedItem.filename))
        let archive = root.appendingPathComponent("damaged.arras")
        try source.exportLayout(to: archive)
        var damagedArchive = try Data(contentsOf: archive)
        let payloadRange = try XCTUnwrap(damagedArchive.range(of: validPayload))
        damagedArchive.replaceSubrange(payloadRange, with: Data(repeating: 0, count: validPayload.count))
        try damagedArchive.write(to: archive, options: .atomic)

        let target = PhotoManager(storageDirectory: targetDirectory)
        var currentItem = PhotoItem(filename: "current.jpg")
        currentItem.customName = "Keep me"
        currentItem.isVisible = false
        target.photos = [currentItem]
        target.persist()

        XCTAssertEqual(try target.importLayout(from: archive, mode: .replace), 0)
        XCTAssertEqual(target.photos.map(\.customName), ["Keep me"])
    }

    @MainActor
    func testExportFailsWhenStoredMediaIsMissing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let source = PhotoManager(storageDirectory: sourceDirectory)
        var item = PhotoItem(filename: "missing.jpg")
        item.isVisible = false
        source.photos = [item]
        let archive = root.appendingPathComponent("incomplete.arras")

        XCTAssertThrowsError(try source.exportLayout(to: archive)) { error in
            XCTAssertEqual(error as? LayoutArchiveError, .missingStoredMedia("missing.jpg"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    @MainActor
    func testImportRollsBackWhenModelSaveFailsAndCleansStagedMedia() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let source = PhotoManager(storageDirectory: sourceDirectory)
        var sourceItem = PhotoItem(filename: "source.jpg")
        sourceItem.isVisible = false
        source.photos = [sourceItem]
        let payload = try jpegData(for: testImage(size: NSSize(width: 240, height: 160), color: .systemBlue))
        try payload.write(to: sourceDirectory.appendingPathComponent(sourceItem.filename))
        let archive = root.appendingPathComponent("layout.arras")
        try source.exportLayout(to: archive)

        let target = PhotoManager(storageDirectory: targetDirectory)
        var currentItem = PhotoItem(filename: "current.jpg")
        currentItem.customName = "Keep me"
        currentItem.isVisible = false
        target.photos = [currentItem]
        XCTAssertTrue(target.persist())

        // Make the on-disk predecessor unreadable after the manager has loaded it. The import
        // must leave the in-memory layout intact when its one model commit refuses this store.
        let corruptData = Data("not valid Arras JSON".utf8)
        try corruptData.write(to: targetDirectory.appendingPathComponent("photos.json"), options: .atomic)

        XCTAssertEqual(try target.importLayout(from: archive, mode: .replace), 0)
        XCTAssertEqual(target.photos.map(\.customName), ["Keep me"])
        XCTAssertTrue(target.persistenceFailures.contains(where: { $0.kind == .save }))

        // The staged imported image was never adopted by a durable model, so it must not be
        // left behind as an orphan in the target library.
        let targetFiles = try FileManager.default.contentsOfDirectory(
            at: targetDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertTrue(targetFiles.filter { $0.pathExtension.lowercased() == "jpg" }.isEmpty)
    }

    @MainActor
    func testSpaceReplacementPersistsCurrentSlotMigratesFrameAndKeepsSharedMediaAcrossRelaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldFilename = "shared.jpg"
        let otherFilename = "other.jpg"
        let oldImage = testImage(size: NSSize(width: 320, height: 180), color: .systemBlue)
        let oldData = try XCTUnwrap(oldImage.tiffRepresentation)
        try oldData.write(to: directory.appendingPathComponent(oldFilename))
        try oldData.write(to: directory.appendingPathComponent(otherFilename))

        let manager = PhotoManager(storageDirectory: directory)
        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = [oldFilename, otherFilename]
        space.folderImageIndex = 0
        space.folderSizeMode = "dynamic"
        let savedConfig = FolderImageConfig(
            frameString: "{{40, 60}, {420, 236.25}}",
            widgetWidth: 420
        )
        space.folderImageConfigs[oldFilename] = savedConfig

        // This second Space deliberately shares the old slot. The old stored file must remain
        // after replacing the first Space's current slot.
        var sharingSpace = PhotoItem(filename: "")
        sharingSpace.isVisible = false
        sharingSpace.spaceImageFilenames = [oldFilename]
        manager.photos = [space, sharingSpace]
        manager.persist()

        manager.replacePhoto(space.id, with: testImage(size: NSSize(width: 180, height: 320), color: .systemRed))

        let replaced = try XCTUnwrap(manager.photos.first(where: { $0.id == space.id }))
        let newFilename = try XCTUnwrap(replaced.spaceImageFilenames.first)
        XCTAssertNotEqual(newFilename, oldFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(newFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(oldFilename).path))
        let runtimeURL = try XCTUnwrap(manager.spaceImages[space.id]?[safe: 0])
        XCTAssertEqual(runtimeURL, directory.appendingPathComponent(newFilename))
        XCTAssertNil(replaced.folderImageConfigs[oldFilename])
        let migratedConfig = try XCTUnwrap(replaced.folderImageConfigs[newFilename])
        XCTAssertEqual(migratedConfig.frameString, savedConfig.frameString)
        XCTAssertEqual(migratedConfig.widgetWidth, savedConfig.widgetWidth)

        let reloaded = PhotoManager(storageDirectory: directory)
        let relaunchedSpace = try XCTUnwrap(reloaded.photos.first(where: { $0.id == space.id }))
        XCTAssertFalse(relaunchedSpace.isVisible)
        XCTAssertEqual(relaunchedSpace.spaceImageFilenames.first, newFilename)
        let relaunchedConfig = try XCTUnwrap(relaunchedSpace.folderImageConfigs[newFilename])
        XCTAssertEqual(relaunchedConfig.frameString, savedConfig.frameString)
        XCTAssertEqual(relaunchedConfig.widgetWidth, savedConfig.widgetWidth)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(newFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(oldFilename).path))
        XCTAssertTrue(reloaded.windows.isEmpty)
    }

    @MainActor
    func testSpaceReplacementKeepsMediaWhenTheSameFilenameAppearsInAnotherSlot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sharedFilename = "duplicate-slot.jpg"
        let imageData = try XCTUnwrap(testImage(size: NSSize(width: 320, height: 180), color: .systemBlue).tiffRepresentation)
        try imageData.write(to: directory.appendingPathComponent(sharedFilename))

        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = [sharedFilename, sharedFilename]
        space.folderImageIndex = 0
        let sharedConfig = FolderImageConfig(frameString: "{{20, 30}, {320, 180}}", widgetWidth: 320)
        space.folderImageConfigs[sharedFilename] = sharedConfig

        let manager = PhotoManager(storageDirectory: directory)
        manager.photos = [space]
        XCTAssertTrue(manager.persist())

        manager.replacePhoto(space.id, with: testImage(size: NSSize(width: 180, height: 320), color: .systemRed))

        let replaced = try XCTUnwrap(manager.photos.first)
        XCTAssertNotEqual(replaced.spaceImageFilenames[0], sharedFilename)
        XCTAssertEqual(replaced.spaceImageFilenames[1], sharedFilename)
        XCTAssertEqual(replaced.folderImageConfigs[sharedFilename]?.frameString, sharedConfig.frameString)
        XCTAssertEqual(replaced.folderImageConfigs[replaced.spaceImageFilenames[0]]?.widgetWidth, sharedConfig.widgetWidth)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(sharedFilename).path))
    }

    @MainActor
    func testReplacementMediaStaysUntilItsLastValidRevisionIsPruned() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalFilename = "revision-media.jpg"
        let imageData = try XCTUnwrap(testImage(size: NSSize(width: 320, height: 180), color: .systemBlue).tiffRepresentation)
        try imageData.write(to: directory.appendingPathComponent(originalFilename))

        var item = PhotoItem(filename: originalFilename)
        item.isVisible = false
        let manager = PhotoManager(storageDirectory: directory)
        manager.photos = [item]
        XCTAssertTrue(manager.persist())

        manager.replacePhoto(item.id, with: testImage(size: NSSize(width: 180, height: 320), color: .systemRed))
        let replacement = try XCTUnwrap(manager.photos.first?.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(originalFilename).path))

        // The replacement created a revision that still points to the original bytes. Push
        // enough newer valid revisions through the bounded trail to evict that predecessor.
        for index in 0...PhotoManager.maxPhotoStoreRevisions {
            var current = try XCTUnwrap(manager.photos.first)
            current.customName = "Revision \(index)"
            manager.photos = [current]
            XCTAssertTrue(manager.persist())
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(replacement).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(originalFilename).path))
    }

    @MainActor
    func testHiddenSpaceImageCountFallsBackToPersistedFilenames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var space = PhotoItem(filename: "")
        space.isVisible = false
        space.spaceImageFilenames = ["one.jpg", "two.jpg", "three.jpg"]

        let manager = PhotoManager(storageDirectory: directory)
        manager.photos = [space]

        XCTAssertTrue(manager.spaceImages[space.id] == nil)
        XCTAssertEqual(manager.folderImageCount(space.id), 3)
    }

    @MainActor
    func testPersistKeepsAValidBoundedRevisionTrail() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "revision.jpg")
        item.isVisible = false
        item.customName = "Revision 0"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())

        for index in 1..<(PhotoManager.maxPhotoStoreRevisions + 4) {
            item.customName = "Revision \(index)"
            manager.photos = [item]
            XCTAssertTrue(manager.persist())
        }

        let revisionDirectory = directory.appendingPathComponent("photos-revisions", isDirectory: true)
        let revisions = try FileManager.default.contentsOfDirectory(
            at: revisionDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(revisions.count, PhotoManager.maxPhotoStoreRevisions)

        for revision in revisions {
            let data = try Data(contentsOf: revision)
            XCTAssertNoThrow(try JSONDecoder().decode([PhotoItem].self, from: data))
        }
    }

    @MainActor
    func testSemanticNoOpWithReorderedDictionaryKeysDoesNotCreateRevision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "dictionary.jpg")
        item.isVisible = false
        item.folderImageConfigs = [
            "b.jpg": FolderImageConfig(frameString: "{{20, 20}, {200, 120}}", widgetWidth: 200),
            "a.jpg": FolderImageConfig(frameString: "{{10, 10}, {180, 100}}", widgetWidth: 180)
        ]
        manager.photos = [item]
        XCTAssertTrue(manager.persist())

        item.customName = "Changed"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())
        let revisionCount = manager.availableRevisions.count

        // Reinsert one dictionary entry to change its in-memory iteration order without
        // changing the semantic layout. sortedKeys should keep the encoded bytes identical.
        let aConfig = try XCTUnwrap(item.folderImageConfigs.removeValue(forKey: "a.jpg"))
        item.folderImageConfigs["a.jpg"] = aConfig
        manager.photos = [item]
        XCTAssertTrue(manager.persist())
        XCTAssertEqual(manager.availableRevisions.count, revisionCount)
    }

    @MainActor
    func testCorruptStoreIsPreservedAndRequiresExplicitRevisionRestore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var original = PhotoItem(filename: "revision.jpg")
        original.isVisible = false
        original.customName = "Original"
        manager.photos = [original]
        XCTAssertTrue(manager.persist())

        original.customName = "Changed"
        manager.photos = [original]
        XCTAssertTrue(manager.persist())

        let corruptData = Data("{ not valid Arras JSON".utf8)
        try corruptData.write(to: directory.appendingPathComponent("photos.json"), options: .atomic)

        let corrupted = PhotoManager(storageDirectory: directory)
        XCTAssertTrue(corrupted.photos.isEmpty)
        XCTAssertTrue(corrupted.isStoreLoadBlocked)
        XCTAssertEqual(corrupted.persistenceFailures.first(where: { $0.kind == .load })?.kind, .load)

        let corruptDirectory = directory.appendingPathComponent("photos-corrupt", isDirectory: true)
        let copies = try FileManager.default.contentsOfDirectory(
            at: corruptDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), corruptData)

        corrupted.photos = [PhotoItem(filename: "should-not-overwrite.jpg")]
        XCTAssertFalse(corrupted.persist())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), corruptData)

        XCTAssertTrue(corrupted.restoreLatestRevision())
        XCTAssertEqual(corrupted.photos.first?.customName, "Original")
        XCTAssertFalse(corrupted.isStoreLoadBlocked)
        XCTAssertFalse(corrupted.persistenceFailures.contains(where: { $0.kind == .load }))
    }

    @MainActor
    func testRevisionFailureLeavesLastKnownGoodStoreUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "revision.jpg")
        item.isVisible = false
        item.customName = "Original"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())
        let originalData = try Data(contentsOf: directory.appendingPathComponent("photos.json"))

        // A file at the revisions directory path makes the required predecessor write fail.
        // The new layout must not replace the only known-good photos.json in that case.
        let revisionsPath = directory.appendingPathComponent("photos-revisions")
        try Data("not a directory".utf8).write(to: revisionsPath)
        item.customName = "Should not win"
        manager.photos = [item]

        XCTAssertFalse(manager.persist())
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), originalData)
        XCTAssertEqual(
            try JSONDecoder().decode([PhotoItem].self, from: originalData).first?.customName,
            "Original"
        )
        XCTAssertTrue(manager.persistenceFailures.contains(where: { $0.kind == .save }))
        XCTAssertFalse(manager.isStoreLoadBlocked)
    }

    @MainActor
    func testRestoreAbortsWhenReadableCurrentStateCannotBecomeARevision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "revision.jpg")
        item.isVisible = false
        item.customName = "Original"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())

        item.customName = "Changed"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())
        let selected = try XCTUnwrap(manager.availableRevisions.first)
        let selectedData = try Data(contentsOf: selected.url)
        let externalRevisionURL = directory.appendingPathComponent("external-revision.json")
        try selectedData.write(to: externalRevisionURL)

        let currentURL = directory.appendingPathComponent("photos.json")
        let currentData = try Data(contentsOf: currentURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("photos-revisions"))
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("photos-revisions"))

        let externalRevision = PhotoStoreRevision(url: externalRevisionURL, createdAt: selected.createdAt)
        XCTAssertFalse(manager.restoreRevision(externalRevision))
        XCTAssertEqual(try Data(contentsOf: currentURL), currentData)
        XCTAssertEqual(manager.photos.first?.customName, "Changed")
        XCTAssertTrue(manager.persistenceFailures.contains(where: { $0.kind == .save }))
    }

    @MainActor
    func testRestoreAbortsWhenCorruptStoreCannotBePreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "revision.jpg")
        item.isVisible = false
        item.customName = "Original"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())

        item.customName = "Changed"
        manager.photos = [item]
        XCTAssertTrue(manager.persist())

        let corruptData = Data("{ not valid Arras JSON".utf8)
        let currentURL = directory.appendingPathComponent("photos.json")
        try corruptData.write(to: currentURL, options: .atomic)
        try Data("not a directory".utf8).write(to: directory.appendingPathComponent("photos-corrupt"))

        let corrupted = PhotoManager(storageDirectory: directory)
        XCTAssertTrue(corrupted.isStoreLoadBlocked)
        XCTAssertFalse(corrupted.restoreLatestRevision())
        XCTAssertEqual(try Data(contentsOf: currentURL), corruptData)
        XCTAssertTrue(corrupted.photos.isEmpty)
        XCTAssertTrue(corrupted.persistenceFailures.contains {
            $0.kind == .save && $0.detail.contains("could not be preserved")
        })
    }

    @MainActor
    func testSaveFailureIsReportedWithoutNeedingAWritableDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let notADirectory = root.appendingPathComponent("not-a-directory")
        try Data("sentinel".utf8).write(to: notADirectory)

        let manager = PhotoManager(storageDirectory: notADirectory)
        manager.photos = [PhotoItem(filename: "photo.jpg")]

        XCTAssertFalse(manager.persist())
        XCTAssertTrue(manager.persistenceFailures.contains(where: { $0.kind == .save }))
        XCTAssertFalse(manager.isStoreLoadBlocked)
    }

    @MainActor
    func testInvalidBatchMediaIsReportedInManagerState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        let added = await manager.addPhotos(data: [Data("not an image".utf8)])
        XCTAssertEqual(added, 0)
        XCTAssertTrue(manager.persistenceFailures.contains(where: { $0.kind == .mediaImport }))
        XCTAssertFalse(manager.isStoreLoadBlocked)
    }

    private func testImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func jpegData(for image: NSImage) throws -> Data {
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
