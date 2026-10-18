import Foundation
import AppKit
import Photos
import XCTest
@testable import Arras

final class PhotosLibraryCollectionTests: XCTestCase {
    @MainActor
    func testUnchangedPhotosRefreshKeepsNativeMediaAndCompletedArrangementHistory() throws {
        for gesture in ["none", "background", "resize"] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.galleryWall))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == child.id })
                manager.photos[index].photosLibrarySource = PhotosLibrarySource(
                    localIdentifier: "fixture-album", collectionType: .userAlbum, displayName: "Sample album")
                manager.photos[index].photosLibraryAssets = [PhotosLibraryAsset(
                    localIdentifier: "fixture-asset", displayName: "Sample photo", managedFilename: child.filename)]
                manager.photos[index].spaceImageFilenames = [child.filename]
                manager.photos[index].rotationInterval = "click"
                manager.spaceImages[child.id] = [manager.storageDir.appendingPathComponent(child.filename)]
                XCTAssertTrue(manager.persist())
                let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                surface.transition?.currentProgress = 1
                let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
                let initial = manager.arrangementSnapshot(ids: ids)
                switch gesture {
                case "background":
                    manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 30, dy: 20), finished: true)
                case "resize":
                    XCTAssertNotNil(manager.beginCollageResize(parent.id))
                    manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
                    manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: true)
                default: break
                }
                let finished = manager.arrangementSnapshot(ids: ids)
                let view = try XCTUnwrap(manager.windows[child.id]?.contentView as? DraggablePhotoView)
                let image = try XCTUnwrap(view.photoLayer.image)
                let frame = manager.windows[child.id]?.photoFrame
                let snapshot = PhotosRefreshSnapshot(generation: manager.desktopGeneration, item: manager.photos[index])
                var incoming = manager.photos[index]
                incoming.photosLibrarySource?.lastReconciledAt = Date(timeIntervalSince1970: 2_000_003_600)
                incoming.photosLibraryAssets[0].displayName = "Updated album label"
                XCTAssertTrue(manager.commitPhotosCollectionRefresh(incoming, replacing: snapshot), gesture)
                XCTAssertTrue(view.photoLayer.image === image, "Unchanged bytes must keep their native media: \(gesture)")
                XCTAssertEqual(manager.windows[child.id]?.photoFrame, frame, gesture)
                XCTAssertEqual(manager.arrangementSnapshot(ids: ids), finished, gesture)
                let saved = try JSONDecoder().decode([PhotoItem].self,
                    from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                XCTAssertEqual(saved.first { $0.id == child.id }?.photosLibrarySource, incoming.photosLibrarySource)
                XCTAssertEqual(saved.first { $0.id == child.id }?.photosLibraryAssets, incoming.photosLibraryAssets)
                if gesture != "none" {
                    XCTAssertTrue(manager.canUndoArrangement, gesture)
                    XCTAssertTrue(manager.undoArrangement(), gesture)
                    XCTAssertEqual(manager.arrangementSnapshot(ids: ids), initial, gesture)
                }
            }
        }
    }

    @MainActor
    func testUnchangedPhotosRefreshRestoresVisibleWindowAndRespectsHiddenStates() throws {
        for visibility in ["visible", "manual", "presence", "display", "parent"] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.galleryWall))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == child.id })
                manager.photos[index].photosLibrarySource = PhotosLibrarySource(
                    localIdentifier: "fixture-album", collectionType: .userAlbum, displayName: "Sample album")
                manager.photos[index].photosLibraryAssets = [PhotosLibraryAsset(
                    localIdentifier: "fixture-asset", displayName: "Sample photo", managedFilename: child.filename)]
                manager.photos[index].spaceImageFilenames = [child.filename]
                manager.photos[index].rotationInterval = "click"
                manager.windows.removeValue(forKey: child.id)?.hidePhoto()
                switch visibility {
                case "manual": manager.photos[index].isVisible = false
                case "presence": manager.photos[index].isHiddenForPresence = true
                case "display": manager.photos[index].isHiddenForDisplay = true
                case "parent":
                    let parentIndex = try XCTUnwrap(manager.photos.firstIndex { $0.id == parent.id })
                    manager.photos[parentIndex].isVisible = false
                default: break
                }
                XCTAssertTrue(manager.persist())
                let snapshot = PhotosRefreshSnapshot(generation: manager.desktopGeneration, item: manager.photos[index])
                var incoming = manager.photos[index]
                incoming.photosLibrarySource?.lastReconciledAt = Date(timeIntervalSince1970: 2_000_003_600)
                XCTAssertTrue(manager.commitPhotosCollectionRefresh(incoming, replacing: snapshot), visibility)
                XCTAssertEqual(manager.windows[child.id] != nil, visibility == "visible", visibility)
                XCTAssertEqual(manager.photos[index].spaceImageFilenames, [child.filename])
            }
        }
    }

    @MainActor
    func testPhotosRefreshCommitPreservesAffectedGesturesAndUnrelatedScenes() throws {
        for gesture in ["background", "photo", "resize", "appearance"] {
            for related in [true, false] {
                try withTestLibrary { manager in
                    XCTAssertTrue(manager.addStarterExample(.galleryWall))
                    XCTAssertTrue(manager.addStarterExample(.minimal))
                    let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                    let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                    let other = try XCTUnwrap(manager.photos.last)
                    let target = related ? child : other
                    let newFilename = related ? other.filename : child.filename
                    let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == target.id })
                    manager.photos[index].photosLibrarySource = PhotosLibrarySource(
                        localIdentifier: "fixture-album", collectionType: .userAlbum, displayName: "Sample album")
                    manager.photos[index].photosLibraryAssets = [PhotosLibraryAsset(
                        localIdentifier: "fixture-asset", displayName: "Sample photo", managedFilename: target.filename)]
                    manager.photos[index].spaceImageFilenames = [target.filename]
                    manager.photos[index].rotationInterval = "click"
                    manager.spaceImages[target.id] = [manager.storageDir.appendingPathComponent(target.filename)]
                    XCTAssertTrue(manager.persist())
                    let snapshot = PhotosRefreshSnapshot(generation: manager.desktopGeneration, item: manager.photos[index])
                    let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                    surface.transition?.currentProgress = 1
                    let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
                    let initialFrames = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                        manager.windows[id].map { (id, $0.photoFrame) }
                    })
                    let photoWindow = try XCTUnwrap(manager.windows[child.id])
                    let photoView = try XCTUnwrap(photoWindow.contentView as? DraggablePhotoView)
                    let center = CGPoint(x: photoWindow.photoFrame.midX, y: photoWindow.photoFrame.midY)
                    let moved = CGPoint(x: center.x + 18, y: center.y + 12)
                    let session = UUID()
                    switch gesture {
                    case "background":
                        manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 30, dy: 20), finished: false)
                    case "photo":
                        photoView.mouseDown(with: try testMouseEvent(.leftMouseDown, in: photoWindow, at: center))
                        photoView.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: photoWindow, at: moved, modifiers: .option))
                    case "resize":
                        XCTAssertNotNil(manager.beginCollageResize(parent.id))
                        manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
                    default:
                        manager.beginCollageAppearancePreview(parent.id, session: session)
                        var settings = try XCTUnwrap(parent.desktopCollage)
                        settings.tintStrength = 0.5
                        manager.previewCollageAppearance(parent.id, session: session, settings: settings)
                    }
                    XCTAssertTrue(manager.hasActiveArrangementInteraction)
                    let preview = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                        manager.windows[id].map { (id, $0.photoFrame) }
                    })
                    let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
                    let urls = manager.spaceImages[target.id]
                    var incoming = manager.photos[index]
                    incoming.photosLibraryAssets[0].managedFilename = newFilename
                    incoming.spaceImageFilenames = [newFilename]
                    incoming.photosLibrarySource?.lastReconciledAt = Date(timeIntervalSince1970: 2_000_003_600)

                    XCTAssertEqual(manager.commitPhotosCollectionRefresh(incoming, replacing: snapshot), !related, gesture)

                    XCTAssertTrue(manager.hasActiveArrangementInteraction, gesture)
                    for (id, frame) in preview { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, gesture) }
                    if related {
                        XCTAssertEqual(manager.photos[index].photosLibraryAssets, snapshot.item.photosLibraryAssets, gesture)
                        XCTAssertEqual(manager.spaceImages[target.id], urls, gesture)
                        XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored, gesture)
                    } else {
                        XCTAssertEqual(manager.photos[index].spaceImageFilenames, [newFilename])
                    }
                    switch gesture {
                    case "background": manager.moveCollage(parent.id, to: surface.photoFrame, finished: true)
                    case "photo": photoView.mouseUp(with: try testMouseEvent(.leftMouseUp, in: photoWindow, at: moved))
                    case "resize": manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: true)
                    default: manager.endCollageAppearancePreview(parent.id, animated: false)
                    }
                    if gesture != "appearance" {
                        XCTAssertEqual(manager.arrangementUndo.count, 1, gesture)
                        XCTAssertTrue(manager.undoArrangement(), gesture)
                        for (id, frame) in initialFrames { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, gesture) }
                    }
                    if related {
                        var retried = try XCTUnwrap(manager.photos.first { $0.id == target.id })
                        retried.photosLibraryAssets = incoming.photosLibraryAssets
                        retried.spaceImageFilenames = incoming.spaceImageFilenames
                        retried.photosLibrarySource = incoming.photosLibrarySource
                        XCTAssertTrue(manager.commitPhotosCollectionRefresh(retried, replacing: snapshot), gesture)
                    }
                }
            }
        }
    }

    @MainActor
    func testCompletedPhotosRefreshWaitsForItsSceneAndKeepsLatestEdits() async throws {
        for outcome in ["finish", "cancel", "source", "unrelated"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasPhotosRefreshWait-" + UUID().uuidString)
            let manager = PhotoManager(storageDirectory: root)
            defer {
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
            let other = try XCTUnwrap(manager.photos.last)
            let target = outcome == "unrelated" ? other : child
            let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == target.id })
            manager.photos[index].photosLibrarySource = PhotosLibrarySource(
                localIdentifier: "fixture-album", collectionType: .userAlbum, displayName: "Sample album")
            manager.photos[index].photosLibraryAssets = [PhotosLibraryAsset(
                localIdentifier: "fixture-asset", displayName: "Sample photo", managedFilename: target.filename)]
            manager.photos[index].spaceImageFilenames = [target.filename]
            manager.photos[index].rotationInterval = "click"
            manager.spaceImages[target.id] = [root.appendingPathComponent(target.filename)]
            XCTAssertTrue(manager.persist())
            let snapshot = PhotosRefreshSnapshot(generation: manager.desktopGeneration, item: manager.photos[index])
            let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 30, dy: 20), finished: false)
            let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
            let preview = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                manager.windows[id].map { (id, $0.photoFrame) }
            })
            let stored = try Data(contentsOf: root.appendingPathComponent("photos.json"))
            let started = expectation(description: "Completed refresh checks its scene")
            var waitMessages = 0
            var completed = false
            let pending = Task { @MainActor in
                started.fulfill()
                let ready = await snapshot.readyIndex(in: manager) { waitMessages += 1 }
                completed = true
                return ready
            }
            defer { pending.cancel() }
            await fulfillment(of: [started], timeout: 2)
            for _ in 0..<3 { await Task.yield() }
            XCTAssertEqual(completed, outcome == "unrelated", outcome)
            XCTAssertEqual(waitMessages, outcome == "unrelated" ? 0 : 1, outcome)
            XCTAssertTrue(manager.hasActiveArrangementInteraction)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photos.json")), stored)
            for (id, frame) in preview { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, outcome) }

            switch outcome {
            case "cancel":
                pending.cancel()
                let ready = await pending.value
                XCTAssertNil(ready)
                XCTAssertTrue(manager.hasActiveArrangementInteraction)
            case "source":
                manager.photos[index].photosLibrarySource?.localIdentifier = "another-album"
                let ready = await pending.value
                XCTAssertNil(ready)
                XCTAssertTrue(manager.hasActiveArrangementInteraction)
            default:
                manager.renamePhoto(target.id, to: "Name changed while refresh waited")
                if outcome == "finish" {
                    manager.moveCollage(parent.id, to: surface.photoFrame, finished: true)
                    XCTAssertEqual(manager.arrangementUndo.count, 1)
                }
                let completedIndex = await pending.value
                let ready = try XCTUnwrap(completedIndex)
                var incoming = manager.photos[ready]
                XCTAssertEqual(incoming.customName, "Name changed while refresh waited")
                incoming.photosLibraryAssets[0].managedFilename = outcome == "finish" ? other.filename : child.filename
                incoming.spaceImageFilenames = incoming.photosLibraryAssets.map(\.managedFilename)
                XCTAssertTrue(manager.commitPhotosCollectionRefresh(incoming, replacing: snapshot))
                XCTAssertEqual(manager.photos[ready].customName, "Name changed while refresh waited")
                XCTAssertEqual(manager.photos[ready].spaceImageFilenames, incoming.spaceImageFilenames)
                if outcome == "unrelated" {
                    XCTAssertTrue(manager.hasActiveArrangementInteraction)
                    for (id, frame) in preview { XCTAssertEqual(manager.windows[id]?.photoFrame, frame) }
                }
            }
        }
    }

    @MainActor
    func testPhotosRefreshCommitFailureKeepsNativeImageAndSnapshot() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let item = try XCTUnwrap(manager.photos.first { $0.collageParentID != nil })
            let other = try XCTUnwrap(manager.photos.last { $0.collageParentID != nil && $0.id != item.id })
            let index = try XCTUnwrap(manager.photos.firstIndex { $0.id == item.id })
            manager.photos[index].photosLibrarySource = PhotosLibrarySource(
                localIdentifier: "fixture-album", collectionType: .userAlbum, displayName: "Sample album")
            manager.photos[index].photosLibraryAssets = [PhotosLibraryAsset(
                localIdentifier: "fixture-asset", displayName: "Sample photo", managedFilename: item.filename)]
            manager.photos[index].spaceImageFilenames = [item.filename]
            manager.spaceImages[item.id] = [manager.storageDir.appendingPathComponent(item.filename)]
            XCTAssertTrue(manager.persist())
            let snapshot = PhotosRefreshSnapshot(generation: manager.desktopGeneration, item: manager.photos[index])
            let view = try XCTUnwrap(manager.windows[item.id]?.contentView as? DraggablePhotoView)
            let image = try XCTUnwrap(view.photoLayer.image)
            let frame = manager.windows[item.id]?.photoFrame
            let urls = manager.spaceImages[item.id]
            let stored = try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json"))
            var incoming = manager.photos[index]
            incoming.photosLibraryAssets[0].managedFilename = other.filename
            incoming.spaceImageFilenames = [other.filename]
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
            XCTAssertFalse(manager.commitPhotosCollectionRefresh(incoming, replacing: snapshot))
            XCTAssertEqual(manager.photos[index].photosLibraryAssets, snapshot.item.photosLibraryAssets)
            XCTAssertEqual(manager.spaceImages[item.id], urls)
            XCTAssertEqual(manager.windows[item.id]?.photoFrame, frame)
            XCTAssertTrue(view.photoLayer.image === image)
            XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")), stored)
        }
    }

    @MainActor
    func testPhotosCollectionStatusChangesRollBackWhenStoreCannotBeWritten() throws {
        for status in [PhotosLibraryCollectionStatus.empty, .needsRelink] {
            try withTestLibrary { manager in
                XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
                var item = try XCTUnwrap(manager.photos.first)
                item.photosLibrarySource = PhotosLibrarySource(localIdentifier: "fixture-album", collectionType: .userAlbum,
                    displayName: "Sample album", lastReconciledAt: Date(timeIntervalSince1970: 2_000_000_000))
                manager.photos = [item]
                XCTAssertTrue(manager.persist())
                let previous = try photoDictionary(item)
                let file = manager.storageDir.appendingPathComponent("photos.json")
                let stored = try Data(contentsOf: file)
                let media = try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename))
                var next = try XCTUnwrap(item.photosLibrarySource)
                next.status = status
                next.lastError = "Sample collection unavailable"
                next.lastReconciledAt = Date(timeIntervalSince1970: 2_000_003_600)
                // Prevent an atomic file replacement while keeping its last good
                // contents readable. Only this unique scratch store is affected.
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: manager.storageDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.storageDir.path) }
                XCTAssertFalse(manager.storePhotosCollectionSource(item.id, source: next))
                XCTAssertEqual(try photoDictionary(try XCTUnwrap(manager.photos.first)) as NSDictionary, previous as NSDictionary)
                XCTAssertEqual(try Data(contentsOf: file), stored)
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename)), media)
            }
        }
    }

    @MainActor
    func testPhotosCollectionStatusChangesPersistWithoutChangingMediaOrAppearance() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
            var item = try XCTUnwrap(manager.photos.first)
            item.photosLibrarySource = PhotosLibrarySource(localIdentifier: "fixture-album", collectionType: .userAlbum,
                                                           displayName: "Sample album")
            manager.photos = [item]
            XCTAssertTrue(manager.persist())
            let media = try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename))
            for status in [PhotosLibraryCollectionStatus.empty, .needsRelink] {
                var next = try XCTUnwrap(item.photosLibrarySource)
                next.status = status
                next.lastError = "Keep the previous snapshot"
                XCTAssertTrue(manager.storePhotosCollectionSource(item.id, source: next))
                var expected = item
                expected.photosLibrarySource = next
                let saved = try JSONDecoder().decode([PhotoItem].self,
                    from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
                XCTAssertEqual(try photoDictionary(try XCTUnwrap(saved.first)) as NSDictionary, try photoDictionary(expected) as NSDictionary)
                XCTAssertEqual(try Data(contentsOf: manager.storageDir.appendingPathComponent(item.filename)), media)
            }
            XCTAssertFalse(manager.storePhotosCollectionSource(UUID(), source: try XCTUnwrap(item.photosLibrarySource)))
        }
    }

    func testEditedPhotosResourcesTakePriorityRegardlessOfResourceOrder() throws {
        for reversed in [false, true] {
            let resources: [PHAssetResourceType] = [.adjustmentData, .photo, .fullSizePhoto, .alternatePhoto]
            let types = reversed ? Array(resources.reversed()) : resources
            let index = try XCTUnwrap(PhotosLibraryResourcePolicy.photoIndex(in: types))
            XCTAssertEqual(types[index], .fullSizePhoto, "Photos edits must replace the unmodified original")
            let movies: [PHAssetResourceType] = [.adjustmentData, .video, .fullSizeVideo]
            let movieTypes = reversed ? Array(movies.reversed()) : movies
            let videoIndex = try XCTUnwrap(PhotosLibraryResourcePolicy.videoIndex(in: movieTypes))
            XCTAssertEqual(movieTypes[videoIndex], .fullSizeVideo)
            let pairs: [PHAssetResourceType] = [.adjustmentBasePairedVideo, .fullSizePairedVideo]
            let pairTypes = reversed ? Array(pairs.reversed()) : pairs
            let pairIndex = try XCTUnwrap(PhotosLibraryResourcePolicy.pairedVideoIndex(in: pairTypes))
            XCTAssertEqual(pairTypes[pairIndex], .fullSizePairedVideo)
            XCTAssertEqual(PhotosLibraryResourcePolicy.selectedTypes(for: .livePhoto, in: types + pairTypes),
                           [PHAssetResourceType.fullSizePhoto.rawValue, PHAssetResourceType.fullSizePairedVideo.rawValue])
            XCTAssertEqual(PhotosLibraryResourcePolicy.selectedTypes(for: .video, in: movieTypes),
                           [PHAssetResourceType.fullSizeVideo.rawValue])
        }
    }

    func testPhotosResourcesPreserveOriginalCompatibilityWithoutUsingAdjustmentFilesAsMedia() throws {
        XCTAssertEqual(PhotosLibraryResourcePolicy.photoIndex(in: [.adjustmentData, .photo]), 1)
        XCTAssertEqual(PhotosLibraryResourcePolicy.photoIndex(in: [.adjustmentData, .alternatePhoto]), 1)
        XCTAssertEqual(PhotosLibraryResourcePolicy.videoIndex(in: [.audio, .video]), 1)
        XCTAssertEqual(PhotosLibraryResourcePolicy.pairedVideoIndex(in: [.photo, .adjustmentBasePairedVideo]), 1)
        XCTAssertNil(PhotosLibraryResourcePolicy.photoIndex(in: [.adjustmentData, .audio, .video]))
        XCTAssertNil(PhotosLibraryResourcePolicy.videoIndex(in: [.adjustmentData, .audio, .photo]))
        XCTAssertNil(PhotosLibraryResourcePolicy.pairedVideoIndex(in: [.adjustmentData, .video]))
        XCTAssertNil(PhotosLibraryResourcePolicy.photoIndex(in: []))
        XCTAssertNil(PhotosLibraryResourcePolicy.videoIndex(in: []))
        XCTAssertNil(PhotosLibraryResourcePolicy.selectedTypes(for: .livePhoto, in: [.fullSizePhoto, .video]))
    }

    func testLegacyPhotosCacheRevalidatesResourceSelectionAndNewMetadataSurvivesReload() throws {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let descriptor = PhotosAssetDescriptor(localIdentifier: "asset", displayName: "Sample", mediaKind: .still,
                                               modificationDate: date, estimatedBytes: 20)
        let original = PhotosLibraryAsset(localIdentifier: "asset", displayName: "Sample", managedFilename: "sample.png",
                                         sourceModificationDate: date)
        let legacy = try JSONDecoder().decode(PhotosLibraryAsset.self, from: JSONEncoder().encode(original))
        XCTAssertNil(legacy.sourceResourceTypes)
        XCTAssertEqual(legacy.managedFilenames, ["sample.png"])
        XCTAssertFalse(legacy.matchesCurrentResource(descriptor, resourceTypes: [PHAssetResourceType.photo.rawValue]),
                       "An old cache does not identify which representation it downloaded")

        var current = legacy
        current.sourceResourceTypes = [PHAssetResourceType.fullSizePhoto.rawValue]
        let reloaded = try JSONDecoder().decode(PhotosLibraryAsset.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(reloaded, current)
        XCTAssertTrue(reloaded.matchesCurrentResource(descriptor, resourceTypes: current.sourceResourceTypes))
        XCTAssertFalse(reloaded.matchesCurrentResource(descriptor, resourceTypes: [PHAssetResourceType.photo.rawValue]),
                       "Reverting Photos edits can change resource type even when the modification date is unchanged")
        XCTAssertFalse(reloaded.matchesCurrentResource(descriptor, resourceTypes: nil))
        XCTAssertNil(reloaded.archiveSnapshot.sourceResourceTypes)
        XCTAssertEqual(reloaded.archiveSnapshot.managedFilenames, current.managedFilenames)
        var stale = reloaded
        stale.status = .failed
        XCTAssertFalse(stale.matchesCurrentResource(descriptor, resourceTypes: current.sourceResourceTypes))
        stale = reloaded
        stale.sourceModificationDate = date.addingTimeInterval(-1)
        XCTAssertFalse(stale.matchesCurrentResource(descriptor, resourceTypes: current.sourceResourceTypes))
        stale = reloaded
        stale.localIdentifier = "another asset"
        XCTAssertFalse(stale.matchesCurrentResource(descriptor, resourceTypes: current.sourceResourceTypes))
    }

    @MainActor
    func testPhotosResourceCacheMetadataStaysLocalAcrossArchiveExportAndImport() throws {
        try withTestLibrary { source in
            XCTAssertTrue(source.addStarterExample(.minimal, makeVisible: false))
            var item = try XCTUnwrap(source.photos.first)
            let bytes = try Data(contentsOf: source.storageDir.appendingPathComponent(item.filename))
            item.photosLibrarySource = PhotosLibrarySource(localIdentifier: "fixture-album", collectionType: .userAlbum,
                                                           displayName: "Sample album")
            let asset = PhotosLibraryAsset(localIdentifier: "fixture-asset", displayName: "Sample",
                managedFilename: item.filename, sourceModificationDate: Date(timeIntervalSince1970: 2_000_000_000),
                sourceResourceTypes: [PHAssetResourceType.fullSizePhoto.rawValue])
            item.photosLibraryAssets = [asset]
            item.spaceImageFilenames = [item.filename]
            source.photos = [item]
            XCTAssertTrue(source.persist())
            let persisted = try JSONDecoder().decode([PhotoItem].self,
                from: Data(contentsOf: source.storageDir.appendingPathComponent("photos.json")))
            XCTAssertEqual(persisted[0].photosLibraryAssets[0], asset)

            let archive = source.storageDir.appendingPathComponent("sample.arras")
            try source.exportWidget(item.id, to: archive)
            let reader = try SimpleZipReader(data: Data(contentsOf: archive))
            let manifest = String(decoding: try XCTUnwrap(reader.entryData(named: "manifest.json")), as: UTF8.self)
            XCTAssertFalse(manifest.contains("sourceResourceTypes"))
            XCTAssertFalse(manifest.contains("fixture-album"))
            XCTAssertFalse(manifest.contains("fixture-asset"))
            try withTestLibrary { target in
                XCTAssertEqual(try target.importLayout(from: archive, mode: .merge), 1)
                let imported = try XCTUnwrap(target.photos.first)
                let snapshot = try XCTUnwrap(imported.photosLibraryAssets.first)
                XCTAssertNil(snapshot.sourceResourceTypes)
                XCTAssertTrue(snapshot.localIdentifier.isEmpty)
                XCTAssertEqual(snapshot.status, .snapshot)
                XCTAssertEqual(try Data(contentsOf: target.storageDir.appendingPathComponent(snapshot.managedFilename)), bytes)
                XCTAssertNil(target.photosLibraryObserver)
            }
            XCTAssertEqual(source.photos[0].photosLibraryAssets[0], asset)
        }
    }

    @MainActor
    func testClosingOrCancellingProgressStopsPendingPhotosResource() async throws {
        for action in ["close", "cancel", "escape"] {
            let started = expectation(description: "Photos resource request started")
            let cancelled = expectation(description: "Photos resource request cancelled once")
            cancelled.assertForOverFulfill = true
            let sync = Task {
                try await PhotosResourceTransfer.read(maxBytes: 1024) { receive, finish in
                    receive(Data([1]))
                    started.fulfill()
                    return {
                        cancelled.fulfill()
                        finish(NSError(domain: "cancelled", code: 1))
                    }
                }
            }
            let progress = PhotosLibraryProgressPanel(collectionName: "Test album")
            progress.onCancel = { sync.cancel() }
            defer { progress.close(); sync.cancel() }
            progress.show()
            await fulfillment(of: [started], timeout: 2)

            if action == "close" {
                progress.panel.performClose(nil)
            } else {
                let button = try XCTUnwrap(progress.panel.contentView?.subviews.compactMap { $0 as? NSButton }.first)
                XCTAssertEqual(button.title, "Cancel")
                XCTAssertEqual(button.keyEquivalent, "\u{1b}")
                if action == "escape" {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: progress.panel.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    XCTAssertTrue(progress.panel.performKeyEquivalent(with: event))
                } else {
                    button.performClick(nil)
                }
            }
            await fulfillment(of: [cancelled], timeout: 2)
            do {
                _ = try await sync.value
                XCTFail("A dismissed Photos import must not finish its download")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(progress.panel.isVisible)
            XCTAssertNil(progress.onCancel)
            progress.close()
            progress.update(.failed("Late progress after cancellation"))
        }
    }

    @MainActor
    func testCompletedPhotosProgressDoesNotCancelOrRetainItsOperation() {
        let progress = PhotosLibraryProgressPanel(collectionName: "Test album")
        var cancelled = false
        progress.onCancel = { cancelled = true }
        progress.close()
        progress.close()
        XCTAssertFalse(cancelled)
        XCTAssertNil(progress.onCancel)
    }

    @MainActor
    func testCollectionChooserAndProgressReleaseAfterSync() async throws {
        for _ in 0..<3 {
            await exerciseCollectionWindows()
        }
    }

    @MainActor
    func testInitialAlbumSelectionMatchesItsNativeRowBeforeAndAfterLayout() throws {
        for count in [1, 3] {
            let selections = (0..<count).map { PhotosLibraryCollectionSelection(
                localIdentifier: "fixture-\($0)", collectionType: .userAlbum, displayName: "Album \($0)", assetCount: 1) }
            let chooser = PhotosLibraryCollectionChooserView(collections: selections)
            let scroll = try XCTUnwrap(chooser.subviews.compactMap { $0 as? NSScrollView }.first)
            let table = try XCTUnwrap(scroll.documentView as? NSTableView)
            let initialRow = table.selectedRow
            XCTAssertEqual(initialRow, 0, "The native row must agree with the initial value selection")
            XCTAssertEqual(chooser.selectedCollection, selections.first)
            let panel = NSPanel(contentRect: chooser.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.contentView = nil; panel.close() }
            panel.contentView = chooser
            chooser.layoutSubtreeIfNeeded()
            XCTAssertEqual(table.numberOfRows, count)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertEqual(chooser.selectedCollection, selections.first)
        }
    }

    @MainActor
    func testAlbumChooserReturnsTheAcceptedAlbumIfSelectionChangesBeforeModalReturns() throws {
        let selection = PhotosLibraryCollectionSelection(localIdentifier: "fixture", collectionType: .userAlbum,
                                                         displayName: "Test album", assetCount: 1)
        var clicked = false
        let result = PhotosLibraryCollectionPicker.chooseCollection([selection], relinking: false) { panel in
            let chooser = panel.contentView?.subviews.compactMap { $0 as? PhotosLibraryCollectionChooserView }.first
            let button = panel.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Sync Album" }
            let table = chooser?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView
            let search = chooser?.subviews.compactMap { $0 as? NSSearchField }.first
            var observations = ["opened: row=\(table?.selectedRow ?? -99) selected=\(chooser?.selectedCollection?.id ?? "nil") enabled=\(button?.isEnabled == true)"]
            let selectionChanged = chooser?.onSelectionChange
            chooser?.onSelectionChange = { [weak chooser, weak table, weak button] usable in
                let sourceRows = table.flatMap { $0.dataSource?.numberOfRows?(in: $0) }
                observations.append("selection: row=\(table?.selectedRow ?? -99) selected=\(chooser?.selectedCollection?.id ?? "nil") usable=\(usable) enabled=\(button?.isEnabled == true) rows=\(table?.numberOfRows ?? -99) sourceRows=\(sourceRows ?? -99) columns=\(table?.tableColumns.map(\.isHidden) ?? []) search=\(search?.stringValue ?? "nil")")
                if !usable { observations.append("stack=" + Thread.callStackSymbols.prefix(24).joined(separator: " | ")) }
                selectionChanged?(usable)
            }
            XCTAssertNotNil(chooser)
            XCTAssertNotNil(button)
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                guard NSApp.modalWindow === panel, !clicked else { return }
                clicked = true
                guard let button, button.isEnabled else {
                    XCTFail("The fixture album must enable its native Sync action; active=\(NSApp.isActive) key=\(panel.isKeyWindow) rows=\(table?.numberOfRows ?? -99) observations=\(observations)")
                    NSApp.abortModal()
                    return
                }
                button.performClick(nil)
                // A table/view callback may run after the action and before
                // runModal returns. The accepted value must already be captured.
                chooser?.filterAlbums("no matching album")
                XCTAssertNil(chooser?.selectedCollection)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            return NSApp.runModal(for: panel)
        }
        XCTAssertTrue(clicked)
        XCTAssertEqual(result, selection)
    }

    @MainActor
    func testAlbumSearchClearsStaleSelectionAndRestoresMatchingAlbum() {
        let albums = [
            PhotosLibraryCollectionSelection(localIdentifier: "a", collectionType: .userAlbum, displayName: "Summer", assetCount: 2),
            PhotosLibraryCollectionSelection(localIdentifier: "b", collectionType: .sharedAlbum, displayName: "Family", assetCount: 4)
        ]
        let chooser = PhotosLibraryCollectionChooserView(collections: albums)
        var canSync = true
        chooser.onSelectionChange = { canSync = $0 }
        chooser.filterAlbums("missing")
        XCTAssertNil(chooser.selectedCollection)
        XCTAssertFalse(canSync, "An empty search must not sync the previously selected album")
        chooser.filterAlbums(" family ")
        XCTAssertEqual(chooser.selectedCollection, albums[1])
        XCTAssertTrue(canSync)
        chooser.filterAlbums("")
        XCTAssertEqual(chooser.selectedCollection, albums[1])
    }

    @MainActor
    private func exerciseCollectionWindows() async {
        let selection = PhotosLibraryCollectionSelection(localIdentifier: "fixture", collectionType: .userAlbum,
                                                          displayName: "Test album", assetCount: 1)
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn] {
            var actualResponse: NSApplication.ModalResponse?
            var stopRequests = 0
            let result = PhotosLibraryCollectionPicker.chooseCollection([selection], relinking: false) { panel in
                let title = response == .alertFirstButtonReturn ? "Sync Album" : "Cancel"
                let button = panel.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == title }
                XCTAssertNotNil(button)
                let deadline = Date().addingTimeInterval(2)
                let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
                    if NSApp.modalWindow === panel {
                        stopRequests += 1
                        if Date() > deadline {
                            XCTFail("Native \(title) action did not finish; enabled=\(button?.isEnabled == true)")
                            NSApp.abortModal()
                        } else {
                            button?.performClick(nil)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                defer { timer.invalidate() }
                let returned = NSApp.runModal(for: panel)
                actualResponse = returned
                return returned
            }
            XCTAssertEqual(result, response == .alertFirstButtonReturn ? selection : nil,
                           "Requested \(response.rawValue), returned \(String(describing: actualResponse?.rawValue)), modal stop requests=\(stopRequests), host active=\(NSApp.isActive)")
        }
        let progress = PhotosLibraryProgressPanel(collectionName: "Test album")
        progress.show()
        await Task.yield()
        progress.update(.idle)
        progress.close()
        progress.close()
        progress.update(.failed("Late progress after dismissal"))
        await Task.yield()
    }
    @MainActor
    func testPhotosRefreshDoesNotRevealPrivacyOrDisplayHiddenWidget() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let original = try XCTUnwrap(manager.photos.first)
            manager.windows[original.id]?.hidePhoto()
            manager.windows.removeValue(forKey: original.id)
            var hidden = original
            hidden.isHiddenForPresence = true
            manager.refreshPhotosLibraryWindow(hidden)
            XCTAssertNil(manager.windows[original.id])
            hidden.isHiddenForPresence = false
            hidden.isHiddenForDisplay = true
            manager.refreshPhotosLibraryWindow(hidden)
            XCTAssertNil(manager.windows[original.id])
        }
    }

    @MainActor
    func testRefreshResolvesMovedIndexAndLatestAppearanceButRejectsReplacedDesktop() throws {
        try withTestLibrary { manager in
            var item = PhotoItem(filename: "snapshot.png")
            item.isVisible = false
            item.photosLibrarySource = PhotosLibrarySource(localIdentifier: "album", collectionType: .userAlbum, displayName: "Album")
            manager.photos = [PhotoItem(filename: "other.png"), item]
            let snapshot = PhotosRefreshSnapshot(generation: manager.desktopGeneration, item: item)
            manager.photos.removeFirst()
            manager.photos[0].customName = "Renamed during sync"
            manager.photos[0].opacity = 0.4
            let index = try XCTUnwrap(snapshot.currentIndex(in: manager))
            XCTAssertEqual(index, 0)
            XCTAssertEqual(manager.photos[index].customName, "Renamed during sync")
            XCTAssertEqual(manager.photos[index].opacity, 0.4)
            manager.photos[0].photosLibrarySource?.localIdentifier = "another album"
            XCTAssertNil(snapshot.currentIndex(in: manager))
            manager.photos = [item]
            XCTAssertNotNil(snapshot.currentIndex(in: manager))
            XCTAssertTrue(manager.restoreDesktopSetupItems([item]))
            XCTAssertNil(snapshot.currentIndex(in: manager))
        }
    }

    @MainActor
    func testPermissionRecoveryOpensPhotosPaneBeforeGeneralPrivacyFallback() {
        var opened: [String] = []
        PhotosPermissionRecovery.openSystemSettings { url in
            opened.append(url.absoluteString)
            return true
        }
        XCTAssertEqual(opened, ["x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"])
        opened.removeAll()
        PhotosPermissionRecovery.openSystemSettings { url in
            opened.append(url.absoluteString)
            return opened.count == 2
        }
        XCTAssertEqual(opened, ["x-apple.systempreferences:com.apple.preference.security?Privacy_Photos",
                                "x-apple.systempreferences:com.apple.preference.security"])
    }

    func testBackgroundAuthorizationNeverPromptsAndExplicitRequestPromptsOnlyWhenNeeded() async {
        for status: PHAuthorizationStatus in [.notDetermined, .denied, .restricted, .authorized] {
            var requests = 0
            let result = await PhotosLibraryAuthorization.requestIfNeeded(
                allowPrompt: false, currentStatus: { status }, request: { requests += 1; return .authorized }
            )
            XCTAssertEqual(result, status)
            XCTAssertEqual(requests, 0)
            let explicit = await PhotosLibraryAuthorization.requestIfNeeded(
                currentStatus: { status }, request: { requests += 1; return .authorized }
            )
            XCTAssertEqual(explicit, status == .notDetermined ? .authorized : status)
            XCTAssertEqual(requests, status == .notDetermined ? 1 : 0)
        }
    }

    @MainActor
    func testLibraryChangesDuringDownloadCoalesceIntoOneFollowupWithoutOverlap() async {
        let reconciler = PhotosChangeReconciler()
        var passes = 0
        var active = 0
        var maximumActive = 0
        var releaseDownload: CheckedContinuation<Void, Never>?
        let started = expectation(description: "First download started")
        let operation: @MainActor () async -> Void = {
            passes += 1
            active += 1
            maximumActive = max(maximumActive, active)
            if passes == 1 {
                await withCheckedContinuation { continuation in
                    releaseDownload = continuation
                    started.fulfill()
                }
            }
            active -= 1
        }
        reconciler.enqueue(operation)
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<20 { reconciler.enqueue(operation) }
        XCTAssertEqual(passes, 1)
        releaseDownload?.resume()
        await reconciler.task?.value
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(maximumActive, 1)
        XCTAssertNil(reconciler.task)
        reconciler.enqueue(operation)
        await reconciler.task?.value
        XCTAssertEqual(passes, 3)
    }

    @MainActor
    func testUnlinkedSnapshotPreservesMediaAndDoesNotRegisterObserverOrPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasUnlinkedSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PhotoManager(storageDirectory: directory)
        var item = PhotoItem(filename: "saved.png")
        item.isVisible = false
        item.photosLibrarySource = PhotosLibrarySource(localIdentifier: "", collectionType: .userAlbum, displayName: "Saved album")
        manager.photos = [item]
        manager.installPhotosLibraryObserver()
        XCTAssertNil(manager.photosLibraryObserver)
        let result = await manager.refreshPhotosLibraryCollection(item.id)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(manager.photos.first?.filename, "saved.png")
        XCTAssertEqual(manager.photos.first?.photosLibrarySource?.localIdentifier, "")
    }

    @MainActor
    func testCancelledReconciliationStopsAndAcceptsFreshChangesWithoutOverlap() async {
        let reconciler = PhotosChangeReconciler()
        let started = expectation(description: "first reconciliation started")
        let restarted = expectation(description: "fresh change reconciled")
        var runs = 0
        var active = 0
        var maximumActive = 0
        let operation: @MainActor () async -> Void = {
            runs += 1
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if runs == 1 {
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { XCTAssertTrue(Task.isCancelled) }
            } else { restarted.fulfill() }
        }
        reconciler.enqueue(operation)
        await fulfillment(of: [started], timeout: 2)
        reconciler.cancel()
        reconciler.enqueue(operation)
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(maximumActive, 1)
    }

    func testPhotosPermissionRecoveryOffersSettingsOnlyForDeniedAccess() {
        XCTAssertEqual(PhotosPermissionRecovery.action(for: .denied), .openSettings)
        XCTAssertEqual(PhotosPermissionRecovery.action(for: .restricted), .explainRestriction)
        XCTAssertEqual(PhotosPermissionRecovery.action(for: .authorized), .none)
        XCTAssertEqual(PhotosPermissionRecovery.action(for: .notDetermined), .none)
    }

    func testSourceAndAssetArchiveSnapshotsDropPhotosIdentifiers() {
        let source = PhotosLibrarySource(
            localIdentifier: "album-local-id",
            collectionType: .sharedAlbum,
            displayName: "Family",
            status: .active
        )
        let asset = PhotosLibraryAsset(
            localIdentifier: "asset-local-id",
            displayName: "IMG_0001",
            managedFilename: "still.jpg",
            media: PhotoMedia(kind: .livePhoto, pairedVideoFilename: "motion.mov"),
            sourceByteCount: 12,
            pairedVideoByteCount: 34
        )

        let sourceSnapshot = source.archiveSnapshot
        let assetSnapshot = asset.archiveSnapshot

        XCTAssertTrue(sourceSnapshot.localIdentifier.isEmpty)
        XCTAssertEqual(sourceSnapshot.collectionType, .sharedAlbum)
        XCTAssertEqual(sourceSnapshot.displayName, "Family")
        XCTAssertEqual(sourceSnapshot.status, .needsRelink)
        XCTAssertTrue(assetSnapshot.localIdentifier.isEmpty)
        XCTAssertEqual(assetSnapshot.status, .snapshot)
        XCTAssertEqual(assetSnapshot.media.pairedVideoFilename, "motion.mov")
        XCTAssertEqual(assetSnapshot.managedFilenames, ["still.jpg", "motion.mov"])
    }

    func testPhotosPolicyPreservesCurrentAssetWithinCountAndByteBounds() {
        let candidates = (0..<(PhotosLibraryCollectionPolicy.maxManagedAssets + 1)).map { index in
            PhotosAssetDescriptor(
                localIdentifier: "asset-\(index)",
                displayName: "Asset \(index)",
                mediaKind: .still,
                modificationDate: nil,
                estimatedBytes: 1
            )
        }

        let currentID = "asset-\(PhotosLibraryCollectionPolicy.maxManagedAssets)"
        let result = PhotosLibraryCollectionPolicy.bounded(candidates, currentAssetIdentifier: currentID)

        XCTAssertEqual(result.selected.count, PhotosLibraryCollectionPolicy.maxManagedAssets)
        XCTAssertTrue(result.selected.contains { $0.localIdentifier == currentID })
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testPhotosPolicyRejectsAnOversizedAssetUnlessItIsTheCurrentSnapshot() {
        let oversized = PhotosAssetDescriptor(
            localIdentifier: "oversized",
            displayName: "Oversized",
            mediaKind: .video,
            modificationDate: nil,
            estimatedBytes: PhotosLibraryCollectionPolicy.maxManagedBytes + 1
        )
        let small = PhotosAssetDescriptor(
            localIdentifier: "small",
            displayName: "Small",
            mediaKind: .still,
            modificationDate: nil,
            estimatedBytes: 1
        )

        let normal = PhotosLibraryCollectionPolicy.bounded(
            [oversized, small],
            currentAssetIdentifier: nil
        )
        XCTAssertEqual(normal.selected.map(\.localIdentifier), ["small"])
        XCTAssertEqual(normal.skipped.map(\.localIdentifier), ["oversized"])

        let current = PhotosLibraryCollectionPolicy.bounded(
            [oversized, small],
            currentAssetIdentifier: "oversized"
        )
        XCTAssertEqual(current.selected.map(\.localIdentifier), ["oversized"])
        XCTAssertEqual(current.skipped.map(\.localIdentifier), ["small"])
    }

    func testPhotosAssetStatusRoundTripsForLegacySafeSnapshot() throws {
        let asset = PhotosLibraryAsset(
            localIdentifier: "asset-id",
            displayName: "Portrait",
            managedFilename: "portrait.webp",
            status: .missing,
            sourceModificationDate: Date(timeIntervalSince1970: 20),
            sourceByteCount: 100
        )
        let decoded = try JSONDecoder().decode(
            PhotosLibraryAsset.self,
            from: JSONEncoder().encode(asset)
        )

        XCTAssertEqual(decoded, asset)
        XCTAssertEqual(decoded.status.displayName, "Missing from Photos")
    }
}
