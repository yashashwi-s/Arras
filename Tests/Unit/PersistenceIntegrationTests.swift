import AppKit
import XCTest
@testable import Arras

final class PersistenceIntegrationTests: XCTestCase {
    @MainActor
    func testFailedRenameCannotLeakAnUnsavedNameIntoASavedSetup() throws {
        for collage in [false, true] {
            for requestedName in ["Unsaved name", ""] {
                try withTestLibrary { manager in
                    let id: UUID
                    if collage { id = try XCTUnwrap(manager.addDesktopCollage()) }
                    else {
                        XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
                        id = try XCTUnwrap(manager.photos.first?.id)
                    }
                    manager.renamePhoto(id, to: "Saved sample name")
                    let original = try XCTUnwrap(manager.photos.first { $0.id == id })
                    let storedURL = manager.storageDir.appendingPathComponent("photos.json")
                    let stored = try Data(contentsOf: storedURL)
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }

                    manager.renamePhoto(id, to: requestedName)

                    let actual = try XCTUnwrap(manager.photos.first { $0.id == id })
                    XCTAssertEqual(manager.label(for: actual), "Saved sample name")
                    XCTAssertEqual(try photoDictionary(actual) as NSDictionary, try photoDictionary(original) as NSDictionary)
                    XCTAssertEqual(try Data(contentsOf: storedURL), stored)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path)
                    let setupID = try manager.saveDesktopSetup(named: "After refused rename")
                    let setup = try XCTUnwrap(try DesktopSetupLibrary.read(in: manager.storageDir).setups.first { $0.id == setupID })
                    XCTAssertEqual(setup.photos.first { $0.id == id }?.customName, original.customName,
                                   "A later setup must capture the durable name, not the refused rename")

                    manager.renamePhoto(id, to: requestedName)
                    let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: storedURL))
                    XCTAssertEqual(saved.first { $0.id == id }?.customName, requestedName.isEmpty ? nil : requestedName)
                }
            }
        }
    }

    @MainActor
    func testRetiredContainersLoadAsStandalonePhotosWithoutLosingTheirMedia() throws {
        try withTestLibrary { manager in
            for material in ["bubble", "polaroid"] {
                var container = PhotoItem(filename: ""); container.isVisible = false
                var child = PhotoItem(filename: "saved.png"); child.isVisible = false
                child.frameString = "{{120, 140}, {280, 190}}"; child.stylePreset = "print"
                var oldContainer = try photoDictionary(container)
                oldContainer["composition"] = ["material": material, "caption": "Old container"]
                var oldChild = try photoDictionary(child)
                oldChild["compositionParentID"] = container.id.uuidString
                oldChild["compositionPinned"] = true
                let data = try JSONSerialization.data(withJSONObject: [oldContainer, oldChild])
                try data.write(to: manager.storageDir.appendingPathComponent("photos.json"))
                let loaded = PhotoManager(storageDirectory: manager.storageDir)
                XCTAssertEqual(loaded.photos.map(\.id), [child.id])
                XCTAssertEqual(loaded.photos[0].filename, child.filename)
                XCTAssertEqual(loaded.photos[0].frameString, child.frameString)
                XCTAssertEqual(loaded.photos[0].stylePreset, child.stylePreset)
                XCTAssertTrue(loaded.persist())
                let saved = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                let text = String(decoding: saved, as: UTF8.self)
                XCTAssertFalse(text.contains("compositionParentID"))
                XCTAssertFalse(text.contains("compositionPinned"))
                XCTAssertFalse(text.contains("\"composition\""))
            }
        }
    }

    @MainActor
    func testMixedOldAndNewLibraryPreservesCollageModelsAndStandaloneMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasRecovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        let legacy = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":"31E63F72-9039-41B6-B6A2-09BC231A835A","filename":"old.png","frameString":"{{10,20},{300,200}}","widgetWidth":300,"isLocked":false,"isVisible":false}"#.utf8))
        var group = PhotoItem(filename: ""); group.isVisible = false
        var settings = DesktopCollageSettings(); settings.caption = "Saved caption"
        settings.labels = [CollageTextLabel(text: "Saved label")]
        group.desktopCollage = settings
        var child = PhotoItem(filename: "child.png"); child.isVisible = false; child.collageParentID = group.id
        child.media = PhotoMedia(kind: .video, posterFilename: "poster.png", isMuted: true)
        child.clickAction = .quickLook; child.revealOnHover = true
        manager.photos = [legacy, group, child]
        XCTAssertTrue(manager.persist())
        let loaded = PhotoManager(storageDirectory: directory)
        XCTAssertEqual(loaded.photos.count, 3)
        XCTAssertEqual(loaded.photos[1].desktopCollage, settings)
        XCTAssertEqual(loaded.photos[2].collageParentID, group.id)
        XCTAssertEqual(loaded.photos[2].media, child.media)
        XCTAssertEqual(loaded.photos[2].clickAction, .quickLook)
        XCTAssertTrue(loaded.photos[2].revealOnHover)
        XCTAssertNil(loaded.photos[0].desktopCollage)
        XCTAssertTrue(loaded.windows.isEmpty)
    }

    @MainActor
    func testOffscreenCollageRestorationTranslatesChildrenAndSlideshowFramesTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasRecoveryDisplay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var parent = PhotoItem(filename: ""); parent.desktopCollage = DesktopCollageSettings(); parent.isVisible = false
        let original = CGRect(x: 100000, y: 100000, width: 500, height: 400)
        parent.frameString = NSStringFromRect(original)
        var child = PhotoItem(filename: "child.png"); child.collageParentID = parent.id; child.isVisible = false
        let childFrame = original.offsetBy(dx: 30, dy: 50)
        child.frameString = NSStringFromRect(childFrame)
        child.folderImageConfigs["child.png"] = FolderImageConfig(frameString: child.frameString, widgetWidth: child.widgetWidth)
        manager.photos = [parent, child]; XCTAssertTrue(manager.persist())
        let loaded = PhotoManager(storageDirectory: directory)
        let restored = NSRectFromString(loaded.photos[0].frameString)
        XCTAssertNotEqual(restored.origin, original.origin)
        let expected = childFrame.offsetBy(dx: restored.minX - original.minX, dy: restored.minY - original.minY)
        XCTAssertEqual(NSRectFromString(loaded.photos[1].frameString), expected)
        XCTAssertEqual(NSRectFromString(loaded.photos[1].folderImageConfigs["child.png"]!.frameString), expected)
    }


    @MainActor
    func testDuplicateIDsAreRejectedWithoutOverwritingTheLayout() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "duplicate.jpg")
        item.isVisible = false
        manager.photos = [item]
        XCTAssertTrue(manager.persist())
        let file = directory.appendingPathComponent("photos.json")
        let original = try Data(contentsOf: file)
        manager.photos.append(item)
        XCTAssertFalse(manager.persist())
        XCTAssertEqual(try Data(contentsOf: file), original)

        let damaged = try JSONEncoder().encode([item, item])
        try damaged.write(to: file, options: .atomic)
        let reloaded = PhotoManager(storageDirectory: directory)
        XCTAssertTrue(reloaded.photos.isEmpty)
        XCTAssertTrue(reloaded.windows.isEmpty)
        XCTAssertFalse(reloaded.persist())
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    @MainActor
    func testStorageResolutionIsolatesUITestingWithoutChangingExplicitOrNormalStorage() {
        let temporary = URL(fileURLWithPath: "/tmp/ArrasStoragePolicy", isDirectory: true)
        let explicit = temporary.appendingPathComponent("explicit", isDirectory: true)
        let configured = temporary.appendingPathComponent("configured", isDirectory: true)
        for unitTesting in [false, true] {
            for uiTesting in [false, true] {
                for path: String? in [nil, "", configured.path] {
                    let actual = PhotoManager.resolveStorageDirectory(explicitDirectory: nil, uiTestPath: path,
                        unitTesting: unitTesting, uiTesting: uiTesting,
                        temporaryDirectory: temporary, processIdentifier: 1234)
                    if path == configured.path { XCTAssertEqual(actual, configured) }
                    else if unitTesting {
                        XCTAssertEqual(actual, temporary.appendingPathComponent("ArrasUnitHost-1234", isDirectory: true))
                    } else if uiTesting {
                        XCTAssertEqual(actual, temporary.appendingPathComponent("ArrasUITestHost-1234", isDirectory: true),
                                       "A missing/empty UI-test path must never select the personal library")
                    } else { XCTAssertNil(actual, "Normal launches retain the historical storage location") }
                    XCTAssertEqual(PhotoManager.resolveStorageDirectory(explicitDirectory: explicit, uiTestPath: path,
                        unitTesting: unitTesting, uiTesting: uiTesting,
                        temporaryDirectory: temporary, processIdentifier: 1234), explicit)
                }
            }
        }
    }

    @MainActor
    func testUnitHostUsesTemporaryStorageAndExplicitManagersKeepTheirDirectory() throws {
        XCTAssertTrue(PhotoManager.isUnitTestHost, "The test scheme must isolate the app host")
        let host = PhotoManager()
        XCTAssertTrue(host.storageDir.lastPathComponent.hasPrefix("ArrasUnitHost-"))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let explicit = PhotoManager(storageDirectory: directory)
        XCTAssertEqual(explicit.storageDir, directory)
    }

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
        XCTAssertTrue(manager.persist())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("photos-revisions", isDirectory: true).path
            )
        )

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
        item.revealOnHover = true
        item.matWidth = 18
        item.matColorHex = "#123456"
        item.shapeMask = PhotoShapeMask.arch.rawValue
        item.borderStyle = PhotoBorderStyle.dashed.rawValue
        item.borderGradientEnabled = true
        item.borderGradientColorHex = "#ABCDEF"
        item.tiltDegrees = -4
        item.stylePreset = StylePreset.modern.rawValue
        item.focalPoint = NormalizedFocalPoint(x: 0.12, y: 0.88)
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
        XCTAssertTrue(imported.revealOnHover)
        XCTAssertEqual(imported.matWidth, 18)
        XCTAssertEqual(imported.matColorHex, "#123456")
        XCTAssertEqual(imported.shapeMask, PhotoShapeMask.arch.rawValue)
        XCTAssertEqual(imported.borderStyle, PhotoBorderStyle.dashed.rawValue)
        XCTAssertTrue(imported.borderGradientEnabled)
        XCTAssertEqual(imported.borderGradientColorHex, "#ABCDEF")
        XCTAssertEqual(imported.tiltDegrees, -4)
        XCTAssertEqual(imported.stylePreset, StylePreset.modern.rawValue)
        XCTAssertEqual(imported.focalPoint, item.focalPoint)
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

        XCTAssertThrowsError(try target.importLayout(from: archive, mode: .replace))
        XCTAssertEqual(target.photos.map(\.customName), ["Keep me"])

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
    func testBackupRecoveryRequiresExplicitModeAndPreservesLatestDamagedBytesAndMedia() throws {
        try withTestLibrary { source in
            XCTAssertTrue(source.addStarterExample(.minimal, makeVisible: false))
            let archive = source.storageDir.appendingPathComponent("recovery.arras")
            try source.exportLayout(to: archive)
            try withTestLibrary { target in
                XCTAssertTrue(target.addStarterExample(.minimal, makeVisible: false))
                let originalMedia = target.photos.flatMap { target.storedFilenames(in: $0) }
                let manifest = target.storageDir.appendingPathComponent("photos.json")
                try Data("damaged at startup".utf8).write(to: manifest)
                target.loadSaved()
                XCTAssertTrue(target.libraryRecoveryRequired)
                for mode in [PhotoManager.LayoutImportMode.merge, .replace] {
                    XCTAssertThrowsError(try target.importLayout(from: archive, mode: mode))
                    XCTAssertEqual(try Data(contentsOf: manifest), Data("damaged at startup".utf8))
                    XCTAssertTrue(target.libraryRecoveryRequired)
                }
                let latest = Data("damaged again before recovery commits".utf8)
                try latest.write(to: manifest)
                XCTAssertGreaterThan(try target.importLayout(from: archive, mode: .recoverDamagedLibrary), 0)
                XCTAssertFalse(target.libraryRecoveryRequired)
                let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: manifest))
                XCTAssertEqual(saved.map(\.id), target.photos.map(\.id))
                let copies = try FileManager.default.contentsOfDirectory(
                    at: target.storageDir.appendingPathComponent("photos-corrupt"), includingPropertiesForKeys: nil)
                XCTAssertTrue(try copies.contains { try Data(contentsOf: $0) == latest })
                for name in originalMedia {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: target.storageDir.appendingPathComponent(name).path))
                }
                XCTAssertTrue(target.persist())
            }
        }
    }

    @MainActor
    func testRecoveryFailurePreservesBlockedStateAndDoesNotOverwriteARepairedLibrary() throws {
        try withTestLibrary { source in
            XCTAssertTrue(source.addStarterExample(.minimal, makeVisible: false))
            let archive = source.storageDir.appendingPathComponent("recovery.arras")
            try source.exportLayout(to: archive)
            try withTestLibrary { target in
                let manifest = target.storageDir.appendingPathComponent("photos.json")
                let damaged = Data("damaged".utf8)
                try damaged.write(to: manifest)
                target.loadSaved()
                let copies = target.storageDir.appendingPathComponent("photos-corrupt")
                try FileManager.default.removeItem(at: copies)
                try Data("block preservation".utf8).write(to: copies)
                XCTAssertThrowsError(try target.importLayout(from: archive, mode: .recoverDamagedLibrary))
                XCTAssertEqual(try Data(contentsOf: manifest), damaged)
                XCTAssertTrue(target.libraryRecoveryRequired)
                XCTAssertTrue(target.photos.isEmpty)
                try FileManager.default.removeItem(at: copies)
                let repaired = try JSONEncoder().encode([PhotoItem]())
                try repaired.write(to: manifest)
                XCTAssertThrowsError(try target.importLayout(from: archive, mode: .recoverDamagedLibrary))
                XCTAssertEqual(try Data(contentsOf: manifest), repaired)
                XCTAssertTrue(target.libraryRecoveryRequired)
                target.loadSaved()
                XCTAssertFalse(target.libraryRecoveryRequired)
            }
        }
    }

    @MainActor
    func testCorruptStoreIsPreservedWithoutOverwritingIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = PhotoManager(storageDirectory: directory)
        var original = PhotoItem(filename: "original.jpg")
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
        XCTAssertTrue(corrupted.libraryRecoveryRequired)

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
    }

    @MainActor
    func testSaveFailsWhenStoragePathIsNotDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let notADirectory = root.appendingPathComponent("not-a-directory")
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: notADirectory)

        let manager = PhotoManager(storageDirectory: notADirectory)
        manager.photos = [PhotoItem(filename: "photo.jpg")]

        XCTAssertFalse(manager.persist())
        XCTAssertEqual(try Data(contentsOf: notADirectory), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notADirectory.appendingPathComponent("photos.json").path))
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
