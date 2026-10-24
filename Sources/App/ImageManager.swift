import AppKit
import SwiftUI
import ServiceManagement
import QuickLookUI
import ImageIO

private final class StoredMediaPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

private final class StoredMediaPreviewDataSource: NSObject, QLPreviewPanelDataSource {
    let item: StoredMediaPreviewItem

    init(item: StoredMediaPreviewItem) {
        self.item = item
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        item
    }
}

/// Manages multiple desktop photos, persistence, and settings.
@MainActor
class PhotoManager: ObservableObject {
    @Published var photos: [PhotoItem] = []
    /// Selection belongs to the Photos settings UI rather than to a widget's durable model.
    /// The anchor gives Shift-click the same contiguous-range behaviour as a native list.
    @Published var selectedPhotoIDs: Set<UUID> = []
    @Published var arrangementUndo: [ArrangementChange] = []
    @Published var arrangementRedo: [ArrangementChange] = []
    @Published var collageEditorID: UUID?
    var collageDrags: [UUID: CollageDrag] = [:]
    var collageFlights: [UUID: CollageTransition] = [:]
    var collageMoveSnapshots: [UUID: CollageMoveSnapshot] = [:]
    var collageResizeSnapshots: [UUID: CollageResizeSnapshot] = [:]
    var collageAppearanceDrafts: [UUID: CollageAppearanceDraft] = [:]
    var collageLabelWindows: [UUID: CollageLabelWindow] = [:]
    @Published var launchAtLogin: Bool = false

    // Presence & Privacy: mirrors of PresenceMonitor's toggles/detected state for
    // the Settings UI. Always go through the setX methods below rather than assigning
    // these directly -- PresenceMonitor owns the real (UserDefaults-backed) state, and
    // these are just a read mirror kept in sync via `syncPresenceState()`.
    @Published var excludeFromScreenCapture: Bool = false
    @Published var autoHideForConferencingApps: Bool = false
    @Published var hideWhenFullscreenActive: Bool = false
    @Published var isConferencingAppDetected: Bool = false
    @Published var isFullscreenAppDetected: Bool = false

    /// Not private: PhotoAppearanceControls.swift lives in another file and needs the same
    /// authoritative lookup. Scanning `NSApp.windows` can find a closed panel still
    /// retained by AppKit or a caller instead of the current replacement. Closing
    /// does not invalidate those references; appearance edits must use this registry.
    var windows: [UUID: DesktopPhotoWindow] = [:]

    // Spaces (Internal rotation timers)
    var spaceImages: [UUID: [URL]] = [:]
    var rotationTimers: [UUID: DispatchSourceTimer] = [:]

    /// Stops and forgets one slideshow timer. Kept as a narrow internal operation so
    /// transactional helpers in other source files never need access to the timer registry.
    func cancelRotationTimer(for id: UUID) {
        rotationTimers[id]?.cancel()
        rotationTimers.removeValue(forKey: id)
    }
    /// The shared Quick Look panel keeps its data source weak; retain the current source while
    /// the panel is open so a preview remains valid after the click-action closure returns.
    private var quickLookDataSource: StoredMediaPreviewDataSource?
    var selectionAnchorID: UUID?
    @Published var copiedAppearanceStyle: WidgetAppearanceStyle?
    /// Bulk duplicate uses the existing single-item path, but turns its per-item saves into
    /// one transaction so a partial selection cannot leave a half-written layout on disk.
    var persistenceSuppressed = false
#if !ARRAS_APP_STORE
    var onTelemetryFactsChanged: ((TelemetryFacts) -> Void)?
    var lastTelemetryFacts: TelemetryFacts?
#endif
    private(set) var settingsWindowIsActive = false

    func setSettingsWindowActive(_ active: Bool) {
        guard settingsWindowIsActive != active else { return }
        settingsWindowIsActive = active
        for window in windows.values { window.setSettingsWindowActive(active) }
        restoreCollageOrdering()
        // Activation finishes ordering panels after this callback returns.
        // Repair once more on the next turn, using their current window IDs.
        // Read current state so a rapid Settings open/close cannot restore an
        // obsolete depth or bring a hidden collage back.
        DispatchQueue.main.async { [weak self] in self?.restoreCollageOrdering() }
    }

    /// Photos library observation is runtime-only. Collection and asset identities live on the
    /// PhotoItem model; this reference only keeps the public PhotoKit observer alive.
    var photosLibraryObserver: PhotosLibraryObserver?
    /// Restoring a desktop invalidates work started against the previous arrangement,
    /// including restores that reuse the same widget IDs and source metadata.
    var desktopGeneration = UUID()
    private var mediaImportCount = 0
    var hasPendingMediaImport: Bool { mediaImportCount > 0 }

    // Each async import owns one scope, balanced by defer even on failure or cancellation.
    func beginMediaImport() { mediaImportCount += 1 }
    func endMediaImport() { mediaImportCount -= 1 }

    /// Preparation runs off the main actor; each import captures its worker before suspending.
    var prepareImportedURL: @Sendable (URL, URL) -> PhotoIngest.Prepared? = {
        PhotoIngest.prepare(contentsOf: $0, in: $1)
    }
    var prepareImportedData: @Sendable (Data, URL, String?) -> PhotoIngest.Prepared? = {
        PhotoIngest.prepare(data: $0, in: $1, originalName: $2)
    }
    @Published var removedWidgetCount = 0
    @Published var photosLibrarySyncState: PhotosLibrarySyncState = .idle

    /// Small first-frame/poster thumbnails keyed by filename, size and reference edits.
    /// Bounded independently of the number of photos or saved setups visited.
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    // Presence & Privacy
    private let presence = PresenceMonitor()
    private let runtimeActivity = RuntimeActivityCenter.shared
    private let storageDirectoryOverride: URL?
    @Published private(set) var libraryRecoveryRequired = false
    private var didPreserveCorruptStore = false
    private static let maxCorruptStoreCopies = 5

    var storageDir: URL {
        if let storageDirectoryOverride {
            try? FileManager.default.createDirectory(at: storageDirectoryOverride, withIntermediateDirectories: true)
            return storageDirectoryOverride
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("PhotoWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether this launch has already looked for data left in the sandbox
    /// container. Checked once rather than on every `storageDir` access.
    private static var didMigrateStorage = false

    private var dataFile: URL { storageDir.appendingPathComponent("photos.json") }

    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["ARRAS_UNIT_TESTING"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Explicit test/demo stores retain priority. Either test launch mode must
    /// stay outside the personal library even when its harness omits a path.
    static func resolveStorageDirectory(explicitDirectory: URL?, uiTestPath: String?,
                                        unitTesting: Bool, uiTesting: Bool,
                                        temporaryDirectory: URL, processIdentifier: Int32) -> URL? {
        if let explicitDirectory { return explicitDirectory }
        if let uiTestPath, !uiTestPath.isEmpty { return URL(fileURLWithPath: uiTestPath, isDirectory: true) }
        guard unitTesting || uiTesting else { return nil }
        let host = unitTesting ? "ArrasUnitHost" : "ArrasUITestHost"
        return temporaryDirectory.appendingPathComponent("\(host)-\(processIdentifier)", isDirectory: true)
    }

    init(storageDirectory: URL? = nil) {
        // Hosted XCTest loads AppDelegate too. Default test managers must never
        // open the real store; explicit per-test/demo directories retain priority.
        storageDirectoryOverride = Self.resolveStorageDirectory(
            explicitDirectory: storageDirectory,
            uiTestPath: ProcessInfo.processInfo.environment["ARRAS_UI_TEST_STORAGE_DIR"],
            unitTesting: Self.isUnitTestHost,
            uiTesting: ProcessInfo.processInfo.arguments.contains("--ui-testing"),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier)

        // Must run before anything reads photos.json: dropping the sandbox moved
        // the Application Support directory, and this carries older installs across.
#if !ARRAS_APP_STORE
        if storageDirectoryOverride == nil, !Self.didMigrateStorage {
            Self.didMigrateStorage = true
            StorageMigration.migrateIfNeeded(to: storageDir)
        }
#endif

        launchAtLogin = SMAppService.mainApp.status == .enabled
        removedWidgetCount = (try? DesktopSetupLibrary.read(in: storageDir).removed?.photos.count) ?? 0

        // Listen for window moves
        NotificationCenter.default.addObserver(
            forName: .desktopPhotoMoved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? DesktopPhotoWindow,
                  let id = window.photoId else { return }
            Task { @MainActor [weak self] in
                self?.saveWindowPosition(for: id, frame: window.photoFrame)
            }
        }

        // Save on quit.
        //
        // This must run synchronously. Hopping through `Task { }` here schedules
        // work on the next main-queue turn, which never arrives — the process is
        // already tearing down, so the save silently never happened. The
        // notification is delivered on the main queue, so we are already on the
        // main actor and can just assert it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelCollageInteractions(endAppearancePreviews: true)
                self?.saveAllPositions()
                self?.persist()
            }
        }

        // Per-Display Profiles: hide/restore photos as monitors connect/disconnect
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        // Presence & Privacy: pick up PresenceMonitor's already-computed initial
        // state (no persist side effects -- see mirrorPresenceState()) and start reacting
        // to future changes. Registered after the initial mirror, and before loadSaved(),
        // so no callback can fire mid-construction: PresenceMonitor's own init() runs its
        // detection synchronously with onChange still nil, and NSWorkspace notifications
        // are always asynchronous, so nothing arrives until well after this initializer --
        // and therefore after loadSaved() below -- returns.
        mirrorPresenceState()
        runtimeActivity.setPresenceSuppressed(presence.shouldSuppressForPresence)
        presence.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.syncPresenceState() }
        }

        // Load saved photos immediately
        loadSaved()
        // Live-folder watchers are runtime-only and are rebuilt from the persisted source
        // metadata after the model and windows have been restored.
        installLiveFolderWatchers()
    }

    // MARK: - Persistence

