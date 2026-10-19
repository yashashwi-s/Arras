import AppKit
import XCTest
@testable import Arras

final class SandboxMigrationTests: XCTestCase {
    private var root: URL!
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasSandboxMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func library(_ name: String, items: [PhotoItem]) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("photos.json"))
        return directory
    }

    func testCopiesCurrentSavedAndRemovedMediaWithoutTelemetryOrOldFolderGrants() throws {
        var current = PhotoItem(filename: "current.png")
        current.isVisible = false
        current.liveFolderSource = LiveFolderSource(bookmarkData: Data([1, 2]), sourcePath: "/Volumes/Old/Photos", displayName: "Linked photos")
        let saved = PhotoItem(filename: "saved.png")
        let removed = PhotoItem(filename: "removed.png")
        let source = try library("source", items: [current])
        var setups = DesktopSetupLibrary()
        setups.setups = [SavedDesktopSetup(name: "Saved arrangement", photos: [saved])]
        setups.previous = SavedDesktopSetup(name: "Previous", photos: [current])
        setups.removed = RemovedWidgets(photos: [removed], detachedChildren: [:])
        try setups.write(in: source)
        for name in ["current.png", "saved.png", "removed.png"] {
            try png.write(to: source.appendingPathComponent(name))
        }
        let telemetry = source.appendingPathComponent("Telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: telemetry, withIntermediateDirectories: true)
        try Data("old identifier".utf8).write(to: telemetry.appendingPathComponent("state.json"))
        let original = try Data(contentsOf: source.appendingPathComponent("photos.json"))

        let staging = try SandboxLibraryImport.prepare(from: source, stagingParent: root)
        let destination = try library("destination", items: [])
        try SandboxLibraryImport.commit(staging, to: destination)

        let imported = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: destination.appendingPathComponent("photos.json")))
        XCTAssertEqual(imported.map(\.id), [current.id])
        XCTAssertEqual(imported[0].liveFolderSource?.displayName, "Linked photos")
        XCTAssertEqual(imported[0].liveFolderSource?.status, .needsRelink)
        XCTAssertNil(imported[0].liveFolderSource?.bookmarkData)
        XCTAssertEqual(imported[0].liveFolderSource?.sourcePath, "")
        let importedSetups = try DesktopSetupLibrary.read(in: destination)
        XCTAssertEqual(importedSetups.setups[0].photos[0].id, saved.id)
        XCTAssertEqual(importedSetups.removed?.photos[0].id, removed.id)
        XCTAssertEqual(importedSetups.previous?.photos[0].liveFolderSource?.status, .needsRelink)
        for name in ["current.png", "saved.png", "removed.png"] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), png)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Telemetry").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("photos.json")), original)
    }

    func testCopiesReferencedFontsAndRejectsInvalidFontData() throws {
        let fontName = UUID().uuidString + ".ttf"
        var collage = PhotoItem(filename: "")
        var settings = DesktopCollageSettings()
        settings.caption = "A saved label"
        settings.captionStyle.font = .custom
        settings.captionStyle.fontName = "Georgia"
        settings.captionStyle.fontFileName = fontName
        collage.desktopCollage = settings
        let source = try library("source", items: [collage])
        let fonts = CollageFontLibrary.directory(in: source)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let font = fonts.appendingPathComponent(fontName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia.ttf"), to: font)
        let staging = try SandboxLibraryImport.prepare(from: source, stagingParent: root)
        XCTAssertEqual(try Data(contentsOf: CollageFontLibrary.directory(in: staging).appendingPathComponent(fontName)),
                       try Data(contentsOf: font))
        try Data("invalid font".utf8).write(to: font)
        XCTAssertThrowsError(try SandboxLibraryImport.prepare(from: source, stagingParent: root))
    }

    func testCorruptMediaIsRejectedBeforeInstallingTheLibrary() throws {
        let source = try library("source", items: [PhotoItem(filename: "broken.png")])
        try Data("invalid media".utf8).write(to: source.appendingPathComponent("broken.png"))
        XCTAssertThrowsError(try SandboxLibraryImport.prepare(from: source, stagingParent: root))
    }

    func testMissingMediaCannotReplaceAnExistingEmptyLibrary() throws {
        let source = try library("source", items: [PhotoItem(filename: "missing.png")])
        let destination = try library("destination", items: [])
        let original = try Data(contentsOf: destination.appendingPathComponent("photos.json"))
        XCTAssertThrowsError(try SandboxLibraryImport.prepare(from: source, stagingParent: root))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photos.json")), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("ArrasLibraryImport-") })
    }

    func testRejectsTraversalAndSymlinksOutsideTheSelectedLibrary() throws {
        let outside = root.appendingPathComponent("private.png")
        try Data("outside".utf8).write(to: outside)
        let traversal = try library("traversal", items: [PhotoItem(filename: "../private.png")])
        XCTAssertThrowsError(try SandboxLibraryImport.prepare(from: traversal, stagingParent: root))
        let symlink = try library("symlink", items: [PhotoItem(filename: "linked.png")])
        try FileManager.default.createSymbolicLink(at: symlink.appendingPathComponent("linked.png"), withDestinationURL: outside)
        XCTAssertThrowsError(try SandboxLibraryImport.prepare(from: symlink, stagingParent: root))
    }

    func testRejectsSymlinkedSetupManifest() throws {
        let source = try library("source", items: [])
        let outside = root.appendingPathComponent("outside-setups.json")
        try JSONEncoder().encode(DesktopSetupLibrary()).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("setups.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try SandboxLibraryImport.prepare(from: source, stagingParent: root))
    }

    func testRefusesToOverwriteCurrentPhotosSavedSetupsOrCorruptStores() throws {
        let source = try library("source", items: [])
        let staging = try SandboxLibraryImport.prepare(from: source, stagingParent: root)
        let occupied = try library("occupied", items: [PhotoItem(filename: "existing.png")])
        XCTAssertThrowsError(try SandboxLibraryImport.commit(staging, to: occupied))
        let savedOnly = try library("savedOnly", items: [])
        var setups = DesktopSetupLibrary()
        setups.setups = [SavedDesktopSetup(name: "Keep me", photos: [])]
        try setups.write(in: savedOnly)
        XCTAssertThrowsError(try SandboxLibraryImport.commit(staging, to: savedOnly))
        let corrupt = try library("corrupt", items: [])
        try Data("damaged".utf8).write(to: corrupt.appendingPathComponent("photos.json"))
        XCTAssertThrowsError(try SandboxLibraryImport.commit(staging, to: corrupt))
    }

    func testMissingPreparedLibraryDoesNotMoveTheDestination() throws {
        let destination = try library("destination", items: [])
        let original = try Data(contentsOf: destination.appendingPathComponent("photos.json"))
        XCTAssertThrowsError(try SandboxLibraryImport.commit(root.appendingPathComponent("missing"), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photos.json")), original)
    }

    func testFailedInstallationRestoresTheOriginalEmptyLibraryAndUnreferencedFiles() throws {
        let source = try library("source", items: [])
        let staging = try SandboxLibraryImport.prepare(from: source, stagingParent: root)
        let destination = try library("destination", items: [])
        let orphan = destination.appendingPathComponent("unreferenced.txt")
        try Data("keep this".utf8).write(to: orphan)
        let original = try Data(contentsOf: destination.appendingPathComponent("photos.json"))
        XCTAssertThrowsError(try SandboxLibraryImport.commit(staging, to: destination) { from, to in
            if from == staging {
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: to.appendingPathComponent("partial.txt"))
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try FileManager.default.moveItem(at: from, to: to)
        })
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photos.json")), original)
        XCTAssertEqual(try Data(contentsOf: orphan), Data("keep this".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("partial.txt").path))
    }

    @MainActor
    func testManagerInstallsValidatedMediaAndReloadsDurableModels() async throws {
        var photo = PhotoItem(filename: "source.png")
        photo.isVisible = false
        let source = try library("source", items: [photo])
        try png.write(to: source.appendingPathComponent("source.png"))
        let manager = PhotoManager(storageDirectory: root.appendingPathComponent("destination"))
        XCTAssertTrue(manager.canImportExistingLibrary)
        try await manager.importExistingLibrary(from: source)
        XCTAssertEqual(manager.photos.map(\.id), [photo.id])
        XCTAssertFalse(manager.hasPendingMediaImport)
        XCTAssertFalse(manager.canImportExistingLibrary)
        XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("source.png")), png)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("source.png")), png)
        let restored = PhotoManager(storageDirectory: manager.storageDir)
        XCTAssertEqual(restored.photos.map(\.id), [photo.id])
    }

    @MainActor
    func testDeferredNativeTabSelectionKeepsTheLatestRequestAndHonorsUpdateNavigation() async {
        let navigation = SettingsNavigation()
        navigation.selectFromTabControl(.preferences)
        navigation.selectFromTabControl(.privacy)
        XCTAssertEqual(navigation.selection, .photos)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(navigation.selection, .privacy)
        navigation.selectFromTabControl(.photos)
        navigation.showUpdates()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(navigation.selection, .preferences)
        XCTAssertNotNil(navigation.updatesRequest)
    }

    @MainActor
    func testAppStoreActionUsesTheStoreAndRecoversWhenItCannotOpen() {
        var opened: [URL] = []
        var recoveries = 0
        AppStoreUpdates.checkForUpdates(open: { opened.append($0); return true }, recover: { recoveries += 1 })
        XCTAssertEqual(opened.map(\.absoluteString), ["macappstore://showUpdatesPage"])
        XCTAssertEqual(recoveries, 0)
        AppStoreUpdates.checkForUpdates(open: { _ in false }, recover: { recoveries += 1 })
        XCTAssertEqual(recoveries, 1)
    }

    func testScreenRegionCoordinatesForRetinaAndOffsetDisplays() {
        XCTAssertEqual(ScreenCaptureRegion.sourceRect(selection: CGRect(x: 200, y: 300, width: 400, height: 250),
                                                      screen: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                       CGRect(x: 200, y: 350, width: 400, height: 250))
        XCTAssertEqual(ScreenCaptureRegion.sourceRect(selection: CGRect(x: -1500, y: 700, width: 300, height: 200),
                                                      screen: CGRect(x: -1920, y: 300, width: 1920, height: 1080)),
                       CGRect(x: 420, y: 480, width: 300, height: 200))
    }

    func testScreenRegionClipsToOneDisplayAndRejectsEmptyOrTinySelections() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(ScreenCaptureRegion.sourceRect(selection: CGRect(x: -20, y: -30, width: 120, height: 130), screen: screen),
                       CGRect(x: 0, y: 800, width: 100, height: 100))
        XCTAssertNil(ScreenCaptureRegion.sourceRect(selection: .zero, screen: screen))
        XCTAssertNil(ScreenCaptureRegion.sourceRect(selection: CGRect(x: 0, y: 0, width: 1, height: 40), screen: screen))
        XCTAssertNil(ScreenCaptureRegion.sourceRect(selection: CGRect(x: 2000, y: 0, width: 40, height: 40), screen: screen))
    }
}
