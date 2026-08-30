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
        source.photos = [item]
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: sourceDirectory.appendingPathComponent(item.filename))

        let archive = root.appendingPathComponent("layout.arras")
        try source.exportLayout(to: archive)

        let target = PhotoManager(storageDirectory: targetDirectory)
        XCTAssertEqual(try target.importLayout(from: archive, mode: .merge), 1)
        XCTAssertEqual(target.photos.first?.customName, "Backup round trip")
        let importedName = try XCTUnwrap(target.photos.first?.filename)
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

        // Exporting a manifest whose referenced image is absent produces the same shape as
        // a truncated/damaged backup received from another Mac.
        let source = PhotoManager(storageDirectory: sourceDirectory)
        var missingItem = PhotoItem(filename: "missing.jpg")
        missingItem.isVisible = false
        source.photos = [missingItem]
        let archive = root.appendingPathComponent("damaged.arras")
        try source.exportLayout(to: archive)

        let target = PhotoManager(storageDirectory: targetDirectory)
        var currentItem = PhotoItem(filename: "current.jpg")
        currentItem.customName = "Keep me"
        currentItem.isVisible = false
        target.photos = [currentItem]
        target.persist()

        XCTAssertEqual(try target.importLayout(from: archive, mode: .replace), 0)
        XCTAssertEqual(target.photos.map(\.customName), ["Keep me"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