    func loadSaved() {
        guard FileManager.default.fileExists(atPath: dataFile.path) else { return }

        do {
            let data = try Data(contentsOf: dataFile)
            do {
                let items = try JSONDecoder().decode([PhotoItem].self, from: data)
                guard Set(items.map(\.id)).count == items.count else {
                    throw NSError(domain: "ArrasPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: "Duplicate widget IDs in the saved layout."])
                }
                libraryRecoveryRequired = false
                installLoadedItems(items)
            } catch {
                libraryRecoveryRequired = true
                let preserved = preserveCorruptStore(data: data)
                var detail = "The existing photos.json could not be decoded: \(error.localizedDescription)."
                if let preserved {
                    detail += " A copy was preserved at \(preserved.path)."
                }
                logPersistenceFailure(detail)
            }
        } catch {
            libraryRecoveryRequired = true
            let preserved = preserveCorruptStore()
            var detail = "The existing photos.json could not be read: \(error.localizedDescription)."
            if let preserved {
                detail += " A copy was preserved at \(preserved.path)."
            }
            logPersistenceFailure(detail)
        }
    }

    /// Replaces the desktop's runtime ownership after a full load or replacement.
    /// Additive imports activate only their new items, preserving the existing desktop.
    private func installLoadedItems(_ items: [PhotoItem]) {
        arrangementUndo.removeAll()
        arrangementRedo.removeAll()
        desktopGeneration = UUID()
        photosLibraryObserver?.cancelPendingSync()
        stopAllLiveFolderWatchers()
        cancelCollageInteractions(endAppearancePreviews: true)
        for window in windows.values { window.hidePhoto() }
        windows.removeAll()
        for window in collageLabelWindows.values { window.close() }
        collageLabelWindows.removeAll()
        CollageFontLibrary.load(in: storageDir)
        for timer in rotationTimers.values { timer.cancel() }
        rotationTimers.removeAll()
        spaceImages.removeAll()

        photos = items.filter { !$0.isRetiredCompositionContainer }
        activateLoadedItems()
        reportMissingStoredMedia(in: items)
    }

    /// Uses the same restoration rules for a full library and newly imported items. A merge
    /// must not normalize or recreate unrelated live previews, windows, timers or watchers.
    private func activateLoadedItems(only ids: Set<UUID>? = nil) {
        reconcileDisplayPresence(connected: Set(NSScreen.screens.map(DisplayManager.identifier(for:))), only: ids)
        // Older saves included manually hidden children in the backdrop bounds.
        // Refit before screen recovery so those invisible extents cannot move the group.
        for parent in photos where parent.desktopCollage != nil && ids?.contains(parent.id) != false {
            if collageMembers(parent.id).contains(where: { !$0.isVisible }) { fitCollageModel(parent.id) }
        }
        restoreCollageFramesToVisibleScreens(only: ids)
        normalizePhotoSelection()
        let collageIDs = Set(photos.filter { $0.desktopCollage != nil }.map(\.id))
        for i in photos.indices where photos[i].collageParentID != nil && ids?.contains(photos[i].id) != false {
            if !collageIDs.contains(photos[i].collageParentID!) || photos[i].desktopCollage != nil || photos[i].collageParentID == photos[i].id { photos[i].collageParentID = nil }
        }

        // Presence suppression (fullscreen / conferencing) depends on which apps happen to be
        // running right now, neither of which survives a relaunch, so it's recomputed fresh here
        // rather than trusting whatever was persisted last session.
        for index in photos.indices where ids?.contains(photos[index].id) != false {
            photos[index].isHiddenForPresence = isSuppressedForPresence(photos[index])
        }

        // Display suppression was reconciled against the screens present at launch.
        // User visibility remains independent of automatic display/presence suppression.
        // Ascending stackOrder: each orderFront puts the next one nearer the front, so the
        // saved front-to-back arrangement is rebuilt exactly.
        let ordered = photos
            .filter { ids?.contains($0.id) != false && $0.isVisible && !$0.isHiddenForDisplay && !$0.isHiddenForPresence }
            .sorted { $0.stackOrder < $1.stackOrder }
        var failedMedia = 0
        for item in ordered where windows[item.id] == nil && collageAllowsWindow(item) {
            guard let content = loadDisplayContent(for: item) else {
                failedMedia += 1
                continue
            }
            createWindow(for: item, content: content)
            if !item.spaceImageFilenames.isEmpty {
                setupRotationTimer(for: item)
            }
        }

        if failedMedia > 0 {
            recordMediaImportFailure(
                "\(failedMedia) saved widget\(failedMedia == 1 ? "" : "s") could not decode its stored image."
            )
        }
        let parentIDs = ids.map { added in
            Set(photos.filter { added.contains($0.id) }.compactMap { $0.desktopCollage != nil ? $0.id : $0.collageParentID })
        }
        syncCollages(only: parentIDs)
        if let ids { orderAddedPhotoWindows(ids) }
        installLiveFolderWatchers(only: ids)
        // A saved setup or removal recovery can introduce the first linked Photos widget
        // after startup. The installer checks existing permission and registers only once.
        installPhotosLibraryObserver()
    }

    /// Imports and removal recovery share additive runtime restoration after their model save.
    /// Callers own rollback; this never replaces existing window or import ownership.
    func activateCommittedAdditions(_ items: [PhotoItem]) {
        activateLoadedItems(only: Set(items.map(\.id)))
        reportMissingStoredMedia(in: items)
    }

    /// Insert new photos into the saved stack without ordering existing panels onto this Space.
    /// Captions retain their foreground position; active photo drags keep their priority.
    private func orderAddedPhotoWindows(_ ids: Set<UUID>) {
        let levels = Set(ids.compactMap { windows[$0]?.level })
        for level in levels {
            let visible = photos.filter {
                $0.desktopCollage == nil && windows[$0.id]?.level == level
                    && windows[$0.id]?.isVisible == true && windows[$0.id]?.isOnActiveSpace == true
            }.sorted { $0.stackOrder < $1.stackOrder }
            let ordered = visible.filter { collageDrags[$0.id] == nil } + visible.filter { collageDrags[$0.id] != nil }
            for index in ordered.indices.reversed() where ids.contains(ordered[index].id) {
                if index + 1 < ordered.count, let higher = windows[ordered[index + 1].id] {
                    windows[ordered[index].id]?.order(.below, relativeTo: higher.windowNumber)
                } else { windows[ordered[index].id]?.orderFront(nil) }
            }
            orderCollageLabels(at: level)
        }
    }

    private func reportMissingStoredMedia(in items: [PhotoItem]) {
        let missing = items
            .flatMap { storedFilenames(in: $0) }
            .filter { !FileManager.default.fileExists(atPath: storageDir.appendingPathComponent($0).path) }
        guard !missing.isEmpty else { return }
            recordMediaImportFailure(
                "\(missing.count) stored media file\(missing.count == 1 ? "" : "s") is missing from the photo library."
            )
    }

    func storedFilenames(in item: PhotoItem) -> [String] { Self.managedFilenames(in: item) }

    nonisolated static func managedFilenames(in item: PhotoItem) -> [String] {
        var names: [String] = []
        if !item.filename.isEmpty { names.append(item.filename) }
        if let poster = item.media.posterFilename, !poster.isEmpty { names.append(poster) }
        if let paired = item.media.pairedVideoFilename, !paired.isEmpty { names.append(paired) }
        names.append(contentsOf: item.spaceImageFilenames)
        names.append(contentsOf: item.liveFolderEntries.map(\.managedFilename))
        names.append(contentsOf: item.photosLibraryAssets.flatMap(\.managedFilenames))
        return names
    }

    /// Resolves what is currently due to be shown for `item` (single photo or the active
    /// frame of a Space), registering Space image URLs as a side effect. Shared by every path
    /// that brings a hidden photo back on screen: manual visibility toggle, load-on-launch, and
    /// display reconnect.
    ///
    /// Returns `PhotoContent` rather than `NSImage` so an animated widget keeps animating
    /// through all three of those paths, not just the initial add.
    func loadDisplayContent(for item: PhotoItem) -> PhotoContent? {
        if item.desktopCollage != nil { return .still(NSImage(size: CollageGeometry.emptySize)) }
        if !item.spaceImageFilenames.isEmpty {
            let urls = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            spaceImages[item.id] = urls
            if let imageURL = urls[safe: item.folderImageIndex],
               let content = loadMediaContent(for: item, filename: imageURL.lastPathComponent, primaryURL: imageURL) {
                return content
            }
            return urls.first.flatMap { loadMediaContent(for: item, filename: $0.lastPathComponent, primaryURL: $0) }
        } else {
            return loadMediaContent(for: item, primaryURL: storageDir.appendingPathComponent(item.filename))
        }
    }

    func loadMediaContent(for item: PhotoItem, primaryURL: URL) -> PhotoContent? {
        loadMediaContent(for: item, filename: primaryURL.lastPathComponent, primaryURL: primaryURL)
    }

    func loadMediaContent(for item: PhotoItem, filename: String, primaryURL: URL) -> PhotoContent? {
        let media = item.photosLibraryAssets.first(where: { $0.managedFilename == filename })?.media
            ?? (item.filename == filename ? item.media : .still)
        let posterURL = media.posterFilename.map { storageDir.appendingPathComponent($0) }
        let pairedVideoURL = media.pairedVideoFilename.map { storageDir.appendingPathComponent($0) }
        if media.kind == .livePhoto {
            guard let pairedVideoURL else { return nil }
            return PhotoContent.load(from: primaryURL, posterURL: posterURL, pairedVideoURL: pairedVideoURL)
        }
        return PhotoContent.load(from: primaryURL, posterURL: posterURL, pairedVideoURL: nil)
    }

    /// Not private, for the same reason `windows` isn't — PhotoAppearanceControls.swift used
    /// to carry a byte-for-byte copy of this, which made two independent writers to the same
    /// file and a lost-update waiting to happen.
    @discardableResult
    func persist() -> Bool {
        persist(recoveringDamagedLibrary: false)
    }

    /// Only the explicitly confirmed backup-recovery path may replace an unreadable store.
    private func persist(recoveringDamagedLibrary: Bool) -> Bool {
        if persistenceSuppressed { return true }
        guard Set(photos.map(\.id)).count == photos.count else {
            logPersistenceFailure("The current layout contains duplicate widget IDs; it was not saved.")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(photos)
        } catch {
            logPersistenceFailure("The current photo layout could not be encoded: \(error.localizedDescription).")
            return false
        }

        // Ordinary edits cannot erase an unreadable store. Explicit backup recovery
        // preserves its latest bytes before the atomic replacement below.
        if libraryRecoveryRequired && !recoveringDamagedLibrary {
            logPersistenceFailure("The existing photos.json was not overwritten because it is unreadable.")
            return false
        }

        let fileManager = FileManager.default
        let currentExists = fileManager.fileExists(atPath: dataFile.path)
        if currentExists {
            let current: Data
            do {
                current = try Data(contentsOf: dataFile)
            } catch {
                libraryRecoveryRequired = true
                let preserved = preserveCorruptStore()
                var detail = "The existing photos.json could not be read before saving: \(error.localizedDescription)."
                if let preserved { detail += " A copy was preserved at \(preserved.path)." }
                logPersistenceFailure(detail)
                return false
            }

            // Validate the previous bytes before replacing them. If another process or a manual
            // edit damaged the file, preserve it and refuse to overwrite it.
            do {
                if recoveringDamagedLibrary {
                    if let repaired = try? JSONDecoder().decode([PhotoItem].self, from: current),
                       Set(repaired.map(\.id)).count == repaired.count {
                        logPersistenceFailure("The library was repaired after recovery began. Reopen Arras before replacing it.")
                        return false
                    }
                    // Preserve the bytes present at commit time, even if another process
                    // changed the damaged file after startup or archive preflight.
                    guard preserveCorruptStore(data: current, force: true) != nil else {
                        logPersistenceFailure("The damaged library could not be preserved; recovery was not applied.")
                        return false
                    }
                } else {
                    _ = try JSONDecoder().decode([PhotoItem].self, from: current)
                }
            } catch {
                libraryRecoveryRequired = true
                let preserved = preserveCorruptStore(data: current)
                var detail = "The existing photos.json could not be decoded before saving: \(error.localizedDescription)."
                if let preserved { detail += " A copy was preserved at \(preserved.path)." }
                logPersistenceFailure(detail)
                return false
            }
        }

        do {
            try fileManager.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try data.write(to: dataFile, options: .atomic)
            libraryRecoveryRequired = false
#if !ARRAS_APP_STORE
            if let onTelemetryFactsChanged {
                let facts = telemetryFacts
                if facts != lastTelemetryFacts {
                    lastTelemetryFacts = facts
                    onTelemetryFactsChanged(facts)
                }
            }
#endif
            return true
        } catch {
            // `.atomic` leaves the previous file in place when its replacement fails, so a
            // transient write error never destroys the last known-good JSON.
            logPersistenceFailure("The photo layout could not be saved: \(error.localizedDescription).")
            return false
        }
    }

    private var corruptStoreDirectory: URL {
        storageDir.appendingPathComponent("photos-corrupt", isDirectory: true)
    }

    /// Keeps the damaged bytes under a unique name. Copying the original file is preferred so
    /// even a decode/read failure that is not representable as `Data` can be diagnosed later.
    private func preserveCorruptStore(data: Data? = nil, force: Bool = false) -> URL? {
        if didPreserveCorruptStore && !force {
            return (try? FileManager.default.contentsOfDirectory(at: corruptStoreDirectory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .last
        }
        guard FileManager.default.fileExists(atPath: dataFile.path) || data != nil else { return nil }

        do {
            try FileManager.default.createDirectory(at: corruptStoreDirectory, withIntermediateDirectories: true)
            let url = corruptStoreDirectory.appendingPathComponent(
                "photos-corrupt-\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString).json"
            )
            if let data {
                try data.write(to: url, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: dataFile, to: url)
            }
            didPreserveCorruptStore = true
            pruneCorruptStoreCopies()
            return url
        } catch {
            return nil
        }
    }

    private func creationDate(for url: URL) -> Date {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
              let date = values.creationDate else {
            return .distantPast
        }
        return date
    }

    private func pruneCorruptStoreCopies() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: corruptStoreDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = creationDate(for: lhs)
            let right = creationDate(for: rhs)
            if left == right { return lhs.lastPathComponent > rhs.lastPathComponent }
            return left > right
        } ?? []
        for url in urls.dropFirst(Self.maxCorruptStoreCopies) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Returns the filenames referenced by the durable current store. If the store cannot be
    /// decoded, media deletion stops conservatively rather than risking data loss.
    private func currentStoredFilenames() -> Set<String>? {
        guard let setups = try? DesktopSetupLibrary.read(in: storageDir) else { return nil }
        let retained = Set(setups.retainedPhotos.flatMap { storedFilenames(in: $0) })
        guard FileManager.default.fileExists(atPath: dataFile.path) else { return retained }
        guard let data = try? Data(contentsOf: dataFile),
              let items = try? JSONDecoder().decode([PhotoItem].self, from: data) else {
            return nil
        }
        return retained.union(items.flatMap { storedFilenames(in: $0) })
    }

    func recordMediaImportFailure(_ detail: String) {
        logPersistenceFailure(detail)
    }

    private func logPersistenceFailure(_ detail: String) {
        NSLog("Arras persistence: %@", detail)
    }

    private func saveAllPositions() {
        for (id, window) in windows {
            saveWindowPosition(for: id, frame: window.photoFrame)
        }
    }

    /// `frame` is always the *photo* rect, never the window frame — the window is larger by
    /// however much room the shadow and tilt need (see `PhotoCanvas`), and persisting that
    /// would grow every widget a little on each launch.
    private func saveWindowPosition(for id: UUID, frame: NSRect) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].frameString = NSStringFromRect(frame)
        photos[index].widgetWidth = frame.width

        if let parent = photos[index].collageParentID {
            fitCollageModel(parent)
            fitCollageWindow(parent)
        }

        // Per-Display Profiles: whichever screen the window's center currently sits on becomes
        // its "home" display, and we remember the exact frame for that display independently
        // so restoring after a disconnect/reconnect doesn't depend on the (possibly stale)
        // top-level frameString if the photo was later moved to a different monitor.
        if let screen = windows[id]?.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            let displayId = DisplayManager.identifier(for: screen)
            photos[index].displayIdentifier = displayId
            photos[index].savedDisplayFrames[displayId] = NSStringFromRect(frame)
        }

