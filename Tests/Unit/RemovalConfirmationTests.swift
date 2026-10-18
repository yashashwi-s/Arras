import XCTest
@testable import Arras

final class RemovalConfirmationTests: XCTestCase {
    @MainActor
    func testSettingsConfirmationCanBeSkippedWithoutChangingStandardDefaults() throws {
        let suiteName = "ArrasRemovalConfirmationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(RemovalConfirmation.requiresConfirmation(origin: .settings, defaults: defaults))

        defaults.set(true, forKey: RemovalConfirmation.skipSettingsKey)

        XCTAssertFalse(RemovalConfirmation.requiresConfirmation(origin: .settings, defaults: defaults))
        XCTAssertTrue(RemovalConfirmation.requiresConfirmation(origin: .menuBar, defaults: defaults))
    }

    @MainActor
    func testMenuConfirmationCannotBeSkippedBySettingsPreference() throws {
        let suiteName = "ArrasRemovalMenuTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: RemovalConfirmation.skipSettingsKey)

        XCTAssertTrue(RemovalConfirmation.requiresConfirmation(origin: .menuBar, defaults: defaults))
    }

    @MainActor
    func testFailedBulkRemovalRollsBackPhotosSelectionAndLeavesMediaUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.jpg")
        let secondURL = directory.appendingPathComponent("second.jpg")
        try Data("first media".utf8).write(to: firstURL)
        try Data("second media".utf8).write(to: secondURL)

        var first = PhotoItem(filename: firstURL.lastPathComponent)
        first.isVisible = false
        var second = PhotoItem(filename: secondURL.lastPathComponent)
        second.isVisible = false

        let manager = PhotoManager(storageDirectory: directory)
        manager.photos = [first, second]
        manager.selectedPhotoIDs = [first.id, second.id]
        manager.selectionAnchorID = second.id
        XCTAssertTrue(manager.persist())

        // Damage the durable predecessor after the manager loaded it. persist() must refuse to
        // replace unreadable data, which exercises removePhotos' one-commit rollback path.
        let corruptStore = Data("{ invalid photos json".utf8)
        try corruptStore.write(to: directory.appendingPathComponent("photos.json"), options: .atomic)

        manager.removePhotos([first.id])

        XCTAssertEqual(manager.photos.map(\.id), [first.id, second.id])
        XCTAssertEqual(manager.selectedPhotoIDs, [first.id, second.id])
        XCTAssertEqual(manager.selectionAnchorID, second.id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("photos.json")), corruptStore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor
    func testSuccessfulSubsetRemovalRetainsRecoveryUntilExplicitDiscard() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sharedURL = directory.appendingPathComponent("shared.jpg")
        let uniqueURL = directory.appendingPathComponent("unique.jpg")
        try Data("shared media".utf8).write(to: sharedURL)
        try Data("unique media".utf8).write(to: uniqueURL)

        var removedSharing = PhotoItem(filename: sharedURL.lastPathComponent)
        removedSharing.isVisible = false
        var retainedSharing = PhotoItem(filename: sharedURL.lastPathComponent)
        retainedSharing.isVisible = false
        var removedUnique = PhotoItem(filename: uniqueURL.lastPathComponent)
        removedUnique.isVisible = false

        let manager = PhotoManager(storageDirectory: directory)
        manager.photos = [removedSharing, retainedSharing, removedUnique]
        manager.selectedPhotoIDs = [removedSharing.id, retainedSharing.id, removedUnique.id]
        manager.selectionAnchorID = removedUnique.id
        XCTAssertTrue(manager.persist())

        manager.removePhotos([removedSharing.id, removedUnique.id])

        XCTAssertEqual(manager.photos.map(\.id), [retainedSharing.id])
        XCTAssertEqual(manager.selectedPhotoIDs, [retainedSharing.id])
        XCTAssertEqual(manager.selectionAnchorID, retainedSharing.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uniqueURL.path))
        try manager.discardRemovedWidgets()
        XCTAssertFalse(FileManager.default.fileExists(atPath: uniqueURL.path))

        let reloaded = PhotoManager(storageDirectory: directory)
        XCTAssertEqual(reloaded.photos.map(\.id), [retainedSharing.id])
        XCTAssertEqual(reloaded.photos.first?.filename, sharedURL.lastPathComponent)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
