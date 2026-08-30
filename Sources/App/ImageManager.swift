import AppKit
import SwiftUI
import ServiceManagement

/// A persisted-state failure that needs a human decision rather than a silent fallback.
///
/// The settings panel keeps these visible until the user dismisses them. In particular, a
/// corrupt store is never treated as an empty first launch: doing so would let the next edit
/// overwrite the only evidence of what went wrong.
enum PersistenceFailureKind: String, CaseIterable, Equatable {
    case load
    case save
    case mediaImport

    var title: String {
        switch self {
        case .load: return "Photo library couldn't be read"
        case .save: return "Photo library couldn't be saved"
        case .mediaImport: return "Some media couldn't be added"
        }
    }

    var systemImage: String {
        switch self {
        case .load: return "doc.badge.gearshape"
        case .save: return "externaldrive.badge.exclamationmark"
        case .mediaImport: return "photo.badge.exclamationmark"
        }
    }
}

struct PersistenceFailure: Identifiable, Equatable {
    let id: UUID
    let kind: PersistenceFailureKind
    let detail: String
    let occurredAt: Date

    init(id: UUID = UUID(), kind: PersistenceFailureKind, detail: String, occurredAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.occurredAt = occurredAt
    }

    var title: String { kind.title }
}

/// One automatic snapshot of the JSON store. Media is deliberately not copied here: these
/// revisions are for recovering layout/state edits, while `.arras` remains the explicit media
/// backup format.
struct PhotoStoreRevision: Identifiable, Equatable {
    let url: URL
    let createdAt: Date

    var id: URL { url }
}