        // Also save per-image config for space photos if in dynamic mode
        if !photos[index].spaceImageFilenames.isEmpty,
           photos[index].folderSizeMode == "dynamic",
           let images = spaceImages[id] {
            let currentImage = images[safe: photos[index].folderImageIndex]
            if let key = currentImage?.lastPathComponent {
                photos[index].folderImageConfigs[key] = FolderImageConfig(
                    frameString: NSStringFromRect(frame),
                    widgetWidth: frame.width
                )
            }
        }

        persist()
    }

    // MARK: - Add / Remove

    /// Saves `image` to the photo store, preserving animation when present.
    ///
    /// Animated GIFs/APNGs are detected via `AnimatedImageIO.extractFrames`
    /// and re-encoded to a standalone `.gif` (see AnimatedImage.swift for
    /// why re-muxing to GIF is the right call for those). Alpha-bearing stills
    /// are stored as PNG; opaque stills keep the app's JPEG storage behavior so
    /// ordinary photo size and quality do not regress.
    private func saveImportedImage(_ image: NSImage) -> (filename: String, url: URL)? {
        if let frames = AnimatedImageIO.extractFrames(from: image) {
            let filename = UUID().uuidString + ".gif"
            let url = storageDir.appendingPathComponent(filename)
            if AnimatedImageIO.writeGIF(frames, to: url) {
                return (filename, url)
            }
            // Encoding failed for some reason (disk full, etc.) -- fall
            // through and try to save a still instead rather than losing
            // the import entirely.
        }

        guard let encoded = Self.encodeImportedStill(image) else {
            recordMediaImportFailure("The selected image could not be decoded.")
            return nil
        }
        let filename = UUID().uuidString + "." + encoded.fileExtension
        let url = storageDir.appendingPathComponent(filename)
        do {
            try encoded.data.write(to: url)
            return (filename, url)
        } catch {
            recordMediaImportFailure("The selected image could not be stored: \(error.localizedDescription).")
            return nil
        }
    }

    /// Encodes an alpha-bearing still without flattening it. Kept internal so unit tests can
    /// exercise the NSImage-based import path without constructing windows or a full manager.
    static func encodeImportedStill(_ image: NSImage) -> (data: Data, fileExtension: String)? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        guard let cgImage = bitmapRep.cgImage else { return nil }
        let hasAlpha = cgImage.hasAlphaChannel
        let format: NSBitmapImageRep.FileType = hasAlpha ? .png : .jpeg
        let properties: [NSBitmapImageRep.PropertyKey: Any] = hasAlpha
            ? [:]
            : [.compressionFactor: 0.9]
        guard let data = bitmapRep.representation(using: format, properties: properties) else {
            return nil
        }
        return (data, hasAlpha ? "png" : "jpg")
    }

    func addPhoto(_ image: NSImage) {
        guard let (filename, url) = saveImportedImage(image) else {
            // `saveImportedImage` records the detailed conversion/write error where it has
            // context. Keep this guard explicit so every NSImage-based importer follows the
            // same failure path without creating a partial PhotoItem.
            return
        }

        // Validate the staged bytes before exposing a model item or window. This keeps the
        // synchronous NSImage entry point aligned with the batched importer: a successful write
        // alone is not enough to claim that an image can be rendered after relaunch.
        guard let content = PhotoContent.load(from: url) else {
            recordMediaImportFailure("The imported image could not be decoded after it was stored.")
            removeStoredFileIfUnreferenced(filename)
            return
        }

        var item = PhotoItem(filename: filename)
        if case .animated = content {
            item.media = PhotoMedia(kind: .animatedImage)
        }
        // This API receives an NSImage rather than source bytes, and its storage path re-encodes
        // the image. Keep that distinction visible to archival exports instead of implying the
        // original file is still available.
        item.mediaFidelity[filename] = .transformed
        photos.append(item)
        guard persist() else {
            // The model write is the commit point. If it fails, remove the window and restore
            // the in-memory array so this API cannot show a widget that disappears on relaunch.
            // If the existing store is corrupt, removeStoredFileIfUnreferenced conservatively
            // keeps the staged bytes for diagnosis because it cannot prove the durable references.
            photos.removeLast()
            windows[item.id]?.hidePhoto()
            windows.removeValue(forKey: item.id)
            removeStoredFileIfUnreferenced(filename)
            return
        }
        createWindow(for: item, content: content)
    }

    /// Removes one stored media file only when no other widget still points at it. Space
    /// duplication intentionally shares its filenames, so deletion must inspect both the
    /// single-image field and every Space slot before touching the bytes on disk.
    // Live-folder and Photos reconciliation commit model changes from their own source files,
    // then use this same durable-reference check before releasing superseded managed media.
    func removeStoredFileIfUnreferenced(_ filename: String, excluding id: UUID? = nil, spaceSlotIndex: Int? = nil) {
        guard !filename.isEmpty else { return }
        let stillReferenced = photos.contains { candidate in
            if candidate.id == id, let spaceSlotIndex {
                // Replacement changes one slot in-place. Count every other slot in that same
                // item, including a duplicate filename, plus the legacy primary filename.
                if candidate.filename == filename { return true }
                return candidate.spaceImageFilenames.enumerated().contains { index, name in
                    index != spaceSlotIndex && name == filename
                }
            }
            return candidate.filename == filename
                || candidate.media.posterFilename == filename
                || candidate.media.pairedVideoFilename == filename
                || candidate.photosLibraryAssets.contains(where: { asset in
                    asset.managedFilenames.contains(filename)
                })
                || candidate.spaceImageFilenames.contains(filename)
                || candidate.liveFolderEntries.contains(where: { $0.managedFilename == filename })
        }
        guard !stillReferenced else { return }

        // Verify the durable current JSON before deleting. If it is unreadable, keep the bytes
        // because the file may still reference them even though the in-memory model does not.
        guard let current = currentStoredFilenames() else { return }
        guard !current.contains(filename) else { return }
        try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(filename))
    }

    func removePhoto(_ id: UUID) { removePhotos([id]) }

    /// Commit the complete selection once before tearing down any windows or media.
    func removePhotos(_ ids: Set<UUID>) {
        let removed = photos.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let affectedParents = Set(removed.compactMap(\.collageParentID))
            .union(removed.filter { $0.desktopCollage != nil }.map(\.id))
        let affectedIDs = Set(removed.map(\.id)).union(photos.filter {
            affectedParents.contains($0.id) || $0.collageParentID.map { affectedParents.contains($0) } == true
        }.map(\.id))
        // A removal cannot discard an unfinished edit, even if the save later
        // fails. Unrelated previews and gestures keep their own runtime ownership.
        guard !hasArrangementInteraction(affecting: affectedIDs) else {
            let reason = "Finish the affected move, resize or collage appearance edit before removing widgets."
            recordMediaImportFailure(reason)
            if !Self.isUnitTestHost { AppDialog.inform(title: "Finish Editing First", message: reason) }
            return
        }
        let previousRecovery: DesktopSetupLibrary
        do {
            previousRecovery = try prepareRemovalRecovery(removed)
        } catch {
            recordMediaImportFailure("Removal recovery could not be saved: \(error.localizedDescription)")
            if !Self.isUnitTestHost {
                AppDialog.inform(title: "Couldn’t Remove Widgets", message: "The recovery copy could not be saved. Your widgets are unchanged. Check available disk space and try again.", style: .warning)
            }
            return
        }
        let oldPhotos = photos
        let oldSelection = selectedPhotoIDs
        let oldAnchor = selectionAnchorID
        let survivingCollageParents = Set(removed.compactMap(\.collageParentID)).subtracting(ids)
        let detached = photos.filter {
            $0.collageParentID.map(ids.contains) == true
                && !ids.contains($0.id)
        }.map(\.id)
        for i in photos.indices where photos[i].collageParentID.map(ids.contains) == true {
            photos[i].collageParentID = nil
        }
        photos.removeAll { ids.contains($0.id) }
        for parent in survivingCollageParents { fitCollageModel(parent) }
        selectedPhotoIDs.subtract(ids)
        if let anchor = selectionAnchorID, ids.contains(anchor) { selectionAnchorID = selectedPhotoIDs.first }
        guard persist() else {
            photos = oldPhotos
            selectedPhotoIDs = oldSelection
            selectionAnchorID = oldAnchor
            try? previousRecovery.write(in: storageDir)
            return
        }
        removedWidgetCount = removed.count
        for item in removed {
            let id = item.id
            collageDrags.removeValue(forKey: id)
            collageFlights.removeValue(forKey: id)?.stop()
            invalidateThumbnails(for: item)
            windows[id]?.hidePhoto()
            windows.removeValue(forKey: id)
            spaceImages.removeValue(forKey: id)
            rotationTimers[id]?.cancel()
            rotationTimers.removeValue(forKey: id)
            stopLiveFolderWatcher(for: id)

            let managedFilenames = [item.filename, item.media.posterFilename, item.media.pairedVideoFilename]
                .compactMap { $0 }
                + item.spaceImageFilenames
                + item.liveFolderEntries.map(\.managedFilename)
                + item.photosLibraryAssets.flatMap(\.managedFilenames)
            for filename in managedFilenames where !filename.isEmpty {
                removeStoredFileIfUnreferenced(filename)
            }
        }
        for id in detached {
            if let child = photos.first(where: { $0.id == id }) {
                windows[id]?.setDepth(child.depth)
                windows[id]?.setSpaceBound(child.isSpaceBound)
                (windows[id]?.contentView as? DraggablePhotoView)?.isLockedByCollage = false
                windows[id]?.setLocked(child.isLocked)
            }
            if windows[id] == nil, let item = photos.first(where: { $0.id == id }), item.isVisible,
               !item.isHiddenForDisplay && !item.isHiddenForPresence, let content = loadDisplayContent(for: item) {
                createWindow(for: item, content: content)
            }
        }
        syncCollages(only: survivingCollageParents)
        for parent in survivingCollageParents { fitCollageWindow(parent) }
        for name in (previousRecovery.removed?.photos ?? []).flatMap({ storedFilenames(in: $0) }) {
            removeStoredFileIfUnreferenced(name)
        }
    }

    func removeAllPhotos() { removePhotos(Set(photos.map(\.id))) }

    /// Shows every photo, or hides every photo if any are currently showing.
    ///
    /// Biased toward hiding so the global hotkey behaves like a "get out of the
    /// way" key: one press always clears the desktop, the next restores it.
    /// - Returns: true if photos are visible after the toggle.
    @discardableResult
    func toggleAllVisibility() -> Bool {
        guard !photos.isEmpty else { return false }

        let target = !photos.contains { $0.isVisible }
        setVisibility(Set(photos.map(\.id)), to: target)
        return photos.contains { $0.isVisible }
    }

    func restoreDesktopSetupItems(_ items: [PhotoItem]) -> Bool {
        let previous = photos
        photos = items
        guard persist() else { photos = previous; return false }
        installLoadedItems(items)
        removeStoredFilesNoLongerReferenced(from: previous, after: items)
        return true
    }

    /// Adopts a batch of already-staged imported items in one durable model write. The caller
    /// has validated that every referenced media file decodes before reaching this point, so the
    /// only fallible operation here is the model save itself. Runtime changes follow that save;
    /// additive imports leave existing windows and interactions intact. A failed save restores
    /// the in-memory layout without touching any windows.
    @discardableResult
    func commitImportedItems(_ importedItems: [PhotoItem], replacing: Bool,
                             recoveringDamagedLibrary: Bool = false) -> Bool {
        guard !importedItems.isEmpty else { return false }
        guard !recoveringDamagedLibrary || (replacing && libraryRecoveryRequired) else { return false }

        let previousPhotos = photos
        let committedPhotos = replacing ? importedItems : previousPhotos + importedItems
        photos = committedPhotos

        guard persist(recoveringDamagedLibrary: recoveringDamagedLibrary) else {
            photos = previousPhotos
            return false
        }

        if replacing { installLoadedItems(committedPhotos) }
        else { activateCommittedAdditions(importedItems) }

        // A replacement may orphan the previous library's media. Do this last: until the model
        // commit succeeds, the old JSON is still the source of truth and must remain loadable.
        // A damaged library's retained copy can still be repaired manually. Keep
        // its media too, including files known to a model loaded before corruption.
        if !recoveringDamagedLibrary {
            removeStoredFilesNoLongerReferenced(from: previousPhotos, after: committedPhotos)
        }
        return true
    }

    private func removeStoredFilesNoLongerReferenced(from oldItems: [PhotoItem], after newItems: [PhotoItem]) {
        let oldFilenames = Set(oldItems.flatMap { storedFilenames(in: $0) }.filter { !$0.isEmpty })
        let newFilenames = Set(newItems.flatMap { storedFilenames(in: $0) }.filter { !$0.isEmpty })

        for filename in oldFilenames.subtracting(newFilenames) {
            // Keep the same durable-reference safety checks used by ordinary deletion.
            removeStoredFileIfUnreferenced(filename)
        }
    }

    // MARK: - Window Creation

    func createWindow(for item: PhotoItem, content: PhotoContent) {
        if item.desktopCollage != nil { createCollageWindow(item); return }
        guard collageAllowsWindow(item) else { return }

        let window = DesktopPhotoWindow()
        window.setSettingsWindowActive(settingsWindowIsActive)
        window.isReleasedWhenClosed = false
        window.photoId = item.id

        // Presence & Privacy: new windows pick up the current exclusion
        // preference immediately; applyScreenCaptureExclusion() handles windows already
        // on screen when the toggle itself changes. `.readOnly` is NSWindow's own
        // documented default, so turning the toggle off restores exactly the behavior
        // this app had before the toggle existed.
        window.sharingType = presence.excludeFromScreenCapture ? .none : .readOnly

        window.showPhoto(content, baseWidth: item.widgetWidth, locked: item.isLocked, settings: item)

        // Restore saved position
        var targetFrame: NSRect? = nil
        if item.folderSizeMode == "dynamic", !item.spaceImageFilenames.isEmpty, let images = spaceImages[item.id] {
            let currentImage = images[safe: item.folderImageIndex]
            if let key = currentImage?.lastPathComponent, let cfg = item.folderImageConfigs[key] {
                targetFrame = NSRectFromString(cfg.frameString)
            }
        }

        let fallbackRect = NSRectFromString(item.frameString)
        var rectToUse = targetFrame ?? fallbackRect
        // Saved placement can predate a crop/quarter-turn edit. Preserve origin
        // and width, but derive height from the rendered image so masks, shadows
        // and resize handles do not surround an obsolete letterboxed canvas.
        // Fixed-frame slideshows intentionally retain their configured canvas.
        let fixedPlaylist = !item.spaceImageFilenames.isEmpty && item.folderSizeMode == "fixed"
        if item.reference.hasImageEdits, !fixedPlaylist, rectToUse.width > 0, window.photoFrame.width > 0 {
            rectToUse.size.height = rectToUse.width * window.photoFrame.height / window.photoFrame.width
        }
        if rectToUse.width > 0, item.collageParentID == nil {
            rectToUse = clampToVisibleScreens(rectToUse)
        }

        if rectToUse.width > 0 {
            window.setPhotoFrame(rectToUse)
        }

        window.setSpaceBound(item.isSpaceBound)

        // Per-Display Profiles: record which physical display this window landed on so it can
        // be hidden/restored correctly if that display is unplugged later. Runs on every
        // createWindow call (not just first-time placement) so a photo dragged onto a new
        // monitor picks up the new "home" the next time it needs to be re-created.
        if let idx = photos.firstIndex(where: { $0.id == item.id }),
           let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(rectToUse) }) ?? NSScreen.main {
            photos[idx].displayIdentifier = DisplayManager.identifier(for: screen)
        }

        // Callbacks
        window.onLockToggle = { [weak self] in self?.toggleLock(item.id) }
        window.onRemove = { [weak self] in self?.removePhoto(item.id) }
        window.onResize = { [weak self] newWidth in
            guard let self, let i = self.photos.firstIndex(where: { $0.id == item.id }) else { return }
            self.photos[i].widgetWidth = newWidth
            self.persist()
        }
        window.onOpacityChanged = { [weak self] newOpacity in
            self?.setOpacity(item.id, newOpacity)
        }

        window.arrangementMenuItems = { [weak self] in self?.makeArrangementMenuItems() ?? [] }
        window.onBringToFront = { [weak self] in self?.bringToFront(item.id) }
        window.onSendToBack = { [weak self] in self?.sendToBack(item.id) }
        window.onRuntimeActivityChanged = { [weak self, weak window] decision in
            guard let self, let window, let id = window.photoId else { return }
            self.handleRuntimeActivityChanged(id, decision: decision)
        }

        // The view owns only the gesture; the manager owns which bounded action it invokes and
        // performs the same lock/depth check for programmatic or stale callbacks.
        window.onClickAction = { [weak self] in
            self?.performClickAction(item.id)
        }
        // Also wire it on the view. `showPhoto` installs the forwarding closure for future
        // windows, while this assignment covers the existing construction path explicitly.
        (window.contentView as? DraggablePhotoView)?.onClickAction = window.onClickAction

        windows[item.id] = window
        wireCollageDrag(window, item: item)
        if let parentID = item.collageParentID { syncCollages(only: [parentID]) }
        window.startRuntimeActivityMonitoring()
    }

    // MARK: - Controls

    /// Raises a widget one step: in front of its siblings first, then up past the desktop
    /// icons, the system's desktop widgets and finally ordinary app windows.
    ///
    /// `orderFront` alone only reorders within a window level, so it can never move a photo
    /// past a desktop icon or a macOS widget — those sit at different levels entirely. Walking
    /// the depth once the widget already leads its own siblings is what makes repeated
    /// "Bring to Front" clicks actually climb the whole stack.
    func bringToFront(_ id: UUID) {
        if let parent = photos.first(where: { $0.id == id })?.collageParentID { bringToFront(parent); return }
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let depth = photos[index].depth
        let siblings = photos.filter { $0.id != id && $0.depth == depth }

        if !siblings.allSatisfy({ $0.stackOrder < photos[index].stackOrder }) {
            let before = photos[index].stackOrder
            photos[index].stackOrder = (photos.map(\.stackOrder).max() ?? 0) + 1
            guard persist() else { photos[index].stackOrder = before; return }
            windows[id]?.orderFront(nil)
            syncCollages()
            return
        }
        if let next = WidgetDepth(stackIndex: depth.stackIndex + 1) {
            setDepth(id, next)
        }
    }

    /// The mirror of `bringToFront`: behind its siblings first, then down past the system
    /// widgets and the desktop icons.
    func sendToBack(_ id: UUID) {
        if let parent = photos.first(where: { $0.id == id })?.collageParentID { sendToBack(parent); return }
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let depth = photos[index].depth
        let siblings = photos.filter { $0.id != id && $0.depth == depth }

        if !siblings.allSatisfy({ $0.stackOrder > photos[index].stackOrder }) {
            let before = photos[index].stackOrder
            photos[index].stackOrder = (photos.map(\.stackOrder).min() ?? 0) - 1
            guard persist() else { photos[index].stackOrder = before; return }
            windows[id]?.orderBack(nil)
            syncCollages()
            return
        }
        if let next = WidgetDepth(stackIndex: depth.stackIndex - 1) {
            setDepth(id, next)
        }
    }

    func setDepth(_ id: UUID, _ depth: WidgetDepth) {
        if let parent = photos.first(where: { $0.id == id })?.collageParentID { setDepth(parent, depth); return }
        if !collageMoveSnapshots.isEmpty { cancelCollageInteractions() }
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index]
        photos[index].depth = depth
        // Kept in sync so an older build reading this file still gets the floating state right.
        photos[index].isFloating = depth == .floating

        // Finder's desktop window covers the whole screen and consumes every click, so a widget
        // below it is unreachable by definition. Locking it is the honest thing to do: the
        // alternative is a widget the user cannot grab and cannot tell why.
        if !depth.isInteractive {
            photos[index].isLocked = true
        }
        guard persist() else { photos[index] = before; return }

        if !depth.isInteractive { windows[id]?.setLocked(true) }
        windows[id]?.setDepth(depth)
        syncCollages()
    }

    func setRevealOnHover(_ id: UUID, _ enabled: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index].revealOnHover
        photos[index].revealOnHover = enabled
        guard persist() else { photos[index].revealOnHover = before; return }
        windows[id]?.setRevealOnHover(enabled)
    }

    @discardableResult
    func setOpacity(_ id: UUID, _ value: CGFloat) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }), value.isFinite else { return false }
        let before = photos[index].opacity
        let requested = max(0.1, min(1.0, value))
        guard before != requested else { return true }
        photos[index].opacity = requested
        guard persist() else { photos[index].opacity = before; return false }
        windows[id]?.setPhotoOpacity(photos[index].opacity)
        updateCollageLabels(id)
        return true
    }

    func toggleLock(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        // A member's effective unlock action belongs to the locking parent,
        // rather than turning its saved personal lock on by accident.
        if isLockedByCollage(photos[index]), let parent = photos[index].collageParentID { toggleLock(parent); return }
        let locked = !photos[index].isLocked
        if locked {
            let drags = collageDrags.filter { $0.key == id || $0.value.parentID == id || $0.value.targetID == id }.map(\.key)
            for photo in drags { cancelCollageDrag(photo) }
        }
        let before = photos
        photos[index].isLocked = locked
        guard persist() else { photos = before; return }
        windows[id]?.setLocked(locked)
        syncCollages()
        let affected = photos[index].desktopCollage == nil ? [photos[index]] : collageMembers(id)
        for item in affected {
            (windows[item.id]?.contentView as? DraggablePhotoView)?.flashLockState(isEffectivelyLocked(item))
        }
    }

    @discardableResult
    func toggleVisibility(_ id: UUID) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return false }
        return setVisibility([id], to: !photos[index].isVisible)
    }

    /// Global visibility commits once so a partial save cannot split a collage
    /// or make Shortcuts report the requested state instead of the actual state.
    @discardableResult
    private func setVisibility(_ ids: Set<UUID>, to visible: Bool) -> Bool {
        let changedIDs = Set(photos.filter { ids.contains($0.id) && $0.isVisible != visible }.map(\.id))
        guard !changedIDs.isEmpty else { return true }
        cancelCollageInteractions()
        let before = photos
        var parents = Set<UUID>()
        for index in photos.indices where changedIDs.contains(photos[index].id) {
            photos[index].isVisible = visible
            if let parent = photos[index].collageParentID { parents.insert(parent) }
            if visible {
                // Manual Show clears transient suppression until the next
                // display/presence evaluation, preserving the stored preference.
                photos[index].isHiddenForDisplay = false
                photos[index].isHiddenForPresence = false
            }
        }
        for parent in parents { fitCollageModel(parent) }
        // Commit visibility and fitted bounds before closing or rebuilding any
        // windows. A failed write must leave the displayed composition intact.
        guard persist() else { photos = before; return false }

        // Create parents first so members inherit the collage's placement as
        // they appear. Creating a parent may already restore its members.
        let changed = photos.filter { changedIDs.contains($0.id) }.sorted {
            $0.desktopCollage != nil && $1.desktopCollage == nil
        }
        for item in changed {
            if visible {
                if windows[item.id] == nil {
                    if let content = loadDisplayContent(for: item) {
                        createWindow(for: item, content: content)
                    } else {
                        recordMediaImportFailure("The stored image for \(label(for: item)) could not be decoded.")
                    }
                }
                if !item.spaceImageFilenames.isEmpty { setupRotationTimer(for: item) }
            } else {
                windows[item.id]?.hidePhoto()
                windows.removeValue(forKey: item.id)
                rotationTimers.removeValue(forKey: item.id)?.cancel()
            }
        }
        for parent in parents { fitCollageWindow(parent) }
        syncCollages()
        return true
    }

    // MARK: - Widget click action

    func setClickAction(_ id: UUID, _ action: WidgetClickAction) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let previous = photos[index]
        photos[index].clickAction = action
        guard persist() else { photos[index] = previous; return }
    }

    /// Lock Position only affects geometry. Keep visibility and depth guards here because
    /// stale callbacks must not activate a hidden or noninteractive widget.
    func performClickAction(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let item = photos[index]
        guard item.isVisible,
              effectiveDepth(of: item).isInteractive,
              collageAllowsWindow(item),
              !item.isHiddenForDisplay,
              !item.isHiddenForPresence else { return }

        switch item.clickAction {
        case .advance:
            guard !item.spaceImageFilenames.isEmpty else { return }
            nextFolderImage(id)
        case .quickLook:
            showQuickLook(for: id)
        case .revealStoredMedia:
            revealStoredMedia(id)
        case .copyPath:
            copyStoredMediaPath(id)
        }
    }

    /// Resolves the currently displayed stored media. Spaces use their selected slot while a
    /// regular widget uses its primary filename. The URL may point at missing media so Copy Path
    /// remains useful for diagnosis; display actions check existence before opening anything.
    func storedMediaURL(for id: UUID) -> URL? {
        guard let item = photos.first(where: { $0.id == id }) else { return nil }
        let filename: String
        if !item.spaceImageFilenames.isEmpty {
            filename = item.spaceImageFilenames[safe: item.folderImageIndex]
                ?? item.spaceImageFilenames.first ?? item.filename
        } else {
            filename = item.filename
        }
        guard !filename.isEmpty else { return nil }
        return storageDir.appendingPathComponent(filename)
    }

    func revealStoredMedia(_ id: UUID) {
        guard let url = storedMediaURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    func copyStoredMediaPath(_ id: UUID) {
        guard let url = storedMediaURL(for: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func mediaPlaybackStatus(for id: UUID) -> VideoPlaybackStatus {
        windows[id]?.mediaPlaybackStatus ?? .paused
    }

    private func showQuickLook(for id: UUID) {
        guard let item = photos.first(where: { $0.id == id }),
              let url = storedMediaURL(for: id),
              FileManager.default.fileExists(atPath: url.path) else { return }
        showQuickLook(for: url, title: label(for: item))
    }

    private func showQuickLook(for url: URL, title: String) {
        let previewItem = StoredMediaPreviewItem(url: url, title: title)
        let dataSource = StoredMediaPreviewDataSource(item: previewItem)
        quickLookDataSource = dataSource

        // The app is an LSUIElement/accessory app and widget panels are deliberately
        // non-activating. Activate before presenting Quick Look so the shared panel can become
        // key and receive Escape/arrow-key focus instead of appearing behind the user's app.
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = dataSource
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func resize(_ id: UUID, to width: CGFloat) {
        guard width.isFinite, width > 0,
              let index = photos.firstIndex(where: { $0.id == id }),
              photos[index].desktopCollage == nil else { return }
        cancelCollageInteractions()
        let before = photos
        let target: NSRect?
        if let window = windows[id] {
            guard let frame = window.frameForResizing(toWidth: width) else { return }
            target = frame
        } else {
            // A hidden photo has no native view. Resize its stored aspect ratio
            // so showing it or restoring a setup cannot resurrect the old size.
            let frame = NSRectFromString(photos[index].frameString)
            if frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 {
                let height = width * (frame.height / frame.width)
                guard height.isFinite, height > 0 else { return }
                target = NSRect(origin: frame.origin, size: NSSize(width: width, height: height))
            } else { target = nil }
        }
        photos[index].widgetWidth = width
        if let target {
            if windows[id] != nil { storeCollageFrame(id, target) }
            else {
                photos[index].frameString = NSStringFromRect(target)
                if let display = photos[index].displayIdentifier {
                    photos[index].savedDisplayFrames[display] = NSStringFromRect(target)
                }
            }
            if photos[index].folderSizeMode == "dynamic",
               let filename = photos[index].spaceImageFilenames[safe: photos[index].folderImageIndex] {
                photos[index].folderImageConfigs[filename] = FolderImageConfig(frameString: NSStringFromRect(target), widgetWidth: width)
            }
        }
        let parent = photos[index].collageParentID
        if let parent { fitCollageModel(parent) }
        guard persist() else { photos = before; return }
        windows[id]?.resizeTo(width: width)
        if let parent { fitCollageWindow(parent) }
    }

    // MARK: - Naming & Organization

    func renamePhoto(_ id: UUID, to name: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let previous = photos[index]
        photos[index].customName = name.isEmpty ? nil : name
        guard persist() else { photos[index] = previous; return }
    }

    @discardableResult
    func replacePhoto(_ id: UUID, with newImage: NSImage) -> Bool {
        guard let item = photos.first(where: { $0.id == id }), item.allowsManualMediaEditing,
              !replacementConflictsWithArrangement(item),
              let stored = saveImportedImage(newImage) else { return false }
        return replaceStoredImage(id, with: stored, fidelity: .transformed)
    }

    /// Commit prepared image bytes directly so file replacements retain animation and format.
    private func replaceStoredImage(
        _ id: UUID,
        with stored: (filename: String, url: URL),
        fidelity: ArchiveMediaFidelity
    ) -> Bool {
        var committed = false
        defer { if !committed { removeStoredFileIfUnreferenced(stored.filename) } }
        guard let original = photos.first(where: { $0.id == id }), original.allowsManualMediaEditing else { return false }
        guard let content = PhotoContent.load(from: stored.url) else {
            recordMediaImportFailure("The replacement image could not be decoded after it was stored.")
            return false
        }
        var replacement = original
        let oldFilename: String
        let preferredFrame: NSRect?
        if original.spaceImageFilenames.isEmpty {
            oldFilename = original.filename
            preferredFrame = nil
            replacement.filename = stored.filename
            replacement.media = content.mediaModel
            replacement.mediaFidelity = [stored.filename: fidelity]
        } else {
            let index = original.spaceImageFilenames.indices.contains(original.folderImageIndex) ? original.folderImageIndex : 0
            oldFilename = original.spaceImageFilenames[index]
            let configuration = original.folderImageConfigs[oldFilename]
            preferredFrame = configuration.map { NSRectFromString($0.frameString) }
            replacement.folderImageIndex = index
            replacement.spaceImageFilenames[index] = stored.filename
            replacement.mediaFidelity[stored.filename] = fidelity
            replacement.playbackHistory.removeAll { $0 == oldFilename }
            if let configuration { replacement.folderImageConfigs[stored.filename] = configuration }
            // Historical slideshows may share a filename/configuration across slots.
            if !replacement.spaceImageFilenames.contains(oldFilename) {
                replacement.mediaFidelity.removeValue(forKey: oldFilename)
                replacement.folderImageConfigs.removeValue(forKey: oldFilename)
            }
        }
        guard commitMediaReplacement(replacement, content: content, preferredFrame: preferredFrame) else { return false }
        committed = true
        if original.spaceImageFilenames.isEmpty {
            for filename in storedMediaFilenames(for: original) { removeStoredFileIfUnreferenced(filename, excluding: id) }
        } else {
            removeStoredFileIfUnreferenced(oldFilename, excluding: id, spaceSlotIndex: replacement.folderImageIndex)
        }
        return true
    }

    /// URL-based replacement preserves a movie's managed bytes and generated poster.  Image
    /// replacement also goes through the same preparation path, so animated files do not depend
    /// on an NSImage round-trip when they are replaced from Finder.
    @discardableResult
    func replacePhoto(_ id: UUID, with sourceURL: URL) async -> ImportBatchResult {
        guard let index = photos.firstIndex(where: { $0.id == id }) else {
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: .failed, reason: "The widget no longer exists.")
            ])
        }

        guard photos[index].allowsManualMediaEditing else {
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: .skipped,
                      reason: "This widget is managed by its linked source. Change its folder or Photos collection instead.")
            ])
        }
        let directory = storageDir
        let generation = desktopGeneration
        let original = photos[index]
        let prepare = prepareImportedURL
        beginMediaImport()
        defer { endMediaImport() }
        let prepared = await Task.detached(priority: .utility) {
            prepare(sourceURL, directory)
        }.value
        guard let prepared else {
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: .failed,
                      reason: "The selected media could not be read, validated, or stored.")
            ])
        }

        // Only the requested media may be replaced. A slideshow can advance, or a
        // newer replacement can commit, while this request prepares off the main actor.
        // Keep unrelated appearance/name edits by applying to the current item below.
        guard !Task.isCancelled, desktopGeneration == generation,
              let item = photos.first(where: { $0.id == id }), item.allowsManualMediaEditing,
              item.filename == original.filename, item.media == original.media,
              item.spaceImageFilenames == original.spaceImageFilenames,
              item.folderImageIndex == original.folderImageIndex else {
            discardPreparedMedia(prepared)
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: .skipped, reason: "The desktop or widget changed during import. Choose the replacement again.")
            ])
        }
        guard !replacementConflictsWithArrangement(item) else {
            discardPreparedMedia(prepared)
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: .skipped,
                      reason: "Finish moving or editing this photo or its collage, then choose the replacement again.")
            ])
        }
        if !item.spaceImageFilenames.isEmpty {
            guard !prepared.media.kind.isVideoKind else {
                discardPreparedMedia(prepared)
                return ImportBatchResult(entries: [
                    .init(source: sourceURL.lastPathComponent, status: .failed,
                          reason: "Videos can be replaced only on standalone widgets.")
                ])
            }
            let saved = replaceStoredImage(id, with: (prepared.filename, prepared.url), fidelity: prepared.mediaFidelity)
            if !saved { discardPreparedMedia(prepared) }
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: saved ? .accepted : .failed,
                      reason: saved ? nil : "The replacement could not be saved.")
            ])
        }

        guard replaceStandaloneMedia(id, with: prepared) else {
            discardPreparedMedia(prepared)
            return ImportBatchResult(entries: [
                .init(source: sourceURL.lastPathComponent, status: .failed,
                      reason: "The selected media could not be decoded after it was stored.")
            ])
        }
        return ImportBatchResult(entries: [
            .init(source: sourceURL.lastPathComponent, status: .accepted)
        ])
    }

    private func replaceStandaloneMedia(_ id: UUID, with prepared: PhotoIngest.Prepared) -> Bool {
        guard let original = photos.first(where: { $0.id == id }), original.spaceImageFilenames.isEmpty,
              let content = PhotoContent.load(from: prepared.url, posterURL: prepared.posterURL,
                                              pairedVideoURL: prepared.pairedVideoURL) else { return false }
        var replacement = original
        replacement.filename = prepared.filename
        replacement.media = prepared.media
        replacement.mediaFidelity = prepared.mediaFidelityByFilename
        guard commitMediaReplacement(replacement, content: content) else { return false }
        for filename in storedMediaFilenames(for: original) { removeStoredFileIfUnreferenced(filename, excluding: id) }
        return true
    }

    /// Save content identity and its destination geometry before touching native media.
    /// Failed writes keep the existing decoder/player, URL cache and collage scene intact.
    private func commitMediaReplacement(_ replacement: PhotoItem, content: PhotoContent, preferredFrame: NSRect? = nil) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == replacement.id }),
              !replacementConflictsWithArrangement(photos[index]) else { return false }
        let previous = photos
        let original = photos[index]
        let id = replacement.id
        let mode = replacement.spaceImageFilenames.isEmpty ? "dynamic" : replacement.folderSizeMode
        let frame = windows[id]?.photoFrame ?? NSRectFromString(original.frameString)
        let size = replacement.reference.hasImageEdits
            ? PhotoReferenceRenderer.outputSize(for: content.size, settings: replacement.reference) : content.size
        let target = DesktopPhotoWindow.frameForSwapping(contentSize: size, photoFrame: frame,
                                                        targetFrame: preferredFrame, mode: mode)
        photos[index] = replacement
        if let target {
            if windows[id] != nil { storeCollageFrame(id, target) }
            else {
                photos[index].frameString = NSStringFromRect(target)
                photos[index].widgetWidth = target.width
                if let display = photos[index].displayIdentifier {
                    photos[index].savedDisplayFrames[display] = NSStringFromRect(target)
                }
            }
            if mode == "dynamic", let filename = replacement.spaceImageFilenames[safe: replacement.folderImageIndex] {
                photos[index].folderImageConfigs[filename] = FolderImageConfig(frameString: NSStringFromRect(target), widgetWidth: target.width)
            }
        }
        let parent = replacement.collageParentID
        if let parent { fitCollageModel(parent) }
        guard persist() else { photos = previous; return false }
        invalidateThumbnails(for: original)
        invalidateThumbnails(for: photos[index])
        if !replacement.spaceImageFilenames.isEmpty {
            spaceImages[id] = replacement.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
        }
        // This transaction already owns the fitted bounds. The normal swap callback
        // would save them a second time after the native content had changed.
        windows[id]?.swapImage(content, targetFrame: target, mode: mode, animate: true, notifyGeometryChange: false)
        if let parent { fitCollageWindow(parent) }
        return true
    }

    /// A replacement changes this scene's media geometry. Leave unrelated scenes
    /// alone, and never cancel a gesture just because background preparation ends.
    func replacementConflictsWithArrangement(_ item: PhotoItem) -> Bool {
        let root = item.collageParentID ?? item.id
        let sceneIDs = Set([root] + collageMembers(root).map(\.id))
        return hasArrangementInteraction(affecting: sceneIDs)
    }

    /// Background source refreshes keep one completed result pending until its
    /// affected scene is idle. Revalidate identity after each cancellable wait;
    /// ordinary idle operation creates no polling task.
    func waitForMediaReplacement(_ currentIndex: () -> Int?, onWait: () -> Void = {}) async -> Int? {
        var reportedWait = false
        while !Task.isCancelled, let index = currentIndex() {
            if !replacementConflictsWithArrangement(photos[index]) { return index }
            if !reportedWait { onWait(); reportedWait = true }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return nil }
        }
        return nil
    }

    private func storedMediaFilenames(for item: PhotoItem) -> [String] {
        [item.filename, item.media.posterFilename, item.media.pairedVideoFilename]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    private func discardPreparedMedia(_ prepared: PhotoIngest.Prepared) {
        for url in prepared.managedURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func duplicatePhoto(_ id: UUID) {
        guard let original = photos.first(where: { $0.id == id }), original.desktopCollage == nil else { return }
        let previous = photos
        var newItem = PhotoItem(filename: "", width: original.widgetWidth)
        newItem.customName = (original.customName ?? "Photo") + " (Copy)"
        copyAppearanceSettings(from: original, to: &newItem)

        var copiedNames: [String: String] = [:]
        var committed = false
        defer {
            if !committed {
                for name in copiedNames.values {
                    try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(name))
                }
            }
        }

        let images: [URL]?
        if !original.spaceImageFilenames.isEmpty {
            newItem.spaceImageFilenames = original.spaceImageFilenames
            newItem.rotationInterval = original.rotationInterval
            newItem.customRotationSeconds = original.customRotationSeconds
            newItem.folderSizeMode = original.folderSizeMode
            newItem.folderImageConfigs = original.folderImageConfigs
            newItem.folderImageIndex = original.folderImageIndex
            newItem.mediaFidelity = original.mediaFidelity
            // A duplicate shares the managed snapshot and source metadata. This does not copy
            // source bytes and keeps the duplicate eligible for the same relink workflow.
            newItem.liveFolderSource = original.liveFolderSource
            newItem.liveFolderEntries = original.liveFolderEntries
            newItem.photosLibrarySource = original.photosLibrarySource
            newItem.photosLibraryAssets = original.photosLibraryAssets
            // Hidden slideshows need not have a live URL cache. The saved managed
            // filenames, not the original window's lifetime, own their content.
            images = original.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
        } else {
            // Copy the primary file and every related managed artifact.  A movie's poster and a
            // Live Photo's paired movie are content, not optional cache, so the duplicate must
            // receive fresh filenames and a remapped model.
            guard let newFilename = copyManagedFile(named: original.filename) else { return }
            copiedNames[original.filename] = newFilename
            for related in [original.media.posterFilename, original.media.pairedVideoFilename].compactMap({ $0 }) where copiedNames[related] == nil {
                guard let copied = copyManagedFile(named: related) else { return }
                copiedNames[related] = copied
            }
            newItem.filename = newFilename
            newItem.media = PhotoMedia(
                kind: original.media.kind,
                posterFilename: original.media.posterFilename.flatMap { copiedNames[$0] },
                pairedVideoFilename: original.media.pairedVideoFilename.flatMap { copiedNames[$0] },
                isMuted: original.media.isMuted
            )
            newItem.mediaFidelity = copiedNames.reduce(into: [:]) { result, pair in
                result[pair.value] = original.mediaFidelity[pair.key] ?? .unknown
            }
            images = nil
        }

        func offsetFrame(_ string: String) -> String {
            guard !string.isEmpty else { return string }
            return NSStringFromRect(NSRectFromString(string).offsetBy(dx: 30, dy: -30))
        }
        newItem.frameString = offsetFrame(original.frameString)
        newItem.folderImageConfigs = newItem.folderImageConfigs.mapValues { configuration in
            var copy = configuration
            copy.frameString = offsetFrame(copy.frameString)
            return copy
        }

        let content: PhotoContent?
        if let images {
            content = images[safe: newItem.folderImageIndex].flatMap {
                loadMediaContent(for: newItem, filename: $0.lastPathComponent, primaryURL: $0)
            }
        } else {
            content = loadMediaContent(for: newItem, primaryURL: storageDir.appendingPathComponent(newItem.filename))
        }
        guard let content else {
            recordMediaImportFailure("The stored image for \(label(for: original)) could not be decoded. No duplicate was added.")
            return
        }
        photos.append(newItem)
        guard persist() else { photos = previous; return }
        committed = true

        // Publish runtime resources only after the duplicate is durable. A failed
        // save leaves the original windows, playback and managed files untouched.
        if let images { spaceImages[newItem.id] = images }
        createWindow(for: newItem, content: content)
        if images != nil { setupRotationTimer(for: newItem) }
        if newItem.liveFolderSource != nil { installLiveFolderWatcher(for: newItem) }
    }

    private func copyManagedFile(named filename: String) -> String? {
        guard !filename.isEmpty else { return nil }
        let sourceURL = storageDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let ext = (filename as NSString).pathExtension
        let copyName = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let destinationURL = storageDir.appendingPathComponent(copyName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return copyName
        } catch {
            return nil
        }
    }

    private func copyAppearanceSettings(from src: PhotoItem, to dst: inout PhotoItem) {
        dst.isFloating = src.isFloating
        dst.depth = src.depth
        dst.stackOrder = src.stackOrder
        dst.opacity = src.opacity
        dst.revealOnHover = src.revealOnHover
        dst.clickAction = src.clickAction
        dst.playbackOrder = src.playbackOrder
        dst.playbackSeed = src.playbackSeed
        dst.playbackStep = src.playbackStep
        dst.playbackHistory = src.playbackHistory
        dst.cornerRadius = src.cornerRadius
        dst.shadowEnabled = src.shadowEnabled
        dst.shadowBlur = src.shadowBlur
        dst.shadowOpacity = src.shadowOpacity
        dst.borderWidth = src.borderWidth
        dst.borderColorHex = src.borderColorHex
        dst.vignetteEnabled = src.vignetteEnabled
        dst.isSpaceBound = src.isSpaceBound

        // frame styling. Duplicating a photo is almost always "give me
        // another one of these", so a copy that silently lost its mat, shape and
        // tilt would be the wrong answer.
        dst.matWidth = src.matWidth
        dst.matColorHex = src.matColorHex
        dst.shapeMask = src.shapeMask
        dst.borderStyle = src.borderStyle
        dst.borderGradientEnabled = src.borderGradientEnabled
        dst.borderGradientColorHex = src.borderGradientColorHex
        dst.tiltDegrees = src.tiltDegrees
        dst.stylePreset = src.stylePreset
        dst.focalPoint = src.focalPoint
        dst.reference = src.reference

        // displayIdentifier / savedDisplayFrames / isHiddenForDisplay intentionally not copied —
        // the duplicate gets its own window and should pick up its own home display from
        // wherever createWindow actually places it.
        //
        // Presence suppression is likewise recomputed rather than inherited: it
        // describes the current moment, not the photo.
    }

    // MARK: - Aesthetic Controls

    func setCornerRadius(_ id: UUID, _ value: CGFloat) {
        guard value.isFinite else { return }
        editAppearance(id) { $0.cornerRadius = max(0, value) }
    }

    func setShadow(_ id: UUID, enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        guard blur.isFinite, opacity.isFinite else { return }
        editAppearance(id) {
            $0.shadowEnabled = enabled
            $0.shadowBlur = max(0, blur)
            $0.shadowOpacity = min(1, max(0, opacity))
        }
    }

    func setBorder(_ id: UUID, width: CGFloat, colorHex: String) {
        guard width.isFinite else { return }
        editAppearance(id) { $0.borderWidth = max(0, width); $0.borderColorHex = colorHex }
    }

    func setVignette(_ id: UUID, enabled: Bool) {
        editAppearance(id) { $0.vignetteEnabled = enabled }
    }

    // MARK: - Smart Canvas

    @discardableResult
    func nextFolderImage(_ id: UUID) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              photos[index].isVisible,
              let images = spaceImages[id], !images.isEmpty else { return false }

        let item = photos[index]

        if replacementConflictsWithArrangement(item) { return false }

        let selection = SpacePlaybackSelector.nextSelection(
            filenames: item.spaceImageFilenames,
            currentIndex: item.folderImageIndex,
            order: item.playbackOrder,
            seed: item.playbackSeed,
            step: item.playbackStep,
            history: item.playbackHistory
        )
        guard let selection else { return false }

        if item.folderSizeMode == "dynamic" { saveFolderImageConfig(for: id) }
        photos[index].folderImageIndex = selection.index
        photos[index].playbackStep = selection.step
        photos[index].playbackHistory = selection.history
        let imageURL = images[selection.index]
        let currentItem = photos[index]

        guard let content = loadMediaContent(for: currentItem, filename: imageURL.lastPathComponent, primaryURL: imageURL) else {
            photos[index] = item
            recordMediaImportFailure("The next slideshow image could not be decoded. The current image has been kept.")
            return false
        }
        guard persist() else { photos[index] = item; return false }
        let targetFrame = currentItem.folderImageConfigs[imageURL.lastPathComponent].map { NSRectFromString($0.frameString) }
        windows[id]?.swapImage(content, targetFrame: targetFrame, mode: currentItem.folderSizeMode, animate: true)
        return true
    }

    @discardableResult
    func prevFolderImage(_ id: UUID) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let images = spaceImages[id], !images.isEmpty else { return false }

        let item = photos[index]

        if replacementConflictsWithArrangement(item) { return false }

        if item.folderSizeMode == "dynamic" {
            saveFolderImageConfig(for: id)
        }

        // Go back. No-repeat has no inverse without retaining a full replay stack, so a manual
        // previous action starts a fresh bag from the newly displayed image.
        let currentIndex = photos[index].folderImageIndex
        let previousIndex = SpacePlaybackSelector.previousIndex(
            filenames: item.spaceImageFilenames,
            currentIndex: currentIndex,
            order: item.playbackOrder
        ) ?? (currentIndex > 0 ? currentIndex - 1 : images.count - 1)
        photos[index].folderImageIndex = previousIndex
        photos[index].playbackStep &+= 1
        if item.playbackOrder == .noRepeat {
            photos[index].playbackHistory = [item.spaceImageFilenames[previousIndex]]
        } else {
            photos[index].playbackHistory = []
        }
        let imageURL = images[previousIndex]
        let currentItem = photos[index]

        guard let content = loadMediaContent(for: currentItem, filename: imageURL.lastPathComponent, primaryURL: imageURL) else {
            photos[index] = item
            recordMediaImportFailure("The previous slideshow image could not be decoded. The current image has been kept.")
            return false
        }
        guard persist() else { photos[index] = item; return false }
        let targetFrame = currentItem.folderImageConfigs[imageURL.lastPathComponent].map { NSRectFromString($0.frameString) }
        windows[id]?.swapImage(content, targetFrame: targetFrame, mode: currentItem.folderSizeMode, animate: true)
        return true
    }

    func setPlaybackOrder(_ id: UUID, _ order: SpacePlaybackOrder) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index]
        photos[index].playbackOrder = order
        photos[index].playbackStep = 0

        if order == .noRepeat,
           !photos[index].spaceImageFilenames.isEmpty {
            let filenames = photos[index].spaceImageFilenames
            let currentIndex = filenames.indices.contains(photos[index].folderImageIndex)
                ? photos[index].folderImageIndex
                : filenames.startIndex
            photos[index].playbackHistory = [filenames[currentIndex]]
        } else {
            photos[index].playbackHistory = []
        }
        guard persist() else { photos[index] = before; return }
    }

    func setRotationInterval(_ id: UUID, _ interval: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index].rotationInterval
        photos[index].rotationInterval = interval
        guard persist() else { photos[index].rotationInterval = before; return }
        setupRotationTimer(for: photos[index])
    }

    func setCustomRotationSeconds(_ id: UUID, _ seconds: Int) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index].customRotationSeconds
        photos[index].customRotationSeconds = max(5, seconds)  // minimum 5 seconds
        guard persist() else { photos[index].customRotationSeconds = before; return }
        // Restart timer if currently on custom
        if photos[index].rotationInterval == "custom" {
            setupRotationTimer(for: photos[index])
        }
    }

    func setFolderSizeMode(_ id: UUID, _ mode: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index]
        let oldMode = photos[index].folderSizeMode
        photos[index].folderSizeMode = mode

        if oldMode == "dynamic" && mode == "fixed" {
            // We just switched to fixed. Update the frameString to current frame so all images use it.
            if let window = windows[id] {
                photos[index].frameString = NSStringFromRect(window.photoFrame)
                photos[index].widgetWidth = window.photoFrame.width
            }
        }
        guard persist() else { photos[index] = before; return }

        if let view = windows[id]?.contentView as? DraggablePhotoView {
            view.setFocalPoint(
                photos[index].focalPoint,
                cropEnabled: !photos[index].spaceImageFilenames.isEmpty && mode == "fixed"
            )
        }

        // Trigger an immediate swap so the window resizes or adapts to the new mode
        if let images = spaceImages[id], !images.isEmpty,
           let imageURL = images[safe: photos[index].folderImageIndex] {
            if let content = loadMediaContent(for: photos[index], filename: imageURL.lastPathComponent, primaryURL: imageURL) {
                let key = imageURL.lastPathComponent
                let targetFrame = photos[index].folderImageConfigs[key].map { NSRectFromString($0.frameString) }
                windows[id]?.swapImage(content, targetFrame: targetFrame, mode: mode, animate: true)
            }
        }
    }

    func folderImageCount(_ id: UUID) -> Int {
        spaceImages[id]?.count
            ?? photos.first(where: { $0.id == id })?.spaceImageFilenames.count
            ?? 0
    }

    /// Runtime policy owns whether an automatic Space timer should exist. Cancelling the timer
    /// while a widget is fully occluded or the system is conserving energy avoids waking the app
    /// every interval; becoming visible again starts a fresh interval without changing the
    /// current slot or any persisted layout.
    private func handleRuntimeActivityChanged(_ id: UUID, decision: RuntimeActivityDecision) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }

        if decision.allowsRotation,
           photos[index].isVisible,
           !photos[index].isHiddenForDisplay,
           !photos[index].isHiddenForPresence,
           (!photos[index].spaceImageFilenames.isEmpty) {
            setupRotationTimer(for: photos[index])
        } else {
            rotationTimers[id]?.cancel()
            rotationTimers.removeValue(forKey: id)
        }
    }

    func setupRotationTimer(for item: PhotoItem) {
        // Rebuilding a timer is intentionally idempotent: runtime policy can deliver an
        // activation update at the same time as a normal visibility/settings path.
        rotationTimers[item.id]?.cancel()
        rotationTimers.removeValue(forKey: item.id)

        let seconds: Int?
        switch item.rotationInterval {
        case "30s":    seconds = 30
        case "5m":     seconds = 300
        case "hourly": seconds = 3600
        case "daily":  seconds = 86400
        case "custom": seconds = max(5, item.customRotationSeconds)
        default:       seconds = nil   // "click" doesn't use timers
        }

        guard let seconds else { return }
        guard item.isVisible,
              !item.isHiddenForDisplay,
              !item.isHiddenForPresence,
              (!item.spaceImageFilenames.isEmpty),
              let window = windows[item.id],
              window.runtimeActivityDecision.allowsRotation else { return }

        let itemID = item.id
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // The floating-point repeating overload traps when seconds overflow its
        // nanosecond conversion. Integral intervals safely saturate without
        // changing a large custom value retained in the user's saved layout.
        let interval = DispatchTimeInterval.seconds(seconds)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(Int(min(1, TimeInterval(seconds) * 0.05) * 1000)))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let window = self.windows[itemID],
                      window.runtimeActivityDecision.allowsRotation else { return }
                self.nextFolderImage(itemID)
            }
        }
        timer.resume()
        rotationTimers[item.id] = timer
    }

    /// Save the current window position/size for the currently displayed folder image.
    private func saveFolderImageConfig(for id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let images = spaceImages[id],
              let window = windows[id] else { return }
        let currentImage = images[safe: photos[index].folderImageIndex]
        if let key = currentImage?.lastPathComponent {
            photos[index].folderImageConfigs[key] = FolderImageConfig(
                frameString: NSStringFromRect(window.photoFrame),
                widgetWidth: window.photoFrame.width
            )
        }
    }

    // MARK: - Per-Display Profiles

    /// Ensures a saved frame is still reachable. Display geometry can shift between sessions
    /// (different arrangement, different resolution/scale), and a frame computed for a display
    /// that's since been swapped for a different physical unit sharing the same identifier
    /// fallback could in principle land fully off-screen — better to snap it back onto a
    /// visible screen than let the user lose track of a widget they can't see or drag back.
    private func clampToVisibleScreens(_ rect: NSRect) -> NSRect {
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(rect) }),
              let target = NSScreen.main ?? NSScreen.screens.first else { return rect }
        var clamped = rect
        clamped.origin.x = target.frame.midX - rect.width / 2
        clamped.origin.y = target.frame.midY - rect.height / 2
        return clamped
    }

    /// A container and its photos relocate as one scene. Clamping each photo
    /// separately after a monitor rearrangement destroys its saved arrangement.
    private func restoreCollageFramesToVisibleScreens(only ids: Set<UUID>? = nil) {
        for parent in photos.filter({ $0.desktopCollage != nil && ids?.contains($0.id) != false }) {
            let original = NSRectFromString(parent.frameString)
            guard original.width > 0, original.height > 0 else { continue }
            let target = clampToVisibleScreens(original)
            guard target.origin != original.origin else { continue }
            for i in photos.indices where photos[i].id == parent.id || photos[i].collageParentID == parent.id {
                let dx = target.minX - original.minX, dy = target.minY - original.minY
                let frame = NSRectFromString(photos[i].frameString).offsetBy(dx: dx, dy: dy)
                photos[i].frameString = NSStringFromRect(frame)
                if parent.desktopCollage != nil {
                    for key in Array(photos[i].folderImageConfigs.keys) {
                        if var config = photos[i].folderImageConfigs[key] {
                            config.frameString = NSStringFromRect(NSRectFromString(config.frameString).offsetBy(dx: dx, dy: dy))
                            photos[i].folderImageConfigs[key] = config
                        }
                    }
                }
                windows[photos[i].id]?.setPhotoFrame(frame)
            }
        }
    }

    /// A monitor may reconnect while Arras is closed, producing no live delta.
    func reconcileDisplayPresence(connected: Set<String>, only ids: Set<UUID>? = nil) {
        for index in photos.indices where ids?.contains(photos[index].id) != false {
            guard let display = photos[index].displayIdentifier else { continue }
            let wasHidden = photos[index].isHiddenForDisplay
            photos[index].isHiddenForDisplay = !connected.contains(display)
            if wasHidden && !photos[index].isHiddenForDisplay,
               let frame = photos[index].savedDisplayFrames[display] {
                photos[index].frameString = frame
            }
        }
    }

    private func handleScreenParametersChanged() {
        let diff = DisplayManager.shared.diffScreens()
        handleScreenChanges(connected: diff.connected, disconnected: diff.disconnected)
    }

    func handleScreenChanges(connected: Set<String>, disconnected: Set<String>) {
        let diff = (connected: connected, disconnected: disconnected)
        // Display profiles must capture durable geometry, never an unfinished
        // resize preview from a window that is about to disappear.
        cancelCollageInteractions(endAppearancePreviews: true)

        // Hide photos whose home display just vanished, remembering exactly where they were.
        if !diff.disconnected.isEmpty {
            for index in photos.indices {
                guard photos[index].isVisible, !photos[index].isHiddenForDisplay,
                      let displayId = photos[index].displayIdentifier,
                      diff.disconnected.contains(displayId) else { continue }

                let id = photos[index].id
                if let window = windows[id] {
                    photos[index].savedDisplayFrames[displayId] = NSStringFromRect(window.photoFrame)
                    window.hidePhoto()
                    windows.removeValue(forKey: id)
                }
                rotationTimers[id]?.cancel()
                rotationTimers.removeValue(forKey: id)
                photos[index].isHiddenForDisplay = true
            }
        }

        // Restore the model before rebuilding windows, so a reconnected group
        // can be translated together onto the display's new coordinate origin.
        if !diff.connected.isEmpty {
            for index in photos.indices {
                guard photos[index].isVisible, photos[index].isHiddenForDisplay,
                      let displayId = photos[index].displayIdentifier, diff.connected.contains(displayId) else { continue }
                photos[index].isHiddenForDisplay = false
                if let savedFrame = photos[index].savedDisplayFrames[displayId] { photos[index].frameString = savedFrame }
            }
        }
        restoreCollageFramesToVisibleScreens()
        for item in photos where item.isVisible && !item.isHiddenForDisplay && !item.isHiddenForPresence {
            if windows[item.id] == nil {
                guard let content = loadDisplayContent(for: item) else { continue }
                createWindow(for: item, content: content)
                if !item.spaceImageFilenames.isEmpty { setupRotationTimer(for: item) }
            } else if item.collageParentID == nil && item.desktopCollage == nil, let window = windows[item.id] {
                let frame = clampToVisibleScreens(window.photoFrame)
                if frame != window.photoFrame { window.setPhotoFrame(frame) }
            }
        }
        saveAllPositions()

        syncCollages()
        persist()
    }

    // MARK: - Space Binding

    /// Space binding is best-effort: see the comment on `DesktopPhotoWindow.setSpaceBound` —
    /// there's no public API to target a specific Space by identity, so this pins the photo to
    /// whichever Space it's on right now rather than a persistent Space #N.
    func setSpaceBound(_ id: UUID, _ bound: Bool) {
        if let parent = photos.first(where: { $0.id == id })?.collageParentID { setSpaceBound(parent, bound); return }
        if !collageMoveSnapshots.isEmpty { cancelCollageInteractions() }
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[index].isSpaceBound
        photos[index].isSpaceBound = bound
        guard persist() else { photos[index].isSpaceBound = before; return }
        windows[id]?.setSpaceBound(bound)
        syncCollages()
    }

    // MARK: - Presence & Privacy

    /// Copies PresenceMonitor's current values into the published mirrors, with no other
    /// side effects. Used once at construction, before `loadSaved()` -- unlike
    /// `syncPresenceState()`, it must never call `reevaluatePresence()`/`persist()`, since
    /// `photos` is still empty at that point and persisting an empty array would
    /// overwrite the user's real `photos.json` before it's even been read.
    private func mirrorPresenceState() {
        excludeFromScreenCapture = presence.excludeFromScreenCapture
        autoHideForConferencingApps = presence.autoHideForConferencingApps
        hideWhenFullscreenActive = presence.hideWhenFullscreenActive
        isConferencingAppDetected = presence.isConferencingAppRunning
        isFullscreenAppDetected = presence.isFullscreenActive
    }

    /// Full response to a PresenceMonitor change once the app is running: refresh the
    /// published mirrors, push sharingType onto any already-open windows, and re-derive
    /// which windows should currently exist.
    private func syncPresenceState() {
        mirrorPresenceState()
        runtimeActivity.setPresenceSuppressed(presence.shouldSuppressForPresence)
        applyScreenCaptureExclusion()
        reevaluatePresence()
    }

    private func applyScreenCaptureExclusion() {
        let type: NSWindow.SharingType = presence.excludeFromScreenCapture ? .none : .readOnly
        for window in windows.values {
            window.sharingType = type
        }
        for window in collageLabelWindows.values { window.sharingType = type }
    }

    /// Whether `item` should currently be hidden for the global presence heuristics (fullscreen
    /// app / conferencing app), independent of the user's own `isVisible` choice. Legacy per-photo
    /// schedule values are intentionally ignored; they remain only so old stores can decode.
    private func isSuppressedForPresence(_: PhotoItem) -> Bool {
        return presence.shouldSuppressForPresence
    }

    /// Re-checks every visible, display-connected photo against `isSuppressedForPresence`
    /// and creates/tears down its window to match -- exactly like the per-display
    /// auto-hide path, `isVisible` is never touched here.
    private func reevaluatePresence() {
        for index in photos.indices {
            guard photos[index].isVisible, !photos[index].isHiddenForDisplay else { continue }
            let shouldHide = isSuppressedForPresence(photos[index])
            guard shouldHide != photos[index].isHiddenForPresence else { continue }
            photos[index].isHiddenForPresence = shouldHide
            let id = photos[index].id

            if shouldHide {
                windows[id]?.hidePhoto()
                windows.removeValue(forKey: id)
                rotationTimers[id]?.cancel()
                rotationTimers.removeValue(forKey: id)
            } else {
                let item = photos[index]
                if let content = loadDisplayContent(for: item) {
                    createWindow(for: item, content: content)
                } else {
                    recordMediaImportFailure("The stored image for \(label(for: item)) could not be decoded.")
                }
                if !item.spaceImageFilenames.isEmpty {
                    setupRotationTimer(for: item)
                }
            }
        }
        syncCollages()
        persist()
    }

    /// Retains the legacy window-sharing request for compatible capture tools.
    /// It does not guarantee exclusion from recording or sharing; see PresenceMonitor.
    func setExcludeFromScreenCapture(_ enabled: Bool) {
        presence.setExcludeFromScreenCapture(enabled)
        mirrorPresenceState()
        applyScreenCaptureExclusion()
    }

    /// Best-effort: auto-hides every photo while a known conferencing/recording app
    /// (Zoom, Teams, QuickTime, etc.) appears to be running. A running process is not
    /// the same thing as an active screen share -- see `PresenceMonitor`.
    func setAutoHideForConferencingApps(_ enabled: Bool) {
        presence.setAutoHideForConferencingApps(enabled)
    }

    /// Best-effort: auto-hides every photo while a fullscreen app appears to be
    /// frontmost. Desktop-level widgets are already invisible behind one; this exists to
    /// reclaim the memory and stop rotation timers rather than to hide anything visible.
    func setHideWhenFullscreenActive(_ enabled: Bool) {
        presence.setHideWhenFullscreenActive(enabled)
    }

    // MARK: - App Controls

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            print("Launch at login error: \(error)")
        }
    }

    /// Returns a small thumbnail for UI display.
    func thumbnail(for item: PhotoItem, size: CGFloat = 48) -> NSImage? {
        let sourceName: String
        if !item.spaceImageFilenames.isEmpty {
            sourceName = item.spaceImageFilenames[safe: item.folderImageIndex]
                ?? item.spaceImageFilenames.first ?? item.filename
        } else {
            sourceName = item.filename
        }
        let referenceKey = item.reference.renderKey
        let cacheKey = "\(sourceName)@\(Int(size))@\(referenceKey)" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }

        // UI thumbnails need one small still, never a decoded animation or a player.
        let media = item.photosLibraryAssets.first(where: { $0.managedFilename == sourceName })?.media
            ?? (item.filename == sourceName ? item.media : .still)
        let primaryURL = storageDir.appendingPathComponent(sourceName)
        let previewURL = media.posterFilename.map { storageDir.appendingPathComponent($0) } ?? primaryURL
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image: NSImage?
        if let source = CGImageSourceCreateWithURL(previewURL as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: max(1, Int(size * scale)),
               kCGImageSourceShouldCacheImmediately: true
           ] as CFDictionary) {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else if VideoMediaSupport.isSupportedVideoURL(primaryURL) {
            image = VideoMediaSupport.posterImage(for: primaryURL)
        } else {
            image = nil
        }

        guard let image, let sourceImage = PhotoReferenceRenderer.image(image, settings: item.reference), sourceImage.size.width > 0, sourceImage.size.height > 0 else {
            return nil
        }

        // Render into a real bitmap rather than returning an
        // NSImage(size:flipped:drawingHandler:).
        //
        // A drawing-handler image carries no representation until something asks it to
        // draw, and NSMenuItem doesn't render one — the menu bar's per-photo thumbnails
        // silently came out blank while the same image drew correctly in the SwiftUI
        // settings list. Baking a bitmap also means the scale/crop maths runs once
        // instead of on every redraw.
        let pixels = Int((size * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: size, height: size)   // point size, so Retina stays crisp

        // Aspect-fit inside the square, centred, so nothing is cropped.
        let aspectRatio = sourceImage.size.width / sourceImage.size.height
        let drawRect: NSRect
        if aspectRatio > 1 {
            let h = size / aspectRatio
            drawRect = NSRect(x: 0, y: (size - h) / 2, width: size, height: h)
        } else {
            let w = size * aspectRatio
            drawRect = NSRect(x: (size - w) / 2, y: 0, width: w, height: size)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let thumb = NSImage(size: NSSize(width: size, height: size))
        thumb.addRepresentation(rep)
        thumbnailCache.setObject(thumb, forKey: cacheKey, cost: rep.bytesPerRow * rep.pixelsHigh)
        return thumb
    }

    /// Drops cached thumbnails for a photo. Called wherever the bytes behind a filename can
    /// change or go away.
    func invalidateThumbnails(for item: PhotoItem) {
        // A filename can have thumbnails for multiple saved edits and arbitrary sizes.
        // Invalidating the bounded cache also clears those snapshot variants.
        thumbnailCache.removeAllObjects()
    }

    /// Label for a photo.
    func label(for item: PhotoItem) -> String {
        if let name = item.customName, !name.isEmpty {
            return name
        }
        guard let index = photos.firstIndex(where: { $0.id == item.id }) else { return "Photo" }
        return "Photo \(index + 1)"
    }
}

// MARK: - Safe Array Access

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
