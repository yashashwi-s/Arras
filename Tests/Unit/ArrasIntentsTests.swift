import AppKit
import AppIntents
import XCTest
@testable import Arras

final class ArrasIntentsTests: XCTestCase {
    @MainActor
    private func withIntentLibrary(_ body: (PhotoManager) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasIntentTests-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: directory)
        let previous = AppDelegate.current
        let owner = AppDelegate(manager: manager)
        AppDelegate.current = owner
        defer {
            withExtendedLifetime(owner) {
                AppDelegate.current = previous
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try await body(manager)
    }

    @MainActor
    private func assertIntentFails(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("The failed operation must be reported to Shortcuts", file: file, line: line)
        } catch {
            XCTAssertTrue(error is ArrasIntentError, "\(error)", file: file, line: line)
        }
    }

    @MainActor
    func testAddPhotoReportsImportFailureAndPreservesAcceptedSourceBytes() async throws {
        try await withIntentLibrary { manager in
            let data = try StarterArtwork.pngData(for: StarterArtwork.image(for: .minimal, index: 0, phase: 0))
            var intent = AddPhotoIntent()
            intent.file = IntentFile(data: data, filename: "sample.png", type: .png)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
            await assertIntentFails { _ = try await intent.perform() }
            XCTAssertTrue(manager.photos.isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path)
            _ = try await intent.perform()
            let item = try XCTUnwrap(manager.photos.first)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename)), data)
            XCTAssertEqual(item.mediaFidelity[item.filename], .sourceBytes)
        }
    }

    @MainActor
    func testVisibilityAndOpacityReportSaveFailuresButAlreadySatisfiedRequestsSucceed() async throws {
        try await withIntentLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let id = try XCTUnwrap(manager.photos.first?.id)
            manager.renamePhoto(id, to: "Fixture")
            let manifest = manager.storageDir.appendingPathComponent("photos.json")
            let original = try Data(contentsOf: manifest)
            var show = ShowPhotoIntent(); show.name = "Fixture"
            var hide = HidePhotoIntent(); hide.name = "Fixture"
            var opacity = SetPhotoOpacityIntent(); opacity.name = "Fixture"; opacity.opacityPercent = 40
            let toggle = ToggleAllPhotosVisibilityIntent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
            await assertIntentFails { _ = try await show.perform() }
            await assertIntentFails { _ = try await opacity.perform() }
            await assertIntentFails { _ = try await toggle.perform() }
            _ = try await hide.perform()
            opacity.opacityPercent = 100
            _ = try await opacity.perform()
            XCTAssertEqual(try Data(contentsOf: manifest), original)
            XCTAssertFalse(try XCTUnwrap(manager.photos.first).isVisible)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path)
            _ = try await show.perform()
            XCTAssertTrue(try XCTUnwrap(manager.photos.first).isVisible)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
            await assertIntentFails { _ = try await hide.perform() }
            XCTAssertTrue(try XCTUnwrap(manager.photos.first).isVisible)
        }
    }

    @MainActor
    func testSlideshowIntentsRejectStillPhotosAndReportFailedAdvancesWithoutChangingSelection() async throws {
        try await withIntentLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            let photo = try XCTUnwrap(manager.photos.first)
            manager.renamePhoto(photo.id, to: "Still")
            var next = NextSpaceImageIntent(); next.name = "Still"
            var previous = PreviousSpaceImageIntent(); previous.name = "Still"
            await assertIntentFails { _ = try await next.perform() }
            await assertIntentFails { _ = try await previous.perform() }
            let url = manager.storageDir.appendingPathComponent(photo.filename)
            let imported = await manager.addSpace(urls: [url, url])
            XCTAssertEqual(imported.acceptedCount, 2)
            let space = try XCTUnwrap(manager.photos.last)
            manager.renamePhoto(space.id, to: "Space")
            next.name = "Space"; previous.name = "Space"
            let manifest = manager.storageDir.appendingPathComponent("photos.json")
            let saved = try Data(contentsOf: manifest)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
            await assertIntentFails { _ = try await next.perform() }
            await assertIntentFails { _ = try await previous.perform() }
            XCTAssertEqual(try Data(contentsOf: manifest), saved)
            XCTAssertEqual(manager.photos.last?.folderImageIndex, space.folderImageIndex)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path)
            _ = try await next.perform()
            XCTAssertEqual(manager.photos.last?.folderImageIndex, 1)
            _ = try await previous.perform()
            XCTAssertEqual(manager.photos.last?.folderImageIndex, 0)
            try FileManager.default.removeItem(at: manager.storageDir.appendingPathComponent(space.spaceImageFilenames[1]))
            await assertIntentFails { _ = try await next.perform() }
            XCTAssertEqual(manager.photos.last?.folderImageIndex, 0)
        }
    }
}
