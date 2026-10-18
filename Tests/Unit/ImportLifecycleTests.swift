import AppKit
import XCTest
@testable import Arras

private final class HeldMediaPreparation: @unchecked Sendable {
    let started: XCTestExpectation
    private let release = DispatchSemaphore(value: 0)

    init(started: XCTestExpectation) { self.started = started }

    func wait() {
        started.fulfill()
        precondition(release.wait(timeout: .now() + 5) == .success, "Import fixture was not released")
    }

    func resume() { release.signal() }
}

final class ImportLifecycleTests: XCTestCase {
    @MainActor
    func testOverlappingSuccessfulAddsPreservePlaybackAndArrangementHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasSuccessfulAdds-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: root)
        defer {
            manager.rotationTimers.values.forEach { $0.cancel() }
            manager.windows.values.forEach { $0.hidePhoto() }
            manager.windows.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(manager.addStarterExample(.rotatingSpace, makeVisible: false))
        manager.photos[0].isVisible = true
        let item = try XCTUnwrap(manager.photos.first)
        // Keep occlusion policy independent of whichever app covers the test host.
        // Native runtime-policy behavior is covered separately; this checks import ownership.
        let window = DesktopPhotoWindow()
        window.photoId = item.id
        window.showPhoto(try XCTUnwrap(manager.loadDisplayContent(for: item)), baseWidth: item.widgetWidth, locked: false, settings: item)
        window.setPhotoFrame(NSRectFromString(item.frameString))
        manager.windows[item.id] = window
        manager.setupRotationTimer(for: item)
        let image = try XCTUnwrap((window.contentView as? DraggablePhotoView)?.photoLayer.image)
        let timer = try XCTUnwrap(manager.rotationTimers[item.id])
        let urls = manager.spaceImages[item.id]
        let original = window.photoFrame
        let generation = manager.desktopGeneration
        manager.selectedPhotoIDs = [item.id]
        manager.nudgeSelected(.right, modifiers: [.shift])
        XCTAssertTrue(manager.undoArrangement())
        let firstGate = HeldMediaPreparation(started: expectation(description: "First add is preparing"))
        let secondGate = HeldMediaPreparation(started: expectation(description: "Second add is preparing"))
        defer { firstGate.resume(); secondGate.resume() }
        manager.prepareImportedData = { data, directory, name in
            (name == "first" ? firstGate : secondGate).wait()
            return PhotoIngest.prepare(data: data, in: directory, originalName: name)
        }
        let data = try sampleData()
        let first = Task { @MainActor in await manager.importPhotos(data: [data], sourceNames: ["first"]) }
        let second = Task { @MainActor in await manager.importPhotos(data: [data], sourceNames: ["second"]) }
        await fulfillment(of: [firstGate.started, secondGate.started], timeout: 3)
        firstGate.resume()
        let firstResult = await first.value
        XCTAssertEqual(firstResult.acceptedCount, 1)
        XCTAssertTrue(manager.hasPendingMediaImport)
        XCTAssertEqual(manager.desktopGeneration, generation)
        XCTAssertEqual(manager.arrangementRedo.count, 1)
        XCTAssertTrue(manager.redoArrangement())
        secondGate.resume()
        let secondResult = await second.value
        XCTAssertEqual(secondResult.acceptedCount, 1, "An additive import must not invalidate another prepared batch")
        XCTAssertFalse(manager.hasPendingMediaImport)
        XCTAssertEqual(manager.photos.count, 3)
        XCTAssertEqual(manager.windows.count, 3)
        XCTAssertTrue(manager.windows[item.id] === window)
        XCTAssertTrue((manager.windows[item.id]?.contentView as? DraggablePhotoView)?.photoLayer.image === image)
        XCTAssertTrue(manager.rotationTimers[item.id] === timer)
        XCTAssertEqual(manager.spaceImages[item.id], urls)
        XCTAssertTrue(manager.undoArrangement())
        XCTAssertEqual(manager.windows[item.id]?.photoFrame, original)
        XCTAssertEqual(manager.photos.count, 3, "Undo must affect placement without removing either addition")
        let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: root.appendingPathComponent("photos.json")))
        XCTAssertEqual(Set(saved.map(\.id)), Set(manager.photos.map(\.id)))
    }

    @MainActor
    func testAddedPhotosRespectSavedStackOrderWithoutRecreatingExistingWindow() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let original = try XCTUnwrap(manager.photos.first)
            manager.setDepth(original.id, .floating)
            let existing = try XCTUnwrap(manager.windows[original.id])
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let existingWasOnSpace = existing.isOnActiveSpace
            XCTAssertTrue(existingWasOnSpace, "The existing fixture must be on the active Space before Add")
            var lower = PhotoItem(filename: original.filename)
            lower.depth = .floating
            lower.frameString = original.frameString
            lower.stackOrder = original.stackOrder - 1
            var higher = PhotoItem(filename: original.filename)
            higher.depth = .floating
            higher.frameString = original.frameString
            higher.stackOrder = original.stackOrder + 1

            XCTAssertTrue(manager.commitImportedItems([lower, higher], replacing: false))

            XCTAssertTrue(manager.windows[original.id] === existing)
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            // Unlike the all-window inventory, this query promises front-to-back order.
            let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
            let order = rows.compactMap { $0[kCGWindowNumber as String] as? Int }
            let top = try XCTUnwrap(order.firstIndex(of: try XCTUnwrap(manager.windows[higher.id]).windowNumber))
            let middle = try XCTUnwrap(order.firstIndex(of: existing.windowNumber))
            let bottom = try XCTUnwrap(order.firstIndex(of: try XCTUnwrap(manager.windows[lower.id]).windowNumber))
            let context = manager.photos.map { item in
                "stack=\(item.stackOrder), window=\(manager.windows[item.id]?.windowNumber ?? 0), level=\(manager.windows[item.id]?.level.rawValue ?? 0), active=\(manager.windows[item.id]?.isOnActiveSpace == true)"
            }.joined(separator: "; ")
            XCTAssertLessThan(top, middle)
            XCTAssertLessThan(middle, bottom, context)
        }
    }

    @MainActor
    func testAddingCollagesPreservesAppearanceDraftAndForegroundCaption() throws {
        try withTestLibrary { manager in
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let ids = Set(manager.photos.map(\.id))
            let original = manager.arrangementSnapshot(ids: ids)
            let archive = manager.storageDir.appendingPathComponent("sample.arras")
            try manager.exportLayout(to: archive)
            let session = UUID()
            manager.beginCollageAppearancePreview(parent.id, session: session)
            var draft = try XCTUnwrap(parent.desktopCollage)
            draft.gap += 30
            draft.caption = "Unsaved draft"
            manager.previewCollageAppearance(parent.id, session: session, settings: draft)
            manager.collageFlights.values.forEach { $0.currentProgress = 1 }
            (manager.windows[parent.id] as? CollageDesktopWindow)?.transition?.currentProgress = 1
            let preview = manager.arrangementSnapshot(ids: ids)
            let windows = manager.windows
            XCTAssertNotEqual(preview, original)

            XCTAssertEqual(try manager.importLayout(from: archive, mode: .merge), 4)
            XCTAssertNotNil(manager.addDesktopCollage())
            NSApp.updateWindows()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let label = try XCTUnwrap(manager.collageLabelWindows[parent.id])
            let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
            let order = rows.compactMap { $0[kCGWindowNumber as String] as? Int }
            let textIndex = try XCTUnwrap(order.firstIndex(of: label.windowNumber))
            for item in manager.photos where item.desktopCollage == nil {
                let photoIndex = try XCTUnwrap(order.firstIndex(of: try XCTUnwrap(manager.windows[item.id]).windowNumber))
                XCTAssertLessThan(textIndex, photoIndex, "Existing captions must stay above photos after a new backdrop is created")
            }

            XCTAssertEqual(manager.collageAppearanceDrafts[parent.id]?.session, session)
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview)
            for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window) }
            XCTAssertEqual((manager.windows[parent.id] as? CollageDesktopWindow)?.settings.caption, draft.caption)
            let saved = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: manager.storageDir.appendingPathComponent("photos.json")))
            XCTAssertEqual(saved.first { $0.id == parent.id }?.desktopCollage, parent.desktopCollage,
                           "Adding media must not persist an unrelated unfinished appearance draft")
            manager.endCollageAppearancePreview(parent.id, session: session, animated: false)
            XCTAssertEqual(manager.arrangementSnapshot(ids: ids), original)
        }
    }

    @MainActor
    func testAddAndBackupMergePreserveActiveArrangementWindowsAndUndo() async throws {
        for merging in [false, true] {
            for gesture in ["background", "photo", "resize"] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasAddDuringDrag-" + UUID().uuidString)
                let manager = PhotoManager(storageDirectory: root.appendingPathComponent("store"))
                defer {
                    manager.cancelCollageInteractions(endAppearancePreviews: true)
                    manager.rotationTimers.values.forEach { $0.cancel() }
                    manager.windows.values.forEach { $0.hidePhoto() }
                    manager.windows.removeAll()
                    manager.collageLabelWindows.values.forEach { $0.close() }
                    manager.collageLabelWindows.removeAll()
                    try? FileManager.default.removeItem(at: root)
                }
                XCTAssertTrue(manager.addStarterExample(.galleryWall))
                let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
                let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
                let ids = Set(manager.photos.map(\.id))
                let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
                surface.transition?.currentProgress = 1
                let windows = manager.windows
                let label = try XCTUnwrap(manager.collageLabelWindows[parent.id])
                let original = manager.arrangementSnapshot(ids: ids)
                let archive = root.appendingPathComponent("sample.arras")
                if merging { try manager.exportLayout(to: archive) }
                let generation = manager.desktopGeneration
                let photoWindow = try XCTUnwrap(manager.windows[child.id])
                let photoView = try XCTUnwrap(photoWindow.contentView as? DraggablePhotoView)
                let center = CGPoint(x: photoWindow.photoFrame.midX, y: photoWindow.photoFrame.midY)
                let moved = CGPoint(x: center.x + 18, y: center.y + 12)
                switch gesture {
                case "background": manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 30, dy: 20), finished: false)
                case "photo":
                    photoView.mouseDown(with: try testMouseEvent(.leftMouseDown, in: photoWindow, at: center))
                    photoView.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: photoWindow, at: moved, modifiers: .option))
                default:
                    XCTAssertNotNil(manager.beginCollageResize(parent.id))
                    manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
                }
                surface.transition?.currentProgress = 1
                manager.collageFlights.values.forEach { $0.currentProgress = 1 }
                let preview = manager.arrangementSnapshot(ids: ids)
                let labelFrame = label.frame
                let followers = surface.childWindows ?? []
                XCTAssertNotEqual(preview, original)
                XCTAssertTrue(manager.hasActiveArrangementInteraction)

                if merging { XCTAssertEqual(try manager.importLayout(from: archive, mode: .merge), 4) }
                else {
                    let result = await manager.importPhotos(data: [try sampleData()])
                    XCTAssertEqual(result.acceptedCount, 1)
                }

                XCTAssertEqual(manager.desktopGeneration, generation)
                XCTAssertTrue(manager.hasActiveArrangementInteraction, gesture)
                XCTAssertTrue(manager.arrangementUndo.isEmpty, "Adding media must not commit a provisional placement")
                XCTAssertEqual(manager.arrangementSnapshot(ids: ids), preview, gesture)
                for (id, window) in windows { XCTAssertTrue(manager.windows[id] === window, gesture) }
                XCTAssertTrue(manager.collageLabelWindows[parent.id] === label)
                XCTAssertEqual(manager.collageLabelWindows[parent.id]?.frame, labelFrame, "merge=\(merging), \(gesture)")
                XCTAssertEqual((surface.childWindows ?? []).map(\.windowNumber), followers.map(\.windowNumber))
                if merging {
                    let imported = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil && $0.id != parent.id })
                    XCTAssertEqual(manager.collageMembers(imported.id).count, 3)
                    XCTAssertEqual(imported.desktopCollage?.caption, parent.desktopCollage?.caption)
                    XCTAssertNotNil(manager.windows[imported.id])
                    XCTAssertNotNil(manager.collageLabelWindows[imported.id])
                }
                switch gesture {
                case "background": manager.moveCollage(parent.id, to: surface.photoFrame, finished: true)
                case "photo": photoView.mouseUp(with: try testMouseEvent(.leftMouseUp, in: photoWindow, at: moved))
                default: manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: true)
                }
                XCTAssertEqual(manager.arrangementUndo.count, 1, gesture)
                XCTAssertTrue(manager.undoArrangement(), gesture)
                XCTAssertEqual(manager.arrangementSnapshot(ids: ids), original, gesture)
                XCTAssertEqual(manager.photos.count, merging ? 8 : 5)
            }
        }
    }

    @MainActor
    func testUnrelatedReplacementFinishingDuringArrangementPreservesGestureAndUndo() async throws {
        try await exerciseReplacementDuringArrangement(related: false)
    }

    @MainActor
    func testRelatedReplacementFinishingDuringArrangementSkipsWithoutCancellingGesture() async throws {
        try await exerciseReplacementDuringArrangement(related: true)
    }

    @MainActor
    private func exerciseReplacementDuringArrangement(related: Bool) async throws {
        for gesture in ["background", "photo", "resize"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasReplacementDrag-" + UUID().uuidString)
            let manager = PhotoManager(storageDirectory: root.appendingPathComponent("store"))
            defer {
                manager.cancelCollageInteractions(endAppearancePreviews: true)
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                manager.collageLabelWindows.values.forEach { $0.close() }
                manager.collageLabelWindows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            XCTAssertTrue(manager.addStarterExample(.galleryWall))
            let parent = try XCTUnwrap(manager.photos.first { $0.desktopCollage != nil })
            let child = try XCTUnwrap(manager.collageMembers(parent.id).first)
            let ids = Set([parent.id] + manager.collageMembers(parent.id).map(\.id))
            XCTAssertTrue(manager.addStarterExample(.minimal))
            let other = try XCTUnwrap(manager.photos.last)
            let target = related ? child : other
            let surface = try XCTUnwrap(manager.windows[parent.id] as? CollageDesktopWindow)
            surface.transition?.currentProgress = 1
            let initialFrames = Dictionary(uniqueKeysWithValues: ids.compactMap { id in manager.windows[id].map { (id, $0.photoFrame) } })
            let source = root.appendingPathComponent("replacement.png")
            try sampleData().write(to: source)
            let files = Set(try FileManager.default.contentsOfDirectory(atPath: manager.storageDir.path))
            let gate = HeldMediaPreparation(started: expectation(description: "Replacement waits for arrangement"))
            defer { gate.resume() }
            manager.prepareImportedURL = { url, directory in
                gate.wait()
                return PhotoIngest.prepare(contentsOf: url, in: directory)
            }
            let pending = Task { @MainActor in await manager.replacePhoto(target.id, with: source) }
            await fulfillment(of: [gate.started], timeout: 3)
            let photoWindow = try XCTUnwrap(manager.windows[child.id])
            let photoView = try XCTUnwrap(photoWindow.contentView as? DraggablePhotoView)
            let center = CGPoint(x: photoWindow.photoFrame.midX, y: photoWindow.photoFrame.midY)
            let movedPointer = CGPoint(x: center.x + 18, y: center.y + 12)
            switch gesture {
            case "background": manager.moveCollage(parent.id, to: surface.photoFrame.offsetBy(dx: 30, dy: 20), finished: false)
            case "photo":
                photoView.mouseDown(with: try testMouseEvent(.leftMouseDown, in: photoWindow, at: center))
                photoView.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: photoWindow, at: movedPointer, modifiers: .option))
            default:
                XCTAssertNotNil(manager.beginCollageResize(parent.id))
                manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: false)
            }
            let preview = Dictionary(uniqueKeysWithValues: ids.compactMap { id in manager.windows[id].map { (id, $0.photoFrame) } })
            XCTAssertNotEqual(preview, initialFrames, gesture)
            XCTAssertTrue(manager.hasActiveArrangementInteraction)

            gate.resume()
            let result = await pending.value

            XCTAssertEqual(result.acceptedCount, related ? 0 : 1, gesture)
            XCTAssertEqual(result.skippedCount, related ? 1 : 0, gesture)
            XCTAssertTrue(manager.hasActiveArrangementInteraction, gesture)
            XCTAssertTrue(manager.arrangementUndo.isEmpty, "Import completion must not finish the gesture")
            for (id, frame) in preview { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, gesture) }
            if related {
                XCTAssertEqual(manager.photos.first { $0.id == target.id }?.filename, target.filename)
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: manager.storageDir.path)), files)
                XCTAssertFalse(manager.replacePhoto(target.id, with: try XCTUnwrap(NSImage(contentsOf: source))),
                               "Direct image replacement must preserve the same active scene")
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: manager.storageDir.path)), files)
                XCTAssertTrue(manager.hasActiveArrangementInteraction)
            } else { XCTAssertNotEqual(manager.photos.first { $0.id == target.id }?.filename, target.filename) }
            switch gesture {
            case "background": manager.moveCollage(parent.id, to: surface.photoFrame, finished: true)
            case "photo": photoView.mouseUp(with: try testMouseEvent(.leftMouseUp, in: photoWindow, at: movedPointer))
            default: manager.resizeCollage(parent.id, scale: 1.1, corner: .topRight, finished: true)
            }
            XCTAssertEqual(manager.arrangementUndo.count, 1, gesture)
            XCTAssertTrue(manager.undoArrangement(), gesture)
            for (id, frame) in initialFrames { XCTAssertEqual(manager.windows[id]?.photoFrame, frame, gesture) }
            XCTAssertFalse(manager.hasPendingMediaImport)
            if related {
                manager.prepareImportedURL = { url, directory in PhotoIngest.prepare(contentsOf: url, in: directory) }
                let retried = await manager.replacePhoto(target.id, with: source)
                XCTAssertEqual(retried.acceptedCount, 1, "Replacement should work again after the gesture ends")
            }
        }
    }

    private enum Operation: CaseIterable {
        case replace, append, files, clipboard, slideshow, linkedFolder, refreshFolder
    }

    @MainActor
    func testPendingMediaCannotChangeARestoredDesktopWithTheSameWidgetIDs() async throws {
        try await exerciseInterruptedImports(restoringDesktop: true)
    }

    @MainActor
    func testCancelledMediaImportsKeepTheDesktopAndDiscardPreparedFiles() async throws {
        try await exerciseInterruptedImports(restoringDesktop: false)
    }

    @MainActor
    func testOverlappingFailedImportsKeepTheUpdaterBlockedUntilBothFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasOverlappingImports-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "Both imports are preparing")
        started.expectedFulfillmentCount = 2
        let gate = HeldMediaPreparation(started: started)
        defer { gate.resume(); gate.resume() }
        manager.prepareImportedData = { data, directory, name in
            gate.wait()
            return PhotoIngest.prepare(data: data, in: directory, originalName: name)
        }
        let oneFinished = expectation(description: "One failed import finished")
        let run: @MainActor () async -> Void = {
            let result = await manager.importPhotos(data: [Data("invalid image".utf8)])
            XCTAssertEqual(result.failedCount, 1)
            if manager.hasPendingMediaImport { oneFinished.fulfill() }
        }
        let first = Task { await run() }
        let second = Task { await run() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(manager.hasPendingMediaImport)
        gate.resume()
        await fulfillment(of: [oneFinished], timeout: 3)
        XCTAssertTrue(manager.hasPendingMediaImport, "Finishing one import must not clear another's scope")
        gate.resume()
        await first.value
        await second.value
        XCTAssertFalse(manager.hasPendingMediaImport)
        XCTAssertTrue(manager.photos.isEmpty)
    }

    @MainActor
    func testReplacementRejectsChangedMediaButPreservesLaterAppearanceEdits() async throws {
        for change in ["next slide", "new replacement", "appearance"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasReplacementLifecycle-" + UUID().uuidString)
            let storage = root.appendingPathComponent("store")
            let manager = PhotoManager(storageDirectory: storage)
            defer {
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            XCTAssertTrue(manager.addStarterExample(change == "next slide" ? .rotatingSpace : .minimal,
                                                    makeVisible: change == "next slide"))
            let original = try XCTUnwrap(manager.photos.first)
            let data = try sampleData()
            let source = root.appendingPathComponent("pending.png")
            try data.write(to: source)
            let gate = HeldMediaPreparation(started: expectation(description: "Replacement preparation started"))
            defer { gate.resume() }
            manager.prepareImportedURL = { url, directory in
                gate.wait()
                return PhotoIngest.prepare(contentsOf: url, in: directory)
            }
            let pending = Task { @MainActor in await manager.replacePhoto(original.id, with: source) }
            await fulfillment(of: [gate.started], timeout: 3)
            if change == "next slide" {
                manager.nextFolderImage(original.id)
                XCTAssertNotEqual(manager.photos[0].folderImageIndex, original.folderImageIndex)
            } else if change == "new replacement" {
                XCTAssertTrue(manager.replacePhoto(original.id, with: try XCTUnwrap(NSImage(data: data))))
                XCTAssertNotEqual(manager.photos[0].filename, original.filename)
            } else {
                manager.renamePhoto(original.id, to: "Later name")
                manager.setMat(original.id, width: 17, colorHex: "#FFFFFF")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let changed = try encoder.encode(manager.photos)
            let files = Set(try FileManager.default.contentsOfDirectory(atPath: storage.path))
            gate.resume()
            let result = await pending.value
            if change == "appearance" {
                XCTAssertEqual(result.acceptedCount, 1)
                XCTAssertEqual(manager.photos[0].customName, "Later name")
                XCTAssertEqual(manager.photos[0].matWidth, 17)
            } else {
                XCTAssertEqual(result.acceptedCount, 0, change)
                XCTAssertEqual(try encoder.encode(manager.photos), changed, change)
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: storage.path)), files, change)
            }
        }
    }

    @MainActor
    private func exerciseInterruptedImports(restoringDesktop: Bool) async throws {
        for operation in Operation.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasImportLifecycle-" + UUID().uuidString)
            let storage = root.appendingPathComponent("store")
            let folder = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manager = PhotoManager(storageDirectory: storage)
            defer {
                manager.stopAllLiveFolderWatchers()
                manager.rotationTimers.values.forEach { $0.cancel() }
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
                try? FileManager.default.removeItem(at: root)
            }
            let data = try sampleData()
            if operation == .refreshFolder {
                try data.write(to: folder.appendingPathComponent("first.png"))
                let added = await manager.addLiveFolderSpace(folder, requiresSecurityScope: false)
                XCTAssertEqual(added.acceptedCount, 1)
                manager.stopAllLiveFolderWatchers()
                manager.photos[0].isVisible = false
                manager.windows.values.forEach { $0.hidePhoto() }
                manager.windows.removeAll()
            } else {
                XCTAssertTrue(manager.addStarterExample(.rotatingSpace, makeVisible: false))
            }
            manager.photos[0].customName = "Saved desktop"
            XCTAssertTrue(manager.persist())
            let id = try XCTUnwrap(manager.photos.first?.id)
            let setup = try manager.saveDesktopSetup(named: "Restore during import")
            let source = folder.appendingPathComponent("pending.png")
            try data.write(to: source)
            let gate = HeldMediaPreparation(started: expectation(description: "\(operation) preparation started"))
            defer { gate.resume() }
            manager.prepareImportedURL = { url, directory in
                gate.wait()
                return PhotoIngest.prepare(contentsOf: url, in: directory)
            }
            manager.prepareImportedData = { bytes, directory, name in
                gate.wait()
                return PhotoIngest.prepare(data: bytes, in: directory, originalName: name)
            }
            let pending = Task { @MainActor in
                switch operation {
                case .replace: return await manager.replacePhoto(id, with: source)
                case .append: return await manager.appendPhotosToSpace(id, urls: [source])
                case .files: return await manager.importPhotos(urls: [source])
                case .clipboard: return await manager.importPhotos(data: [data], sourceNames: ["Pending clipboard"])
                case .slideshow: return await manager.addSpace(urls: [source])
                case .linkedFolder: return await manager.addLiveFolderSpace(folder, requiresSecurityScope: false)
                case .refreshFolder: return await manager.reconcileLiveFolder(id, folderURL: folder, requiresSecurityScope: false)
                }
            }
            await fulfillment(of: [gate.started], timeout: 3)
            XCTAssertTrue(manager.hasPendingMediaImport)
            if restoringDesktop {
                try manager.activateDesktopSetup(setup)
            } else {
                pending.cancel()
            }
            manager.stopAllLiveFolderWatchers()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let restored = try encoder.encode(manager.photos)
            let files = Set(try FileManager.default.contentsOfDirectory(atPath: storage.path))
            gate.resume()
            let result = await pending.value
            XCTAssertFalse(manager.hasPendingMediaImport, "\(operation) did not release its import scope")
            XCTAssertEqual(result.acceptedCount, 0, "\(operation) must not commit after interruption")
            XCTAssertEqual(try encoder.encode(manager.photos), restored, "\(operation) changed the desktop")
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: storage.path)), files,
                           "\(operation) left staged media behind")
        }
    }

    @MainActor
    private func sampleData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