/// Manages multiple desktop photos, persistence, and settings.
@MainActor
class PhotoManager: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var launchAtLogin: Bool = false

    /// Persistent-state problems are intentionally model-owned so every Settings tab can show
    /// the same diagnosis. The array is bounded in `recordPersistenceFailure`.
    @Published private(set) var persistenceFailures: [PersistenceFailure] = []
    @Published private(set) var availableRevisions: [PhotoStoreRevision] = []

    // v1.6 — Presence & Privacy: mirrors of PresenceMonitor's toggles/detected state for
    // the Settings UI. Always go through the setX methods below rather than assigning
    // these directly -- PresenceMonitor owns the real (UserDefaults-backed) state, and
    // these are just a read mirror kept in sync via `syncPresenceState()`.
    @Published var excludeFromScreenCapture: Bool = false
    @Published var autoHideForConferencingApps: Bool = false
    @Published var hideWhenFullscreenActive: Bool = false
    @Published var isConferencingAppDetected: Bool = false
    @Published var isFullscreenAppDetected: Bool = false

    /// Not private: PhotoAppearanceControls.swift lives in another file and needs the same
    /// authoritative lookup. It used to scan `NSApp.windows` for a matching `photoId` instead,
    /// which silently resolved to a *closed* window — widget windows are deliberately never
    /// released (see `isReleasedWhenClosed` in createWindow), so they stay in `NSApp.windows`
    /// forever. After a single hide/show cycle, half the appearance panel stopped working.
    var windows: [UUID: DesktopPhotoWindow] = [:]

    // v1.4 — Spaces (Internal rotation timers)
    var spaceImages: [UUID: [URL]] = [:]
    private var rotationTimers: [UUID: DispatchSourceTimer] = [:]

    /// Rendered thumbnails, keyed by source filename and point size.
    ///
    /// `thumbnail(for:)` decodes the stored image at full resolution and draws it into a
    /// bitmap. It is called from `PhotoRowView`'s body — so once per visible row per SwiftUI
    /// pass — and from `rebuildMenu`, once per photo every time the status menu opens. With no
    /// cache, adding one photo to a library of twenty cost twenty full-resolution decodes on
    /// the main thread, and so did every click on the menu bar icon.
    private let thumbnailCache = NSCache<NSString, NSImage>()

    // v1.6 — Presence & Privacy
    private let presence = PresenceMonitor()
    private var scheduleTimer: DispatchSourceTimer?
    private let storageDirectoryOverride: URL?
    private var storeLoadBlocked = false
    private var didPreserveCorruptStore = false

    /// True while the current `photos.json` could not be decoded or read. The Settings
    /// recovery surface uses this to distinguish a genuinely blocked store from an unrelated
    /// media or best-effort save warning.
    var isStoreLoadBlocked: Bool { storeLoadBlocked }

    /// Five snapshots cover a short undo trail without turning a frequent frame-position save
    /// into an unbounded archive. A revision is a JSON state snapshot; source media stays in the
    /// normal store and is retained while a valid revision still references it.
    static let maxPhotoStoreRevisions = 5
    private static let maxCorruptStoreCopies = 5
    /// Orphan cleanup is deliberately bounded. A store can contain files from an interrupted
    /// import, but a single revision prune should never spend an unbounded amount of time
    /// walking or deleting user data.
    private static let maxOrphanedMediaCleanup = 32
    private static let managedMediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "bmp", "webp"
    ]

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

    init(storageDirectory: URL? = nil) {
        if let path = ProcessInfo.processInfo.environment["ARRAS_UI_TEST_STORAGE_DIR"], !path.isEmpty {
            storageDirectoryOverride = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            storageDirectoryOverride = storageDirectory
        }

        // Must run before anything reads photos.json: dropping the sandbox moved
        // the Application Support directory, and this carries older installs across.
        if storageDirectoryOverride == nil, !Self.didMigrateStorage {
            Self.didMigrateStorage = true
            StorageMigration.migrateIfNeeded(to: storageDir)
        }

        launchAtLogin = SMAppService.mainApp.status == .enabled

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
                self?.saveAllPositions()
                self?.persist()
            }
        }

        // v1.5 — Per-Display Profiles: hide/restore photos as monitors connect/disconnect
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        // v1.6 — Presence & Privacy: pick up PresenceMonitor's already-computed initial
        // state (no persist side effects -- see mirrorPresenceState()) and start reacting
        // to future changes. Registered after the initial mirror, and before loadSaved(),
        // so no callback can fire mid-construction: PresenceMonitor's own init() runs its
        // detection synchronously with onChange still nil, and NSWorkspace notifications
        // are always asynchronous, so nothing arrives until well after this initializer --
        // and therefore after loadSaved() below -- returns.
        mirrorPresenceState()
        presence.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.syncPresenceState() }
        }

        // Load saved photos immediately
        loadSaved()
    }

    // MARK: - Persistence

    func loadSaved() {
        refreshAvailableRevisions()
        guard FileManager.default.fileExists(atPath: dataFile.path) else { return }

        do {
            let data = try Data(contentsOf: dataFile)
            do {
                let items = try JSONDecoder().decode([PhotoItem].self, from: data)
                storeLoadBlocked = false
                installLoadedItems(items)
            } catch {
                storeLoadBlocked = true
                let preserved = preserveCorruptStore(data: data)
                var detail = "The existing photos.json could not be decoded: \(error.localizedDescription)."
                if let preserved {
                    detail += " A copy was preserved at \(preserved.path)."
                }
                if !availableRevisions.isEmpty {
                    detail += " Restore a previous revision from Settings."
                } else {
                    detail += " No valid automatic revision is available."
                }
                recordPersistenceFailure(.load, detail: detail)
            }
        } catch {
            storeLoadBlocked = true
            let preserved = preserveCorruptStore()
            var detail = "The existing photos.json could not be read: \(error.localizedDescription)."
            if let preserved {
                detail += " A copy was preserved at \(preserved.path)."
            }
            if !availableRevisions.isEmpty {
                detail += " Restore a previous revision from Settings."
            }
            recordPersistenceFailure(.load, detail: detail)
        }
    }

    /// Rebuilds windows from a decoded model. Keeping this in one place means an explicit
    /// revision restore follows the same presence, Space, display and animation rules as a
    /// normal relaunch instead of inventing a second loader.
    private func installLoadedItems(_ items: [PhotoItem]) {
        for window in windows.values { window.hidePhoto() }
        windows.removeAll()
        for timer in rotationTimers.values { timer.cancel() }
        rotationTimers.removeAll()
        spaceImages.removeAll()

        photos = items

        // Presence suppression (schedule / fullscreen / conferencing) depends on the
        // wall clock and on which apps happen to be running right now, neither of which
        // survives a relaunch, so it's recomputed fresh here rather than trusting
        // whatever was persisted last session.
        let now = Date()
        for index in photos.indices {
            photos[index].isHiddenForPresence = isSuppressedForPresence(photos[index], now: now)
        }

        // A photo that was auto-hidden because its display was disconnected stays invisible
        // on relaunch until that display reconnects (window presence == isVisible && !isHiddenForDisplay).
        // Ascending stackOrder: each orderFront puts the next one nearer the front, so the
        // saved front-to-back arrangement is rebuilt exactly.
        let ordered = photos
            .filter { $0.isVisible && !$0.isHiddenForDisplay && !$0.isHiddenForPresence }
            .sorted { $0.stackOrder < $1.stackOrder }
        var failedMedia = 0
        for item in ordered {
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
        reportMissingStoredMedia(in: items)
        scheduleNextSchedulerTick()
    }

    private func reportMissingStoredMedia(in items: [PhotoItem]) {
        let missing = items
            .flatMap { storedFilenames(in: $0) }
            .filter { !FileManager.default.fileExists(atPath: storageDir.appendingPathComponent($0).path) }
        guard !missing.isEmpty else { return }
        recordMediaImportFailure(
            "\(missing.count) stored image file\(missing.count == 1 ? "" : "s") is missing from the photo library."
        )
    }

    private func storedFilenames(in item: PhotoItem) -> [String] {
        var names: [String] = []
        if !item.filename.isEmpty { names.append(item.filename) }
        names.append(contentsOf: item.spaceImageFilenames)
        return names
    }

    /// Resolves what is currently due to be shown for `item` (single photo or the active
    /// frame of a Space), registering Space image URLs as a side effect. Shared by every path
    /// that brings a hidden photo back on screen: manual visibility toggle, load-on-launch, and
    /// display reconnect.
    ///
    /// Returns `PhotoContent` rather than `NSImage` so an animated widget keeps animating
    /// through all three of those paths, not just the initial add.
    private func loadDisplayContent(for item: PhotoItem) -> PhotoContent? {
        if !item.spaceImageFilenames.isEmpty {
            let urls = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            spaceImages[item.id] = urls
            if let imageURL = urls[safe: item.folderImageIndex],
               let content = PhotoContent.load(from: imageURL) {
                return content
            }
            return urls.first.flatMap { PhotoContent.load(from: $0) }
        } else {
            return PhotoContent.load(from: storageDir.appendingPathComponent(item.filename))
        }
    }

    /// Not private, for the same reason `windows` isn't — PhotoAppearanceControls.swift used
    /// to carry a byte-for-byte copy of this, which made two independent writers to the same
    /// file and a lost-update waiting to happen.
    @discardableResult
    func persist() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(photos)
        } catch {
            recordPersistenceFailure(.save, detail: "The current photo layout could not be encoded: \(error.localizedDescription).")
            return false
        }

        // A corrupt existing store must stay available for diagnosis. Requiring an explicit
        // restore before accepting another write is what prevents a later edit from erasing it.
        if storeLoadBlocked {
            recordPersistenceFailure(
                .save,
                detail: "The existing photos.json was not overwritten. Restore a valid revision from Settings before saving another change."
            )
            return false
        }

        let fileManager = FileManager.default
        let currentExists = fileManager.fileExists(atPath: dataFile.path)
        if currentExists {
            let current: Data
            do {
                current = try Data(contentsOf: dataFile)
            } catch {
                storeLoadBlocked = true
                let preserved = preserveCorruptStore()
                var detail = "The existing photos.json could not be read before saving: \(error.localizedDescription)."
                if let preserved { detail += " A copy was preserved at \(preserved.path)." }
                recordPersistenceFailure(.load, detail: detail)
                recordPersistenceFailure(.save, detail: "The photo layout was not saved because its previous state could not be read.")
                return false
            }

            // Validate the previous bytes before making them a recovery point. If another
            // process or a manual edit damaged the file, preserve it and refuse to replace it.
            do {
                _ = try JSONDecoder().decode([PhotoItem].self, from: current)
            } catch {
                storeLoadBlocked = true
                let preserved = preserveCorruptStore(data: current)
                var detail = "The existing photos.json could not be decoded before saving: \(error.localizedDescription)."
                if let preserved { detail += " A copy was preserved at \(preserved.path)." }
                recordPersistenceFailure(.load, detail: detail)
                recordPersistenceFailure(.save, detail: "The photo layout was not saved because its previous state was corrupt.")
                return false
            }

            // Repeated no-op writes (including a few AppKit callbacks) do not create a
            // revision. Every real write gets one bounded, valid predecessor snapshot.
            if current == data {
                clearPersistenceFailure(.save)
                refreshAvailableRevisions()
                return true
            }
            // The predecessor is the recovery guarantee. If it cannot be written, leave the
            // existing photos.json untouched rather than replacing the only known-good state
            // and merely displaying a warning after the fact.
            guard writeRevision(current) != nil else { return false }
            do {
                try fileManager.createDirectory(at: storageDir, withIntermediateDirectories: true)
                try data.write(to: dataFile, options: .atomic)
                clearPersistenceFailure(.save)
                refreshAvailableRevisions()
                return true
            } catch {
                // `.atomic` leaves the previous file in place when its replacement fails. The
                // recovery point above therefore remains valid and the in-memory edit stays
                // visible without claiming it survived a relaunch.
                recordPersistenceFailure(.save, detail: "The photo layout could not be saved: \(error.localizedDescription).")
                return false
            }
        }

        do {
            try fileManager.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try data.write(to: dataFile, options: .atomic)
            clearPersistenceFailure(.save)
            refreshAvailableRevisions()
            return true
        } catch {
            // `.atomic` leaves the previous file in place when its replacement fails. The
            // recovery point above therefore remains valid and the in-memory edit stays
            // visible without claiming it survived a relaunch.
            recordPersistenceFailure(.save, detail: "The photo layout could not be saved: \(error.localizedDescription).")
            return false
        }
    }

    /// A bounded snapshot of the last known-good JSON state. `persist()` treats this as a
    /// prerequisite for replacing `photos.json`, so a revision failure leaves the last known
    /// good store untouched.
    @discardableResult
    private func writeRevision(_ data: Data) -> URL? {
        do {
            try FileManager.default.createDirectory(at: revisionsDirectory, withIntermediateDirectories: true)
            let filename = "photos-\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString).json"
            let url = revisionsDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            pruneRevisions()
            refreshAvailableRevisions()
            return url
        } catch {
            recordPersistenceFailure(.save, detail: "A recovery revision could not be written: \(error.localizedDescription).")
            return nil
        }
    }

    private var revisionsDirectory: URL {
        storageDir.appendingPathComponent("photos-revisions", isDirectory: true)
    }

    private var corruptStoreDirectory: URL {
        storageDir.appendingPathComponent("photos-corrupt", isDirectory: true)
    }

    /// Keeps the damaged bytes under a unique name. Copying the original file is preferred so
    /// even a decode/read failure that is not representable as `Data` can be diagnosed later.
    private func preserveCorruptStore(data: Data? = nil) -> URL? {
        if didPreserveCorruptStore {
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

    private func refreshAvailableRevisions() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: revisionsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        availableRevisions = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      (try? JSONDecoder().decode([PhotoItem].self, from: data)) != nil else { return nil }
                return PhotoStoreRevision(url: url, createdAt: creationDate(for: url))
            }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.url.lastPathComponent > $1.url.lastPathComponent }
                return $0.createdAt > $1.createdAt
            }
    }

    private func creationDate(for url: URL) -> Date {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
              let date = values.creationDate else {
            return .distantPast
        }
        return date
    }

    private func pruneRevisions() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: revisionsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = creationDate(for: lhs)
            let right = creationDate(for: rhs)
            if left == right { return lhs.lastPathComponent > rhs.lastPathComponent }
            return left > right
        } ?? []
        for url in urls.dropFirst(Self.maxPhotoStoreRevisions) {
            try? FileManager.default.removeItem(at: url)
        }

        // A file can outlive the PhotoItem that used it when an import or replacement is
        // interrupted. Once a revision no longer protects that old state, clean only files that
        // are clearly media, are not referenced by the live model/current JSON/any valid
        // revision, and are within a small per-prune budget.
        cleanupOrphanedStoredMedia()
    }

    /// Returns filenames from valid JSON revisions. Invalid revision files are reported too:
    /// cleanup must stop conservatively when it cannot prove what a revision references.
    private func revisionStoredFilenames() -> (filenames: Set<String>, hasUnreadableRevision: Bool) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: revisionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "json" } ?? []

        var filenames = Set<String>()
        var hasUnreadableRevision = false
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let items = try? JSONDecoder().decode([PhotoItem].self, from: data) else {
                hasUnreadableRevision = true
                continue
            }
            filenames.formUnion(items.flatMap { storedFilenames(in: $0) })
        }
        return (filenames, hasUnreadableRevision)
    }

    /// Returns the current on-disk references, or nil when a current store exists but cannot be
    /// decoded. A corrupt current store must block orphan cleanup rather than turning a recovery
    /// problem into data loss.
    private func currentStoredFilenames() -> Set<String>? {
        guard FileManager.default.fileExists(atPath: dataFile.path) else { return [] }
        guard let data = try? Data(contentsOf: dataFile),
              let items = try? JSONDecoder().decode([PhotoItem].self, from: data) else {
            return nil
        }
        return Set(items.flatMap { storedFilenames(in: $0) })
    }

    private func cleanupOrphanedStoredMedia() {
        guard let current = currentStoredFilenames() else { return }
        let revisions = revisionStoredFilenames()
        guard !revisions.hasUnreadableRevision else { return }

        var referenced = current
        referenced.formUnion(photos.flatMap { storedFilenames(in: $0) })
        referenced.formUnion(revisions.filenames)

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var removed = 0
        for url in candidates where removed < Self.maxOrphanedMediaCleanup {
            guard Self.managedMediaExtensions.contains(url.pathExtension.lowercased()),
                  !referenced.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory != true else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }
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

    /// Replaces the live layout only after a selected, previously validated revision has been
    /// decoded and written successfully. There is no automatic fallback: choosing this action
    /// is the user's explicit recovery decision.
    @discardableResult
    func restoreLatestRevision() -> Bool {
        guard let revision = availableRevisions.first else { return false }
        return restoreRevision(revision)
    }

    @discardableResult
    func restoreRevision(_ revision: PhotoStoreRevision) -> Bool {
        let data: Data
        let items: [PhotoItem]
        do {
            data = try Data(contentsOf: revision.url)
            items = try JSONDecoder().decode([PhotoItem].self, from: data)
        } catch {
            recordPersistenceFailure(.load, detail: "The selected recovery revision could not be restored: \(error.localizedDescription).")
            return false
        }

        // Keep the state being replaced recoverable too. If this launch was already blocked on
        // corrupt input, preserveCorruptStore is idempotent and returns the existing copy.
        if storeLoadBlocked {
            let hadCurrentStore = FileManager.default.fileExists(atPath: dataFile.path)
            if hadCurrentStore, preserveCorruptStore() == nil {
                recordPersistenceFailure(
                    .save,
                    detail: "The selected layout was not restored because the corrupt photos.json could not be preserved."
                )
                return false
            }
        } else if FileManager.default.fileExists(atPath: dataFile.path) {
            do {
                let current = try Data(contentsOf: dataFile)
                if current != data {
                    guard writeRevision(current) != nil else { return false }
                }
            } catch {
                storeLoadBlocked = true
                let preserved = preserveCorruptStore()
                var detail = "The existing photos.json could not be read before restore: \(error.localizedDescription)."
                if let preserved { detail += " A copy was preserved at \(preserved.path)." }
                recordPersistenceFailure(.load, detail: detail)
                guard preserved != nil else {
                    recordPersistenceFailure(
                        .save,
                        detail: "The selected layout was not restored because the unreadable photos.json could not be preserved."
                    )
                    return false
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try data.write(to: dataFile, options: .atomic)
        } catch {
            recordPersistenceFailure(.save, detail: "The selected recovery revision could not be written: \(error.localizedDescription).")
            return false
        }

        storeLoadBlocked = false
        didPreserveCorruptStore = false
        clearPersistenceFailure(.load)
        clearPersistenceFailure(.save)
        installLoadedItems(items)
        refreshAvailableRevisions()
        return true
    }

    private func recordPersistenceFailure(_ kind: PersistenceFailureKind, detail: String) {
        if let index = persistenceFailures.firstIndex(where: { $0.kind == kind }) {
            let existing = persistenceFailures[index]
            persistenceFailures[index] = PersistenceFailure(id: existing.id, kind: kind, detail: detail)
        } else {
            persistenceFailures.append(PersistenceFailure(kind: kind, detail: detail))
            if persistenceFailures.count > 8 { persistenceFailures.removeFirst() }
        }
    }

    func recordMediaImportFailure(_ detail: String) {
        recordPersistenceFailure(.mediaImport, detail: detail)
    }

    private func clearPersistenceFailure(_ kind: PersistenceFailureKind) {
        persistenceFailures.removeAll { $0.kind == kind }
    }

    func dismissPersistenceFailure(_ id: UUID) {
        persistenceFailures.removeAll { $0.id == id }
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
    /// why re-muxing to GIF, rather than the JPEG transcode below, is the
    /// right call for those). Everything else keeps the app's original
    /// behavior of flattening to JPEG unchanged, so ordinary photo storage
    /// size/quality doesn't regress.
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

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            recordMediaImportFailure("The selected image could not be decoded.")
            return nil
        }
        let filename = UUID().uuidString + ".jpg"
        let url = storageDir.appendingPathComponent(filename)
        do {
            try jpegData.write(to: url)
            return (filename, url)
        } catch {
            recordMediaImportFailure("The selected image could not be stored: \(error.localizedDescription).")
            return nil
        }
    }

    func addPhoto(_ image: NSImage) {
        guard let (filename, url) = saveImportedImage(image) else {
            // `saveImportedImage` records the detailed conversion/write error where it has
            // context. Keep this guard explicit so every NSImage-based importer follows the
            // same failure path without creating a partial PhotoItem.
            return
        }

        let item = PhotoItem(filename: filename)
        photos.append(item)
        if let content = PhotoContent.load(from: url) {
            createWindow(for: item, content: content)
        } else {
            recordMediaImportFailure("The imported image could not be decoded after it was stored.")
        }
        guard persist() else {
            // The media file is staged before the model write. Keep it available for diagnosis
            // when the JSON write fails; a later explicit cleanup can remove it safely.
            return
        }
    }

    /// Removes one stored media file only when no other widget still points at it. Space
    /// duplication intentionally shares its filenames, so deletion must inspect both the
    /// single-image field and every Space slot before touching the bytes on disk.
    private func removeStoredFileIfUnreferenced(_ filename: String, excluding id: UUID? = nil, spaceSlotIndex: Int? = nil) {
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
            return candidate.filename == filename || candidate.spaceImageFilenames.contains(filename)
        }
        guard !stillReferenced else { return }

        // `persist()` writes the predecessor JSON before replacing the current file. Those
        // revisions are real references: deleting their media would make an explicit restore
        // recreate a PhotoItem that points at a missing file. Treat an unreadable revision as a
        // reason to keep the bytes until the user or bounded pruning resolves it.
        guard let current = currentStoredFilenames() else { return }
        let revisions = revisionStoredFilenames()
        guard !revisions.hasUnreadableRevision else { return }
        guard !current.contains(filename), !revisions.filenames.contains(filename) else { return }
        try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(filename))
    }



    func removePhoto(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        invalidateThumbnails(for: photos[index])
        let item = photos[index]

        windows[id]?.hidePhoto()
        windows.removeValue(forKey: id)

        spaceImages.removeValue(forKey: id)
        rotationTimers[id]?.cancel()
        rotationTimers.removeValue(forKey: id)

        photos.remove(at: index)
        // Keep media in place until the new JSON is durable. If saving fails, the previous
        // photos.json still references this item and must remain loadable on the next launch.
        if persist() {
            if !item.spaceImageFilenames.isEmpty {
                for filename in item.spaceImageFilenames {
                    removeStoredFileIfUnreferenced(filename)
                }
            } else {
                removeStoredFileIfUnreferenced(item.filename)
            }
        }
    }

    func removeAllPhotos() {
        let ids = photos.map { $0.id }
        for id in ids { removePhoto(id) }
    }

    /// Shows every photo, or hides every photo if any are currently showing.
    ///
    /// Biased toward hiding so the global hotkey behaves like a "get out of the
    /// way" key: one press always clears the desktop, the next restores it.
    /// - Returns: true if photos are visible after the toggle.
    @discardableResult
    func toggleAllVisibility() -> Bool {
        guard !photos.isEmpty else { return false }

        let anyVisible = photos.contains { $0.isVisible }
        let target = !anyVisible

        for photo in photos where photo.isVisible != target {
            toggleVisibility(photo.id)
        }
        return target
    }

    /// Appends a fully-formed item (e.g. from an imported `.tableau` layout bundle) and,
    /// if visible, creates its window. Image/space files must already be written into
    /// `storageDir` under the names in `item.filename` / `item.spaceImageFilenames`.
    /// Kept separate from `addPhoto`/`addSpace` since those synthesize a brand-new item
    /// from an `NSImage` rather than restoring one that already carries saved settings.
    func addImportedItem(_ item: PhotoItem) {
        photos.append(item)
        guard item.isVisible else { persist(); return }

        // Goes through the shared loader so an imported animated widget arrives
        // animating, rather than as a frozen first frame.
        if let content = loadDisplayContent(for: item) {
            createWindow(for: item, content: content)
        } else {
            recordMediaImportFailure("The imported widget's stored image could not be decoded.")
        }
        if !item.spaceImageFilenames.isEmpty {
            setupRotationTimer(for: item)
        }
        persist()
    }

    /// Adopts a batch of already-staged imported items in one durable model write. The caller
    /// has validated that every referenced media file decodes before reaching this point, so the
    /// only fallible operation here is the model save itself. Windows are rebuilt only after the
    /// save succeeds; if it fails, restoring the old value leaves both the in-memory layout and
    /// its existing windows untouched.
    @discardableResult
    func commitImportedItems(_ importedItems: [PhotoItem], replacing: Bool) -> Bool {
        guard !importedItems.isEmpty else { return false }

        let previousPhotos = photos
        let committedPhotos = replacing ? importedItems : previousPhotos + importedItems
        photos = committedPhotos

        guard persist() else {
            photos = previousPhotos
            return false
        }

        // Rebuild all runtime state (windows, Spaces, timers, presence suppression) only after
        // photos.json is durable. This also keeps import behavior aligned with relaunch and
        // explicit revision restore.
        installLoadedItems(committedPhotos)

        // A replacement may orphan the previous library's media. Do this last: until the model
        // commit succeeds, the old JSON is still the source of truth and must remain loadable.
        removeStoredFilesNoLongerReferenced(from: previousPhotos, after: committedPhotos)
        return true
    }

    private func removeStoredFilesNoLongerReferenced(from oldItems: [PhotoItem], after newItems: [PhotoItem]) {
        let oldFilenames = Set(oldItems.flatMap { storedFilenames(in: $0) }.filter { !$0.isEmpty })
        let newFilenames = Set(newItems.flatMap { storedFilenames(in: $0) }.filter { !$0.isEmpty })

        for filename in oldFilenames.subtracting(newFilenames) {
            // Keep the same revision-aware safety checks used by ordinary deletion: a previous
            // layout snapshot may still need this media for explicit recovery.
            removeStoredFileIfUnreferenced(filename)
        }
    }

    // MARK: - Window Creation

    func createWindow(for item: PhotoItem, content: PhotoContent) {
        let window = DesktopPhotoWindow()
        window.isReleasedWhenClosed = false
        window.photoId = item.id

        // v1.6 — Presence & Privacy: new windows pick up the current exclusion
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
        if rectToUse.width > 0 {
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
            guard let self, let i = self.photos.firstIndex(where: { $0.id == item.id }) else { return }
            self.photos[i].opacity = newOpacity
            self.persist()
        }

        window.onBringToFront = { [weak self] in self?.bringToFront(item.id) }
        window.onSendToBack = { [weak self] in self?.sendToBack(item.id) }

        // Click-to-advance for folder photos
        window.onClickAdvance = { [weak self] in
            guard let self else { return }
            if let idx = self.photos.firstIndex(where: { $0.id == item.id }),
               !self.photos[idx].spaceImageFilenames.isEmpty,
               self.photos[idx].rotationInterval == "click" {
                self.nextFolderImage(item.id)
            }
        }
        // Also wire it on the view
        (window.contentView as? DraggablePhotoView)?.onClickAdvance = window.onClickAdvance

        windows[item.id] = window
    }

    // MARK: - v1.1 Controls

    /// Raises a widget one step: in front of its siblings first, then up past the desktop
    /// icons, the system's desktop widgets and finally ordinary app windows.
    ///
    /// `orderFront` alone only reorders within a window level, so it can never move a photo
    /// past a desktop icon or a macOS widget — those sit at different levels entirely. Walking
    /// the depth once the widget already leads its own siblings is what makes repeated
    /// "Bring to Front" clicks actually climb the whole stack.
    func bringToFront(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let depth = photos[index].depth
        let siblings = photos.filter { $0.id != id && $0.depth == depth }

        if !siblings.allSatisfy({ $0.stackOrder < photos[index].stackOrder }) {
            photos[index].stackOrder = (photos.map(\.stackOrder).max() ?? 0) + 1
            windows[id]?.orderFront(nil)
            persist()
            return
        }
        if let next = WidgetDepth(stackIndex: depth.stackIndex + 1) {
            setDepth(id, next)
        }
    }

    /// The mirror of `bringToFront`: behind its siblings first, then down past the system
    /// widgets and the desktop icons.
    func sendToBack(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let depth = photos[index].depth
        let siblings = photos.filter { $0.id != id && $0.depth == depth }

        if !siblings.allSatisfy({ $0.stackOrder > photos[index].stackOrder }) {
            photos[index].stackOrder = (photos.map(\.stackOrder).min() ?? 0) - 1
            windows[id]?.orderBack(nil)
            persist()
            return
        }
        if let next = WidgetDepth(stackIndex: depth.stackIndex - 1) {
            setDepth(id, next)
        }
    }

    func setDepth(_ id: UUID, _ depth: WidgetDepth) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].depth = depth
        // Kept in sync so an older build reading this file still gets the floating state right.
        photos[index].isFloating = depth == .floating

        // Finder's desktop window covers the whole screen and consumes every click, so a widget
        // below it is unreachable by definition. Locking it is the honest thing to do: the
        // alternative is a widget the user cannot grab and cannot tell why.
        if !depth.isInteractive {
            photos[index].isLocked = true
            windows[id]?.setLocked(true)
        }

        windows[id]?.setDepth(depth)
        persist()
    }

    func setOpacity(_ id: UUID, _ value: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].opacity = max(0.1, min(1.0, value))
        windows[id]?.setPhotoOpacity(photos[index].opacity)
        persist()
    }

    func toggleLock(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isLocked.toggle()
        let locked = photos[index].isLocked

        windows[id]?.setLocked(locked)
        (windows[id]?.contentView as? DraggablePhotoView)?.flashLockState(locked)
        persist()
    }

    func toggleVisibility(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isVisible.toggle()

        if photos[index].isVisible {
            // A manual "Show" always wins over the display-disconnect and presence
            // (schedule / fullscreen / conferencing) auto-hides — otherwise a photo could
            // become permanently unreachable from the UI. This only wins until the next
            // presence re-evaluation (a schedule boundary, or the fullscreen/conferencing
            // state actually changing) re-applies the same rule from scratch — see
            // reevaluatePresence(). That mirrors how isHiddenForDisplay already behaves:
            // manual show wins now, not forever.
            photos[index].isHiddenForDisplay = false
            photos[index].isHiddenForPresence = false
            let item = photos[index]
            if let content = loadDisplayContent(for: item) {
                createWindow(for: item, content: content)
            } else {
                recordMediaImportFailure("The stored image for \(label(for: item)) could not be decoded.")
            }
            if !item.spaceImageFilenames.isEmpty {
                setupRotationTimer(for: item)
            }
        } else {
            windows[id]?.hidePhoto()
            windows.removeValue(forKey: id)
            rotationTimers[id]?.cancel()
            rotationTimers.removeValue(forKey: id)
        }
        persist()
    }

    func resize(_ id: UUID, to width: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].widgetWidth = width
        windows[id]?.resizeTo(width: width)
        persist()
    }

    // MARK: - v1.2 Naming & Organization

    func renamePhoto(_ id: UUID, to name: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].customName = name.isEmpty ? nil : name
        persist()
    }

    func replacePhoto(_ id: UUID, with newImage: NSImage) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let item = photos[index]
        invalidateThumbnails(for: item)

        // Stage the replacement before mutating the model. The generated filename means this
        // is a copy in our store, not an in-place write that could damage the last known-good
        // slot if encoding or decoding fails.
        guard let stored = saveImportedImage(newImage) else { return }

        // Only replace the primary file for single-image photos.
        if item.spaceImageFilenames.isEmpty {
            // The extension may change (still <-> animated), so this isn't
            // always an in-place overwrite of the old file.
            photos[index].filename = stored.filename

            if let content = PhotoContent.load(from: stored.url) {
                windows[id]?.swapImage(content, animate: true)
            } else {
                // Do not leave an undecodable replacement behind or change the model to point
                // at it. `saveImportedImage` normally produces a loadable file, but this keeps
                // a failed conversion recoverable if an encoder ever regresses.
                recordMediaImportFailure("The replacement image could not be decoded after it was stored.")
                photos[index].filename = item.filename
                removeStoredFileIfUnreferenced(stored.filename)
                return
            }

        } else {
            // A Space replacement targets the currently selected slot, not the whole Space.
            // Use the persisted filenames as the source of truth: hidden widgets do not have a
            // `spaceImages` entry yet, but must still get a durable replacement.
            let currentIndex = item.spaceImageFilenames.indices.contains(item.folderImageIndex)
                ? item.folderImageIndex
                : 0
            let oldFilename = item.spaceImageFilenames[currentIndex]
            // Configs are keyed by filename, so a malformed/legacy Space can have two slots
            // sharing one config. Keep the old key while another slot still uses it, and copy
            // the same frame to the newly stored filename for the replaced slot.
            let oldConfig = photos[index].folderImageConfigs[oldFilename]
            photos[index].spaceImageFilenames[currentIndex] = stored.filename
            if let oldConfig {
                photos[index].folderImageConfigs[stored.filename] = oldConfig
            }
            if !photos[index].spaceImageFilenames.contains(oldFilename) {
                photos[index].folderImageConfigs.removeValue(forKey: oldFilename)
            }

            // Keep the runtime URL cache in sync even when the widget is hidden (and therefore
            // had never gone through loadDisplayContent). This also makes the next menu
            // thumbnail/navigation lookup use the new bytes immediately.
            var urls = photos[index].spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            if urls.indices.contains(currentIndex) {
                urls[currentIndex] = stored.url
            }
            spaceImages[id] = urls

            guard let content = PhotoContent.load(from: stored.url) else {
                // Restore the old slot/configuration if the staged file cannot be decoded.
                recordMediaImportFailure("The replacement Space image could not be decoded after it was stored.")
                photos[index].spaceImageFilenames[currentIndex] = oldFilename
                if let oldConfig {
                    photos[index].folderImageConfigs.removeValue(forKey: stored.filename)
                    photos[index].folderImageConfigs[oldFilename] = oldConfig
                }
                spaceImages[id] = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
                removeStoredFileIfUnreferenced(stored.filename)
                return
            }

            // Dynamic Spaces keep the replaced slot's saved photo frame. Fixed Spaces keep the
            // existing frame regardless of the new image aspect ratio. Passing the mode here is
            // important: the generic swap default is dynamic, which would resize fixed Spaces.
            let targetFrame = oldConfig.map { NSRectFromString($0.frameString) }
            windows[id]?.swapImage(
                content,
                targetFrame: targetFrame,
                mode: item.folderSizeMode,
                animate: true
            )

        }

        // The old filename was invalidated above; invalidate the new key too so this remains
        // correct if a future ingest path reuses a generated filename in the same process.
        invalidateThumbnails(for: photos[index])
        let didPersist = persist()
        if didPersist {
            // Remove replaced bytes only after the new JSON is durable, and only when no other
            // PhotoItem still references the filename. If saving fails, keep both files so the
            // last known-good photos.json remains usable on the next launch.
            if item.spaceImageFilenames.isEmpty {
                removeStoredFileIfUnreferenced(item.filename, excluding: id)
            } else {
                let oldIndex = item.spaceImageFilenames.indices.contains(item.folderImageIndex)
                    ? item.folderImageIndex
                    : 0
                removeStoredFileIfUnreferenced(
                    item.spaceImageFilenames[oldIndex],
                    excluding: id,
                    spaceSlotIndex: oldIndex
                )
            }
        }
    }

    func duplicatePhoto(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let original = photos[index]

        if !original.spaceImageFilenames.isEmpty {
            // Duplicate folder photo — just copy the settings
            var newItem = PhotoItem(filename: "")
            newItem.customName = (original.customName ?? "Photo") + " (Copy)"
            newItem.spaceImageFilenames = original.spaceImageFilenames
            newItem.rotationInterval = original.rotationInterval
            newItem.folderImageIndex = original.folderImageIndex
            newItem.widgetWidth = original.widgetWidth
            copyAppearanceSettings(from: original, to: &newItem)

            // Offset position
            if !original.frameString.isEmpty {
                var rect = NSRectFromString(original.frameString)
                rect.origin.x += 30
                rect.origin.y -= 30
                newItem.frameString = NSStringFromRect(rect)
            }

            photos.append(newItem)

            if let images = spaceImages[original.id],
               let imageURL = images[safe: newItem.folderImageIndex],
               let content = PhotoContent.load(from: imageURL) {
                spaceImages[newItem.id] = images
                createWindow(for: newItem, content: content)
                setupRotationTimer(for: newItem)
            }
        } else {
            // Copy the file, preserving its extension -- an animated photo
            // is stored as `.gif`, and renaming the copy to `.jpg` while
            // keeping GIF bytes would make PhotoContent.load misidentify it
            // as a still on the next load.
            let ext = (original.filename as NSString).pathExtension
            let newFilename = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
            let srcURL = storageDir.appendingPathComponent(original.filename)
            let dstURL = storageDir.appendingPathComponent(newFilename)
            try? FileManager.default.copyItem(at: srcURL, to: dstURL)

            var newItem = PhotoItem(filename: newFilename, width: original.widgetWidth)
            newItem.customName = (original.customName ?? "Photo") + " (Copy)"
            copyAppearanceSettings(from: original, to: &newItem)

            // Offset position
            if !original.frameString.isEmpty {
                var rect = NSRectFromString(original.frameString)
                rect.origin.x += 30
                rect.origin.y -= 30
                newItem.frameString = NSStringFromRect(rect)
            }

            photos.append(newItem)

            if let content = PhotoContent.load(from: dstURL) {
                createWindow(for: newItem, content: content)
            }
        }

        persist()
    }

    func movePhoto(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < photos.count,
              destinationIndex >= 0, destinationIndex < photos.count else { return }
        let item = photos.remove(at: sourceIndex)
        photos.insert(item, at: destinationIndex)
        persist()
    }

    private func copyAppearanceSettings(from src: PhotoItem, to dst: inout PhotoItem) {
        dst.isFloating = src.isFloating
        dst.depth = src.depth
        dst.stackOrder = src.stackOrder
        dst.opacity = src.opacity
        dst.cornerRadius = src.cornerRadius
        dst.shadowEnabled = src.shadowEnabled
        dst.shadowBlur = src.shadowBlur
        dst.shadowOpacity = src.shadowOpacity
        dst.borderWidth = src.borderWidth
        dst.borderColorHex = src.borderColorHex
        dst.vignetteEnabled = src.vignetteEnabled
        dst.isSpaceBound = src.isSpaceBound

        // v2.2 frame styling. Duplicating a photo is almost always "give me
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

        // displayIdentifier / savedDisplayFrames / isHiddenForDisplay intentionally not copied —
        // the duplicate gets its own window and should pick up its own home display from
        // wherever createWindow actually places it.
        //
        // Presence suppression is likewise recomputed rather than inherited: it
        // describes the current moment, not the photo.
    }

    // MARK: - v1.3 Aesthetic Controls

    func setCornerRadius(_ id: UUID, _ value: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].cornerRadius = value
        (windows[id]?.contentView as? DraggablePhotoView)?.setCornerRadius(value)
        persist()
    }

    func setShadow(_ id: UUID, enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].shadowEnabled = enabled
        photos[index].shadowBlur = blur
        photos[index].shadowOpacity = opacity
        windows[id]?.applyShadowSettings(enabled: enabled, blur: blur, opacity: opacity)
        persist()
    }

    func setBorder(_ id: UUID, width: CGFloat, colorHex: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].borderWidth = width
        photos[index].borderColorHex = colorHex
        let color = NSColor.fromHex(colorHex) ?? .white
        (windows[id]?.contentView as? DraggablePhotoView)?.applyBorder(width: width, color: color)
        persist()
    }

    func setVignette(_ id: UUID, enabled: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].vignetteEnabled = enabled
        if enabled {
            (windows[id]?.contentView as? DraggablePhotoView)?.applyVignette()
        } else {
            (windows[id]?.contentView as? DraggablePhotoView)?.removeVignette()
        }
        persist()
    }

    // MARK: - v1.4 Smart Canvas





    func nextFolderImage(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              photos[index].isVisible,
              let images = spaceImages[id], !images.isEmpty else { return }

        let item = photos[index]

        if item.folderSizeMode == "dynamic" {
            saveFolderImageConfig(for: id)
        }

        // Advance
        photos[index].folderImageIndex = (photos[index].folderImageIndex + 1) % images.count
        let imageURL = images[photos[index].folderImageIndex]

        if let content = PhotoContent.load(from: imageURL) {
            let key = imageURL.lastPathComponent
            let targetFrame = item.folderImageConfigs[key].map { NSRectFromString($0.frameString) }
            windows[id]?.swapImage(content, targetFrame: targetFrame, mode: item.folderSizeMode, animate: true)
        }
        persist()
    }

    func prevFolderImage(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let images = spaceImages[id], !images.isEmpty else { return }

        let item = photos[index]

        if item.folderSizeMode == "dynamic" {
            saveFolderImageConfig(for: id)
        }

        // Go back
        let currentIndex = photos[index].folderImageIndex
        photos[index].folderImageIndex = currentIndex > 0 ? currentIndex - 1 : images.count - 1
        let imageURL = images[photos[index].folderImageIndex]

        if let content = PhotoContent.load(from: imageURL) {
            let key = imageURL.lastPathComponent
            let targetFrame = item.folderImageConfigs[key].map { NSRectFromString($0.frameString) }
            windows[id]?.swapImage(content, targetFrame: targetFrame, mode: item.folderSizeMode, animate: true)
        }
        persist()
    }

    func setRotationInterval(_ id: UUID, _ interval: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].rotationInterval = interval
        rotationTimers[id]?.cancel()
        rotationTimers.removeValue(forKey: id)
        setupRotationTimer(for: photos[index])
        persist()
    }

    func setCustomRotationSeconds(_ id: UUID, _ seconds: Int) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].customRotationSeconds = max(5, seconds)  // minimum 5 seconds
        // Restart timer if currently on custom
        if photos[index].rotationInterval == "custom" {
            rotationTimers[id]?.cancel()
            rotationTimers.removeValue(forKey: id)
            setupRotationTimer(for: photos[index])
        }
        persist()
    }

    func setFolderSizeMode(_ id: UUID, _ mode: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let oldMode = photos[index].folderSizeMode
        photos[index].folderSizeMode = mode

        if oldMode == "dynamic" && mode == "fixed" {
            // We just switched to fixed. Update the frameString to current frame so all images use it.
            if let window = windows[id] {
                photos[index].frameString = NSStringFromRect(window.photoFrame)
                photos[index].widgetWidth = window.photoFrame.width
            }
        }

        // Trigger an immediate swap so the window resizes or adapts to the new mode
        if let images = spaceImages[id], !images.isEmpty {
            let imageURL = images[photos[index].folderImageIndex]
            if let content = PhotoContent.load(from: imageURL) {
                let key = imageURL.lastPathComponent
                let targetFrame = photos[index].folderImageConfigs[key].map { NSRectFromString($0.frameString) }
                windows[id]?.swapImage(content, targetFrame: targetFrame, mode: mode, animate: true)
            }
        }
        persist()
    }

    func folderImageCount(_ id: UUID) -> Int {
        spaceImages[id]?.count
            ?? photos.first(where: { $0.id == id })?.spaceImageFilenames.count
            ?? 0
    }



    func setupRotationTimer(for item: PhotoItem) {
        let interval: TimeInterval?
        switch item.rotationInterval {
        case "30s":    interval = 30
        case "5m":     interval = 300
        case "hourly": interval = 3600
        case "daily":  interval = 86400
        case "custom": interval = TimeInterval(max(5, item.customRotationSeconds))
        default:       interval = nil   // "click" doesn't use timers
        }

        guard let seconds = interval else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            self?.nextFolderImage(item.id)
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

    // MARK: - v1.5 Per-Display Profiles

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

    private func handleScreenParametersChanged() {
        let diff = DisplayManager.shared.diffScreens()
        guard !diff.connected.isEmpty || !diff.disconnected.isEmpty else { return }

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

        // Restore photos whose home display just reappeared.
        if !diff.connected.isEmpty {
            for index in photos.indices {
                guard photos[index].isVisible, photos[index].isHiddenForDisplay,
                      let displayId = photos[index].displayIdentifier,
                      diff.connected.contains(displayId) else { continue }

                photos[index].isHiddenForDisplay = false
                if let savedFrame = photos[index].savedDisplayFrames[displayId] {
                    let rect = clampToVisibleScreens(NSRectFromString(savedFrame))
                    photos[index].frameString = NSStringFromRect(rect)
                }

                let item = photos[index]
                guard let content = loadDisplayContent(for: item) else {
                    recordMediaImportFailure("The stored image for \(label(for: item)) could not be decoded.")
                    continue
                }
                createWindow(for: item, content: content)
                if !item.spaceImageFilenames.isEmpty {
                    setupRotationTimer(for: item)
                }
            }
        }

        persist()
    }

    // MARK: - v1.5 Space Binding

    /// Space binding is best-effort: see the comment on `DesktopPhotoWindow.setSpaceBound` —
    /// there's no public API to target a specific Space by identity, so this pins the photo to
    /// whichever Space it's on right now rather than a persistent Space #N.
    func setSpaceBound(_ id: UUID, _ bound: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isSpaceBound = bound
        windows[id]?.setSpaceBound(bound)
        persist()
    }

    // MARK: - v1.6 Presence & Privacy

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
        applyScreenCaptureExclusion()
        reevaluatePresence()
    }

    private func applyScreenCaptureExclusion() {
        let type: NSWindow.SharingType = presence.excludeFromScreenCapture ? .none : .readOnly
        for window in windows.values {
            window.sharingType = type
        }
    }

    /// Whether `item` should currently be hidden for presence reasons -- outside its own
    /// schedule window, or either global heuristic (fullscreen app / conferencing app)
    /// currently tripped -- independent of the user's own `isVisible` choice.
    private func isSuppressedForPresence(_ item: PhotoItem, now: Date = Date()) -> Bool {
        if item.scheduleEnabled {
            let withinSchedule = Schedule.isActive(
                startMinutes: item.scheduleStartMinutes,
                endMinutes: item.scheduleEndMinutes,
                weekdayMask: item.scheduleWeekdays,
                at: now
            )
            if !withinSchedule { return true }
        }
        return presence.shouldSuppressForPresence
    }

    /// Re-checks every visible, display-connected photo against `isSuppressedForPresence`
    /// and creates/tears down its window to match -- exactly like the per-display
    /// auto-hide path, `isVisible` is never touched here.
    private func reevaluatePresence() {
        let now = Date()
        for index in photos.indices {
            guard photos[index].isVisible, !photos[index].isHiddenForDisplay else { continue }
            let shouldHide = isSuppressedForPresence(photos[index], now: now)
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
        persist()
    }

    /// Arms a single one-shot timer for the earliest moment any enabled schedule could
    /// flip active/inactive, then re-arms itself after firing. Deliberately not a
    /// per-minute poll: with no photos scheduled this holds no timer at all, and with
    /// several scheduled it still costs exactly one wakeup per boundary crossing.
    private func scheduleNextSchedulerTick() {
        scheduleTimer?.cancel()
        scheduleTimer = nil

        let enabledItems = photos.filter { $0.scheduleEnabled }
        guard !enabledItems.isEmpty else { return }

        let now = Date()
        let seconds = enabledItems
            .map { Schedule.secondsUntilNextBoundary(startMinutes: $0.scheduleStartMinutes, endMinutes: $0.scheduleEndMinutes, from: now) }
            .min() ?? 60

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.reevaluatePresence()
            self?.scheduleNextSchedulerTick()
        }
        timer.resume()
        scheduleTimer = timer
    }

    /// Reliable: sets `NSWindow.sharingType = .none` on every photo window, which the
    /// window server itself honors for any screen recording or video-conferencing share.
    /// See the type-level comment on `PresenceMonitor` for exactly what this does and
    /// does not cover.
    func setExcludeFromScreenCapture(_ enabled: Bool) {
        presence.setExcludeFromScreenCapture(enabled)
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

    /// Sets or updates a photo's show-only-during-this-window schedule.
    /// - Parameters:
    ///   - startMinutes/endMinutes: minutes after midnight; `endMinutes < startMinutes`
    ///     is an overnight window (e.g. 22:00-06:00). Both are wrapped into `0..<1440`
    ///     rather than validated, so a caller can't hand this an out-of-range value that
    ///     later fails to decode -- see PhotoItem's decoding discipline.
    ///   - weekdayMask: bitmask, bit (Calendar.weekday - 1): bit 0 = Sunday ... bit 6 = Saturday.
    func setSchedule(_ id: UUID, enabled: Bool, startMinutes: Int, endMinutes: Int, weekdayMask: Int) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].scheduleEnabled = enabled
        photos[index].scheduleStartMinutes = ((startMinutes % 1440) + 1440) % 1440
        photos[index].scheduleEndMinutes = ((endMinutes % 1440) + 1440) % 1440
        photos[index].scheduleWeekdays = weekdayMask
        reevaluatePresence()
        scheduleNextSchedulerTick()
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
        let cacheKey = "\(sourceName)@\(Int(size))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) { return cached }

        let image: NSImage?
        if !item.spaceImageFilenames.isEmpty {
            let images = spaceImages[item.id] ?? item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
            if let imageURL = images[safe: item.folderImageIndex] {
                image = NSImage(contentsOf: imageURL)
            } else {
                image = images.first.flatMap { NSImage(contentsOf: $0) }
            }
        } else {
            let url = storageDir.appendingPathComponent(item.filename)
            image = NSImage(contentsOf: url)
        }

        guard let sourceImage = image, sourceImage.size.width > 0, sourceImage.size.height > 0 else {
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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
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
        thumbnailCache.setObject(thumb, forKey: cacheKey)
        return thumb
    }

    /// Drops cached thumbnails for a photo. Called wherever the bytes behind a filename can
    /// change or go away.
    func invalidateThumbnails(for item: PhotoItem) {
        var names = item.spaceImageFilenames
        names.append(item.filename)
        for name in names {
            for size in [16, 48] {
                thumbnailCache.removeObject(forKey: "\(name)@\(size)" as NSString)
            }
        }
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
