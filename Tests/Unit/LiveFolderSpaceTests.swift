import AppKit
import XCTest
@testable import Arras

private final class FolderPreparationGate: @unchecked Sendable {
    let started: XCTestExpectation
    let finished: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var mainThread: Bool?

    init(started: XCTestExpectation, finished: XCTestExpectation) {
        self.started = started
        self.finished = finished
    }

    var ranOnMainThread: Bool? { lock.withLock { mainThread } }

    func prepare(_ url: URL, in directory: URL) -> PhotoIngest.Prepared? {
        lock.withLock { mainThread = Thread.isMainThread }
        started.fulfill()
        precondition(release.wait(timeout: .now() + 5) == .success, "Folder preparation fixture was not released")
        let prepared = PhotoIngest.prepare(contentsOf: url, in: directory)
        finished.fulfill()
        return prepared
    }

    func resume() { release.signal() }
}

final class LiveFolderSpaceTests: XCTestCase {
    @MainActor
    func testFolderRefreshPreservesActiveScenesAndLatestPlaybackChoice() async throws {
        for gesture in ["background", "resize", "unrelated", "cancel"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasFolderGesture-" + UUID().uuidString)
            let source = root.appendingPathComponent("source")
            let store = root.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try jpegData(color: .systemBlue).write(to: source.appendingPathComponent("first.jpg"))
            try jpegData(color: .systemOrange).write(to: source.appendingPathComponent("second.jpg"))
            let manager = PhotoManager(storageDirectory: store)
            defer {
                manager.stopAllLiveFolderWatchers()
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let added = await manager.addLiveFolderSpace(source, requiresSecurityScope: false)
            XCTAssertEqual(added.acceptedCount, 2)
            manager.stopAllLiveFolderWatchers()
            let index = try XCTUnwrap(manager.photos.firstIndex { $0.liveFolderSource != nil })
            let id = manager.photos[index].id
            manager.photos[index].rotationInterval = "click"
            if gesture != "unrelated" {
                manager.photos[index].collageParentID = parent.id
                manager.fitCollageModel(parent.id)
                manager.syncCollages(only: [parent.id])
            }
            manager.collageFlights.values.forEach { $0.currentProgress = 1 }
            XCTAssertTrue(manager.persist())
            let gate = FolderPreparationGate(started: expectation(description: "Folder refresh is preparing"),
                                             finished: expectation(description: "Folder file is prepared"))
            defer { gate.resume() }
            manager.prepareImportedURL = { url, directory in gate.prepare(url, in: directory) }
            try jpegData(color: .systemGreen).write(to: source.appendingPathComponent("third.jpg"))
            let filesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: store.path))
            var completed = false
            let pending = Task { @MainActor in
                let result = await manager.reconcileLiveFolder(id, folderURL: source, requiresSecurityScope: false)
                completed = true
                return result
            }
            defer { pending.cancel() }
            await fulfillment(of: [gate.started], timeout: 3)
            manager.nextFolderImage(id)
            XCTAssertEqual(manager.photos[index].folderImageIndex, 1)
            let selectedID = manager.photos[index].liveFolderEntries[1].sourceIdentifier
            manager.renamePhoto(id, to: "Edited while preparing")
            let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            if gesture == "resize" {
                XCTAssertNotNil(manager.beginCollageResize(parent.id))
                manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
            } else {
                manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 30, dy: 20), finished: false)
            }
            let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
            let preview = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                manager.windows[id].map { (id, $0.photoFrame) }
            })
            let view = try XCTUnwrap(manager.windows[id]?.contentView as? DraggablePhotoView)
            let image = try XCTUnwrap(view.photoLayer.image)
            let urls = manager.spaceImages[id]
            let stored = try Data(contentsOf: store.appendingPathComponent("photos.json"))
            gate.resume()
            await fulfillment(of: [gate.finished], timeout: 3)
            // Give the real asynchronous reconciliation time to reach its commit.
            // The assertion concerns ownership during an edit, not a speed target.
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(completed, gesture == "unrelated", gesture)
            XCTAssertTrue(manager.hasActiveArrangementInteraction, gesture)
            for (id, frame) in preview { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, gesture) }
            if gesture != "unrelated" {
                XCTAssertTrue(manager.hasPendingMediaImport)
                XCTAssertTrue(view.photoLayer.image === image)
                XCTAssertEqual(manager.spaceImages[id], urls)
                XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent("photos.json")), stored)
            }
            if gesture == "cancel" {
                pending.cancel()
                let result = await pending.value
                XCTAssertEqual(result.acceptedCount, 0)
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.path)), filesBefore)
                XCTAssertTrue(manager.hasActiveArrangementInteraction)
            } else {
                if gesture == "resize" {
                    manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: true)
                } else { manager.moveCollage(parent.id, to: surface.photoFrame, finished: true) }
                XCTAssertEqual(manager.arrangementUndo.count, 1)
                let finishedPlacement = manager.arrangementSnapshot(ids: ids)
                let result = await pending.value
                XCTAssertEqual(result.acceptedCount, 1)
                XCTAssertEqual(manager.photos[index].liveFolderEntries.count, 3)
                XCTAssertEqual(manager.photos[index].liveFolderEntries[manager.photos[index].folderImageIndex].sourceIdentifier, selectedID)
                XCTAssertEqual(manager.photos[index].customName, "Edited while preparing")
                XCTAssertEqual(manager.arrangementSnapshot(ids: ids), finishedPlacement,
                               "Adding another slide must preserve the completed scene geometry")
                XCTAssertTrue(view.photoLayer.image === image, "An unchanged displayed file must keep its native media")
                XCTAssertTrue(manager.undoArrangement(), gesture)
            }
            XCTAssertFalse(manager.hasPendingMediaImport)
        }
    }

    @MainActor
    func testChangedFolderFilesPrepareOffTheMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasFolderChanged-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("first.jpg")
        try jpegData(color: .systemBlue).write(to: file)
        let manager = PhotoManager(storageDirectory: store)
        defer {
            manager.stopAllLiveFolderWatchers()
            manager.rotationTimers.values.forEach { $0.cancel() }
            manager.windows.values.forEach { $0.hidePhoto() }
            manager.windows.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
        let added = await manager.addLiveFolderSpace(source, requiresSecurityScope: false)
        XCTAssertEqual(added.acceptedCount, 1)
        manager.stopAllLiveFolderWatchers()
        let original = try XCTUnwrap(manager.photos.first)
        let oldFilename = try XCTUnwrap(original.spaceImageFilenames.first)
        let oldBytes = try Data(contentsOf: store.appendingPathComponent(oldFilename))
        try jpegData(color: .systemPink).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let resourceIdentifier = try file.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let identity = resourceIdentifier.map { String(describing: $0) } ?? file.standardizedFileURL.path
        XCTAssertEqual(identity, original.liveFolderEntries[0].sourceIdentifier,
                       "This fixture must exercise changed bytes under the same source identity")
        let gate = FolderPreparationGate(started: expectation(description: "Changed file uses background preparation"),
                                         finished: expectation(description: "Changed file is prepared"))
        defer { gate.resume() }
        manager.prepareImportedURL = { url, directory in gate.prepare(url, in: directory) }
        let pending = Task { @MainActor in
            await manager.reconcileLiveFolder(original.id, folderURL: source, requiresSecurityScope: false)
        }
        defer { pending.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(gate.ranOnMainThread, false)
        gate.resume()
        await fulfillment(of: [gate.finished], timeout: 2)
        let result = await pending.value
        XCTAssertEqual(result.acceptedCount, 1)
        let replacement = try XCTUnwrap(manager.photos.first?.spaceImageFilenames.first)
        XCTAssertNotEqual(replacement, oldFilename)
        XCTAssertNotEqual(try Data(contentsOf: store.appendingPathComponent(replacement)), oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(oldFilename).path))
        XCTAssertFalse(manager.hasPendingMediaImport)
    }

    @MainActor
    func testFailedFolderStatusSavesKeepThePreviousSourceAndSnapshot() async throws {
        for failure in ["missing", "empty", "unreadable"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasFolderStatus-" + UUID().uuidString)
            let source = root.appendingPathComponent("source")
            let store = root.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let first = source.appendingPathComponent("first.jpg")
            try jpegData(color: .systemBlue).write(to: first)
            let manager = PhotoManager(storageDirectory: store)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
                manager.stopAllLiveFolderWatchers()
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            let added = await manager.addLiveFolderSpace(source, requiresSecurityScope: false)
            XCTAssertEqual(added.acceptedCount, 1)
            manager.stopAllLiveFolderWatchers()
            if failure == "unreadable" { manager.photos[0].liveFolderSource?.status = .empty }
            XCTAssertTrue(manager.persist())
            let original = try XCTUnwrap(manager.photos.first)
            let previous = try photoDictionary(original)
            let stored = try Data(contentsOf: store.appendingPathComponent("photos.json"))
            let media = try Data(contentsOf: store.appendingPathComponent(original.spaceImageFilenames[0]))
            try FileManager.default.removeItem(at: first)
            if failure == "missing" { try FileManager.default.removeItem(at: source) }
            if failure == "unreadable" { try Data("not an image".utf8).write(to: source.appendingPathComponent("broken.jpg")) }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
            _ = await manager.reconcileLiveFolder(original.id, folderURL: source, requiresSecurityScope: false)
            XCTAssertEqual(try photoDictionary(try XCTUnwrap(manager.photos.first)) as NSDictionary, previous as NSDictionary, failure)
            XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent("photos.json")), stored, failure)
            XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent(original.spaceImageFilenames[0])), media, failure)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
            _ = await manager.reconcileLiveFolder(original.id, folderURL: source, requiresSecurityScope: false)
            let expectedStatus: LiveFolderStatus = failure == "missing" ? .missing : failure == "empty" ? .empty : .active
            XCTAssertEqual(manager.photos.first?.liveFolderSource?.status, expectedStatus, failure)
            let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store.appendingPathComponent("photos.json")))
            XCTAssertEqual(saved.first?.liveFolderSource, manager.photos.first?.liveFolderSource, failure)
            XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent(original.spaceImageFilenames[0])), media, failure)
        }
    }

    @MainActor
    func testInitialLiveFolderSnapshotUsesManagedCopiesAndReconcilesChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasLiveFolderTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let store = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = source.appendingPathComponent("first.jpg")
        try jpegData(color: .systemBlue).write(to: first)
        let manager = PhotoManager(storageDirectory: store)
        defer {
            manager.stopAllLiveFolderWatchers()
            manager.rotationTimers.values.forEach { $0.cancel() }
            manager.windows.values.forEach { $0.hidePhoto() }
            manager.windows.removeAll()
        }
        let result = await manager.addLiveFolderSpace(source, requiresSecurityScope: false)

        XCTAssertEqual(result.acceptedCount, 1)
        let id = try XCTUnwrap(manager.photos.first?.id)
        let firstItem = try XCTUnwrap(manager.photos.first)
        XCTAssertEqual(firstItem.liveFolderEntries.count, 1)
        XCTAssertNotEqual(firstItem.spaceImageFilenames.first, first.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(firstItem.spaceImageFilenames[0]).path))

        let second = source.appendingPathComponent("second.jpg")
        try jpegData(color: .systemOrange).write(to: second)
        let refresh = await manager.reconcileLiveFolder(id, folderURL: source, requiresSecurityScope: false)

        XCTAssertEqual(refresh.acceptedCount, 1)
        XCTAssertEqual(manager.photos.first?.liveFolderEntries.count, 2)
    }

    func testReconciliationReusesManagedCopyWhenFinderRenamesAFile() {
        let existing = [
            LiveFolderEntry(
                sourceIdentifier: "volume-file-1",
                sourceName: "old-name.jpg",
                managedFilename: "managed-1.jpg",
                sourceByteCount: 10,
                sourceModificationDate: Date(timeIntervalSince1970: 1)
            )
        ]
        let candidates = [
            LiveFolderCandidate(
                sourceIdentifier: "volume-file-1",
                sourceName: "renamed.jpg",
                byteCount: 10,
                modificationDate: Date(timeIntervalSince1970: 1)
            ),
            LiveFolderCandidate(
                sourceIdentifier: "volume-file-2",
                sourceName: "new.jpg",
                byteCount: 12,
                modificationDate: Date(timeIntervalSince1970: 2)
            )
        ]

        let result = LiveFolderSpacePolicy.reconcile(
            existing: existing,
            candidates: candidates,
            currentSourceIdentifier: "volume-file-1"
        )

        XCTAssertEqual(result.retained.first?.managedFilename, "managed-1.jpg")
        XCTAssertEqual(result.retained.first?.sourceName, "renamed.jpg")
        XCTAssertEqual(result.added.map(\.sourceIdentifier), ["volume-file-2"])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.selectedSourceIdentifier, "volume-file-1")
    }

    func testReconciliationRemovesMissingSourceAndKeepsCurrentWhenBounded() {
        let existing = [
            LiveFolderEntry(sourceIdentifier: "gone", sourceName: "gone.jpg", managedFilename: "gone.jpg"),
            LiveFolderEntry(sourceIdentifier: "kept", sourceName: "kept.jpg", managedFilename: "kept.jpg")
        ]
        let candidates = [
            LiveFolderCandidate(sourceIdentifier: "kept", sourceName: "kept.jpg", byteCount: 1, modificationDate: nil),
            LiveFolderCandidate(sourceIdentifier: "added", sourceName: "added.jpg", byteCount: 1, modificationDate: nil)
        ]

        let result = LiveFolderSpacePolicy.reconcile(
            existing: existing,
            candidates: candidates,
            currentSourceIdentifier: "kept"
        )

        XCTAssertEqual(result.removed.map(\.sourceIdentifier), ["gone"])
        XCTAssertEqual(result.selectedSourceIdentifier, "kept")
    }

    func testFileAndByteCapsPrioritizeCurrentSource() {
        let candidates = (0..<(LiveFolderSpacePolicy.maxManagedFiles + 1)).map { index in
            LiveFolderCandidate(
                sourceIdentifier: "id-\(index)",
                sourceName: "image-\(index).jpg",
                byteCount: 1,
                modificationDate: nil
            )
        }

        let result = LiveFolderSpacePolicy.boundedCandidates(
            candidates,
            currentSourceIdentifier: "id-\(LiveFolderSpacePolicy.maxManagedFiles)"
        )

        XCTAssertEqual(result.selected.count, LiveFolderSpacePolicy.maxManagedFiles)
        XCTAssertTrue(result.selected.contains { $0.sourceIdentifier == "id-\(LiveFolderSpacePolicy.maxManagedFiles)" })
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testByteCapRejectsOversizedFirstCandidate() {
        let oversized = LiveFolderCandidate(
            sourceIdentifier: "oversized",
            sourceName: "oversized.jpg",
            byteCount: LiveFolderSpacePolicy.maxManagedBytes + 1,
            modificationDate: nil
        )
        let fitting = LiveFolderCandidate(
            sourceIdentifier: "fitting",
            sourceName: "fitting.jpg",
            byteCount: LiveFolderSpacePolicy.maxManagedBytes,
            modificationDate: nil
        )

        let result = LiveFolderSpacePolicy.boundedCandidates(
            [oversized, fitting],
            currentSourceIdentifier: nil
        )

        XCTAssertEqual(result.selected.map(\.sourceIdentifier), ["fitting"])
        XCTAssertEqual(result.skipped.map(\.sourceIdentifier), ["oversized"])
    }

    func testByteCapStillPreservesOversizedCurrentCandidate() {
        let oversized = LiveFolderCandidate(
            sourceIdentifier: "oversized",
            sourceName: "oversized.jpg",
            byteCount: LiveFolderSpacePolicy.maxManagedBytes + 1,
            modificationDate: nil
        )
        let fitting = LiveFolderCandidate(
            sourceIdentifier: "fitting",
            sourceName: "fitting.jpg",
            byteCount: 1,
            modificationDate: nil
        )

        let result = LiveFolderSpacePolicy.boundedCandidates(
            [oversized, fitting],
            currentSourceIdentifier: "oversized"
        )

        XCTAssertEqual(result.selected.map(\.sourceIdentifier), ["oversized"])
        XCTAssertEqual(result.skipped.map(\.sourceIdentifier), ["fitting"])
    }

    func testLiveFolderSourceRoundTripsAndArchiveSnapshotDropsMachineAccess() throws {
        let source = LiveFolderSource(
            bookmarkData: Data([1, 2, 3]),
            sourcePath: "/Volumes/Private Drive/Photos",
            displayName: "Photos",
            status: .active,
            lastKnownResourceIdentifier: "volume-file-1",
            lastReconciledAt: Date(timeIntervalSince1970: 10)
        )
        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(LiveFolderSource.self, from: encoded)
        XCTAssertEqual(decoded, source)

        let snapshot = source.archiveSnapshot
        XCTAssertNil(snapshot.bookmarkData)
        XCTAssertEqual(snapshot.sourcePath, "")
        XCTAssertNil(snapshot.lastKnownResourceIdentifier)
        XCTAssertEqual(snapshot.status, .needsRelink)
        XCTAssertEqual(snapshot.displayName, "Photos")
    }

    @MainActor
    func testArrasExportStripsLiveFolderEntryResourceIdentifiers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasLiveFolderArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let managedFilename = "managed.jpg"
        try jpegData(color: .systemBlue).write(to: root.appendingPathComponent(managedFilename))
        let manager = PhotoManager(storageDirectory: root)
        var item = PhotoItem(filename: "")
        item.isVisible = false
        item.spaceImageFilenames = [managedFilename]
        item.liveFolderSource = LiveFolderSource(
            sourcePath: "/Volumes/Camera/Photos",
            displayName: "Photos"
        )
        item.liveFolderEntries = [
            LiveFolderEntry(
                sourceIdentifier: "volume-resource-id",
                sourceName: "original.jpg",
                managedFilename: managedFilename
            )
        ]
        manager.photos = [item]

        let archive = root.appendingPathComponent("snapshot.arras")
        _ = try manager.exportLayout(to: archive)
        let manifest = try PhotoManager.inspect(archive)

        XCTAssertEqual(manifest.photos.first?.liveFolderSource?.sourcePath, "")
        XCTAssertEqual(manifest.photos.first?.liveFolderEntries.first?.sourceIdentifier, "")
        XCTAssertEqual(manifest.photos.first?.liveFolderEntries.first?.sourceName, "original.jpg")
    }

    private func jpegData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw CocoaError(.coderValueNotFound)
        }
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }
}
