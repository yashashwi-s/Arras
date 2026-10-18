import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

/// The persisted state of a Finder-backed Space. A live folder always owns a managed snapshot
/// in the Photo Widget store; the source is only used to discover changes and is never needed to
/// render an already-saved Space.
enum LiveFolderStatus: String, Codable, Equatable, Sendable {
    case active
    case empty
    case missing
    case needsRelink

    var displayName: String {
        switch self {
        case .active: return "Live"
        case .empty: return "Folder is empty"
        case .missing: return "Folder unavailable"
        case .needsRelink: return "Needs relink"
        }
    }

    var needsRelink: Bool {
        self == .missing || self == .needsRelink
    }
}

/// Metadata kept alongside a live Space. `bookmarkData` is intentionally optional so a source
/// can be represented after an archive import without carrying a machine-specific bookmark.
struct LiveFolderSource: Codable, Equatable, Sendable {
    var bookmarkData: Data?
    var sourcePath: String
    var displayName: String
    var status: LiveFolderStatus
    var lastKnownResourceIdentifier: String?
    var lastReconciledAt: Date?

    init(
        bookmarkData: Data? = nil,
        sourcePath: String,
        displayName: String? = nil,
        status: LiveFolderStatus = .active,
        lastKnownResourceIdentifier: String? = nil,
        lastReconciledAt: Date? = nil
    ) {
        self.bookmarkData = bookmarkData
        self.sourcePath = sourcePath
        self.displayName = displayName ?? URL(fileURLWithPath: sourcePath).lastPathComponent
        self.status = status
        self.lastKnownResourceIdentifier = lastKnownResourceIdentifier
        self.lastReconciledAt = lastReconciledAt
    }

    private enum CodingKeys: String, CodingKey {
        case bookmarkData, sourcePath, displayName, status, lastKnownResourceIdentifier, lastReconciledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        let pathName = sourcePath.isEmpty ? "Live Folder" : URL(fileURLWithPath: sourcePath).lastPathComponent
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? pathName
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap(LiveFolderStatus.init(rawValue:)) ?? .needsRelink
        lastKnownResourceIdentifier = try container.decodeIfPresent(String.self, forKey: .lastKnownResourceIdentifier)
        lastReconciledAt = try container.decodeIfPresent(Date.self, forKey: .lastReconciledAt)
    }

    /// Archive-safe metadata. A bundle can still tell the recipient that the Space was live,
    /// while no path, bookmark, or resource fingerprint from the exporting Mac escapes.
    var archiveSnapshot: LiveFolderSource {
        LiveFolderSource(
            bookmarkData: nil,
            sourcePath: "",
            displayName: displayName,
            status: .needsRelink,
            lastKnownResourceIdentifier: nil,
            lastReconciledAt: nil
        )
    }
}

/// One managed copy belonging to one source file. Resource identifiers are preferred over paths
/// because they survive a rename within the same volume.
struct LiveFolderEntry: Codable, Equatable, Sendable {
    var sourceIdentifier: String
    var sourceName: String
    var managedFilename: String
    var sourceByteCount: Int64?
    var sourceModificationDate: Date?

    init(
        sourceIdentifier: String,
        sourceName: String,
        managedFilename: String,
        sourceByteCount: Int64? = nil,
        sourceModificationDate: Date? = nil
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.managedFilename = managedFilename
        self.sourceByteCount = sourceByteCount
        self.sourceModificationDate = sourceModificationDate
    }
}

/// File information used by the pure reconciliation policy. Keeping this independent of URL and
/// FileManager makes ordering, caps, rename handling, and current-item preservation unit-testable.
struct LiveFolderCandidate: Equatable, Sendable {
    let sourceIdentifier: String
    let sourceName: String
    let byteCount: Int64
    let modificationDate: Date?
}

struct LiveFolderReconciliation: Equatable, Sendable {
    let retained: [LiveFolderEntry]
    let added: [LiveFolderCandidate]
    let removed: [LiveFolderEntry]
    let selectedSourceIdentifier: String?
    let skipped: [LiveFolderCandidate]
}

enum LiveFolderSpacePolicy {
    /// A live Space is a durable local cache. These limits prevent an accidentally selected
    /// camera/card archive from becoming an unbounded second media library.
    static let maxManagedFiles = 200
    static let maxManagedBytes: Int64 = 256 * 1024 * 1024

    /// Selects a deterministic, bounded subset while giving the currently displayed source file
    /// priority. The returned order follows the caller's sorted candidate order.
    static func boundedCandidates(
        _ candidates: [LiveFolderCandidate],
        currentSourceIdentifier: String?
    ) -> (selected: [LiveFolderCandidate], skipped: [LiveFolderCandidate]) {
        guard !candidates.isEmpty else { return ([], []) }

        var prioritized = candidates
        if let currentSourceIdentifier,
           let currentIndex = prioritized.firstIndex(where: { $0.sourceIdentifier == currentSourceIdentifier }) {
            let current = prioritized.remove(at: currentIndex)
            prioritized.insert(current, at: 0)
        }

        var selected: [LiveFolderCandidate] = []
        var skipped: [LiveFolderCandidate] = []
        var totalBytes: Int64 = 0

        for candidate in prioritized {
            let isCurrent = candidate.sourceIdentifier == currentSourceIdentifier
            guard selected.count < maxManagedFiles else {
                skipped.append(candidate)
                continue
            }

            // A currently displayed file is retained even when its source is larger than the
            // normal byte cap; otherwise a refresh could make the visible Space disappear.
            let normalizedBytes = max(candidate.byteCount, 0)
            let remainingBytes = maxManagedBytes - min(totalBytes, maxManagedBytes)
            let exceedsBytes = normalizedBytes > remainingBytes
            if exceedsBytes && !isCurrent {
                skipped.append(candidate)
                continue
            }

            selected.append(candidate)
            totalBytes += normalizedBytes
        }

        // Priority above changes only the selection order. Restore Finder's deterministic order
        // so rotation remains stable across rescans.
        let selectedIDs = Set(selected.map(\.sourceIdentifier))
        let ordered = candidates.filter { selectedIDs.contains($0.sourceIdentifier) }
        let selectedSet = Set(ordered.map(\.sourceIdentifier))
        let finalSkipped = candidates.filter { !selectedSet.contains($0.sourceIdentifier) }
        return (ordered, finalSkipped)
    }

    /// Reconciles by source identity. An unchanged identity reuses its managed filename, so a
    /// Finder rename updates the label without staging a duplicate copy.
    static func reconcile(
        existing: [LiveFolderEntry],
        candidates: [LiveFolderCandidate],
        currentSourceIdentifier: String?
    ) -> LiveFolderReconciliation {
        let bounded = boundedCandidates(candidates, currentSourceIdentifier: currentSourceIdentifier)
        let existingByID = Dictionary(existing.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let candidateIDs = Set(bounded.selected.map(\.sourceIdentifier))

        var retained: [LiveFolderEntry] = []
        var added: [LiveFolderCandidate] = []
        for candidate in bounded.selected {
            if let old = existingByID[candidate.sourceIdentifier] {
                retained.append(
                    LiveFolderEntry(
                        sourceIdentifier: candidate.sourceIdentifier,
                        sourceName: candidate.sourceName,
                        managedFilename: old.managedFilename,
                        sourceByteCount: candidate.byteCount,
                        sourceModificationDate: candidate.modificationDate
                    )
                )
            } else {
                added.append(candidate)
            }
        }

        let removed = existing.filter { !candidateIDs.contains($0.sourceIdentifier) }
        let selectedID = bounded.selected.contains(where: { $0.sourceIdentifier == currentSourceIdentifier })
            ? currentSourceIdentifier
            : bounded.selected.first?.sourceIdentifier
        return LiveFolderReconciliation(
            retained: retained,
            added: added,
            removed: removed,
            selectedSourceIdentifier: selectedID,
            skipped: bounded.skipped
        )
    }
}

/// A low-overhead watcher for one selected directory. The callback only schedules a debounced
/// main-actor reconciliation; no source file is opened by the desktop renderer.
final class LiveFolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init(url: URL, queue: DispatchQueue, handler: @escaping () -> Void) throws {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileNoSuchFile)
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func cancel() {
        source.cancel()
    }
}

private struct LiveFolderScan: Sendable {
    let candidates: [LiveFolderCandidate]
    let failure: LiveFolderStatus?
}

private enum LiveFolderScanner {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .fileResourceIdentifierKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .nameKey
    ]

    static func scan(_ folderURL: URL) -> LiveFolderScan {
        guard let folderValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey]),
              folderValues.isDirectory == true else {
            return LiveFolderScan(candidates: [], failure: .missing)
        }

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return LiveFolderScan(candidates: [], failure: .missing)
        }

        var candidates: [LiveFolderCandidate] = []
        var seenIdentifiers = Set<String>()
        for fileURL in urls {
            // A live-folder Space has one filename per slot and remains an image-only snapshot;
            // standalone video widgets use the richer managed-media path instead.
            guard PhotoImportPolicy.isImage(fileURL) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }

            let identifier = resourceIdentifier(values, fallback: fileURL.standardizedFileURL.path)
            guard seenIdentifiers.insert(identifier).inserted else { continue }
            candidates.append(
                LiveFolderCandidate(
                    sourceIdentifier: identifier,
                    sourceName: values.name ?? fileURL.lastPathComponent,
                    byteCount: Int64(values.fileSize ?? 0),
                    modificationDate: values.contentModificationDate
                )
            )
        }

        candidates.sort {
            let nameOrder = $0.sourceName.localizedStandardCompare($1.sourceName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.sourceIdentifier < $1.sourceIdentifier
        }
        return LiveFolderScan(candidates: candidates, failure: candidates.isEmpty ? .empty : nil)
    }

    private static func resourceIdentifier(_ values: URLResourceValues, fallback: String) -> String {
        if let identifier = values.fileResourceIdentifier {
            return String(describing: identifier)
        }
        return fallback
    }
}

// MARK: - PhotoManager live-folder Spaces

extension PhotoManager {
    private static let liveFolderDebounceNanoseconds: UInt64 = 180_000_000

    /// Runtime-only watcher storage. Weak manager keys let temporary managers release their
    /// watchers while keeping Codable state a small, backward-compatible value model.
    private static let liveFolderRuntimeLock = NSLock()
    private static let liveFolderRuntime = NSMapTable<PhotoManager, LiveFolderRuntimeState>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private final class LiveFolderRuntimeState {
        var watchers: [UUID: LiveFolderWatcher] = [:]
        var tasks: [UUID: Task<Void, Never>] = [:]
        var notificationTokens: [NSObjectProtocol] = []
    }

    private var liveFolderState: LiveFolderRuntimeState {
        Self.liveFolderRuntimeLock.lock()
        defer { Self.liveFolderRuntimeLock.unlock() }
        if let state = Self.liveFolderRuntime.object(forKey: self) { return state }
        let state = LiveFolderRuntimeState()
        Self.liveFolderRuntime.setObject(state, forKey: self)
        return state
    }

    /// Adds a live Space from a user-selected Finder directory. The initial snapshot is made
    /// through `PhotoIngest.prepare`, exactly like ordinary image imports.
    @discardableResult
    func addLiveFolderSpace(_ folderURL: URL, requiresSecurityScope: Bool = true) async -> ImportBatchResult {
        let source = makeLiveFolderSource(for: folderURL)
        return await createOrRefreshLiveFolderSpace(
            folderURL: folderURL,
            source: source,
            requiresSecurityScope: requiresSecurityScope
        )
    }

    /// Rebinds a missing or archived live Space to a newly selected folder.
    @discardableResult
    func relinkLiveFolder(_ id: UUID, to folderURL: URL) async -> ImportBatchResult {
        guard let index = photos.firstIndex(where: { $0.id == id }), photos[index].liveFolderSource != nil else {
            return ImportBatchResult(entries: [
                .init(source: folderURL.lastPathComponent, status: .failed, reason: "The live folder Space no longer exists.")
            ])
        }

        let oldSource = photos[index].liveFolderSource!
        stopLiveFolderWatcher(for: id)
        let source = makeLiveFolderSource(for: folderURL)
        photos[index].liveFolderSource = source
        guard persist() else {
            photos[index].liveFolderSource = oldSource
            installLiveFolderWatcher(for: photos[index])
            return ImportBatchResult(entries: [
                .init(source: folderURL.lastPathComponent, status: .failed, reason: "The folder link could not be saved.")
            ])
        }
        return await reconcileLiveFolder(id, folderURL: folderURL, requiresSecurityScope: true)
    }

    /// Explicit refresh used by the row/menu and by mount notifications. Tests can use
    /// `requiresSecurityScope: false` with a temporary directory outside the sandbox.
    @discardableResult
    func reconcileLiveFolder(
        _ id: UUID,
        folderURL: URL? = nil,
        requiresSecurityScope: Bool = true
    ) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard let initialIndex = photos.firstIndex(where: { $0.id == id }),
              let source = photos[initialIndex].liveFolderSource else {
            return ImportBatchResult()
        }
        let expectedEntries = photos[initialIndex].liveFolderEntries
        let expectedFilenames = photos[initialIndex].spaceImageFilenames
        let generation = desktopGeneration

        func currentIndexIfUnchanged() -> Int? {
            guard !Task.isCancelled, desktopGeneration == generation,
                  let currentIndex = photos.firstIndex(where: { $0.id == id }),
                  photos[currentIndex].liveFolderSource == source,
                  photos[currentIndex].liveFolderEntries == expectedEntries,
                  photos[currentIndex].spaceImageFilenames == expectedFilenames else { return nil }
            return currentIndex
        }

        func statusSaveFailure() -> ImportBatchResult {
            ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed,
                      reason: "The folder status could not be saved; the previous snapshot remains available.")
            ])
        }

        let resolved = resolveLiveFolderSource(source, overrideURL: folderURL, requiresSecurityScope: requiresSecurityScope)
        guard let access = resolved else {
            guard let index = currentIndexIfUnchanged() else { return ImportBatchResult() }
            var unavailable = source
            unavailable.status = source.bookmarkData == nil ? .needsRelink : .missing
            guard storeLiveFolderSource(photos[index].id, source: unavailable) else { return statusSaveFailure() }
            if source.status == .needsRelink || source.status == .missing {
                return ImportBatchResult(entries: [
                    .init(source: source.displayName, status: .failed, reason: "The folder is unavailable. Choose Relink Folder… to select it again.")
                ])
            }
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: "The folder could not be opened. Choose Relink Folder… to select it again.")
            ])
        }

        let scanURL = access.url
        let scan = await Task.detached(priority: .utility) {
            LiveFolderScanner.scan(scanURL)
        }.value
        defer { access.stop() }

        guard let index = currentIndexIfUnchanged() else { return ImportBatchResult() }

        guard scan.failure != .missing else {
            var unavailable = source
            unavailable.status = .missing
            guard storeLiveFolderSource(id, source: unavailable) else { return statusSaveFailure() }
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: "The folder is unavailable; the last managed snapshot is still safe to display.")
            ])
        }

        // An empty folder is a valid, reachable source. Keep the last managed snapshot so the
        // widget remains usable, but expose the empty state instead of silently deleting media.
        if scan.candidates.isEmpty {
            var empty = source
            empty.status = .empty
            empty.lastReconciledAt = Date()
            guard storeLiveFolderSource(id, source: empty) else { return statusSaveFailure() }
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .skipped, reason: "No supported images were found; the last managed snapshot remains available.")
            ])
        }

        let item = photos[index]
        let currentIdentifier = item.liveFolderEntries[safe: item.folderImageIndex]?.sourceIdentifier
        let reconciliation = LiveFolderSpacePolicy.reconcile(
            existing: item.liveFolderEntries,
            candidates: scan.candidates,
            currentSourceIdentifier: currentIdentifier
        )

        let existingByID = Dictionary(item.liveFolderEntries.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let directory = storageDir
        let prepare = prepareImportedURL
        let preparedAdded = await withTaskGroup(of: (LiveFolderCandidate, PhotoIngest.Prepared?).self) { group in
            for candidate in reconciliation.added {
                let sourceURL = access.url.appendingPathComponent(candidate.sourceName, isDirectory: false)
                group.addTask {
                    (candidate, prepare(sourceURL, directory))
                }
            }
            var values: [(LiveFolderCandidate, PhotoIngest.Prepared?)] = []
            for await value in group { values.append(value) }
            return values
        }

        var entries: [ImportBatchResult.Entry] = []
        var addedByID: [String: LiveFolderEntry] = [:]
        var preparedFidelity: [String: ArchiveMediaFidelity] = [:]
        var failedAddedIDs = Set<String>()
        for (candidate, prepared) in preparedAdded {
            guard let prepared else {
                failedAddedIDs.insert(candidate.sourceIdentifier)
                entries.append(.init(source: candidate.sourceName, status: .failed, reason: "The source image could not be read or decoded."))
                continue
            }
            guard PhotoContent.load(from: prepared.url) != nil else {
                for url in prepared.managedURLs { try? FileManager.default.removeItem(at: url) }
                failedAddedIDs.insert(candidate.sourceIdentifier)
                entries.append(.init(source: candidate.sourceName, status: .failed, reason: "The source image could not be read or decoded."))
                continue
            }
            addedByID[candidate.sourceIdentifier] = LiveFolderEntry(
                sourceIdentifier: candidate.sourceIdentifier,
                sourceName: candidate.sourceName,
                managedFilename: prepared.filename,
                sourceByteCount: candidate.byteCount,
                sourceModificationDate: candidate.modificationDate
            )
            preparedFidelity.merge(prepared.mediaFidelityByFilename) { _, new in new }
            entries.append(.init(source: candidate.sourceName, status: .accepted))
        }

        // A file's resource identity can remain while its bytes change. Re-stage only that one
        // managed copy, and never read the source from the renderer itself.
        var replacements: [LiveFolderEntry] = []
        var failedReplacementIDs = Set<String>()
        for candidate in reconciliation.retained {
            guard currentIndexIfUnchanged() != nil else { break }
            guard let old = existingByID[candidate.sourceIdentifier] else { continue }
            if old.sourceByteCount != candidate.sourceByteCount || old.sourceModificationDate != candidate.sourceModificationDate {
                let sourceURL = access.url.appendingPathComponent(candidate.sourceName, isDirectory: false)
                let prepared = await Task.detached(priority: .utility) {
                    prepare(sourceURL, directory)
                }.value
                if let prepared {
                    guard PhotoContent.load(from: prepared.url) != nil else {
                        for url in prepared.managedURLs { try? FileManager.default.removeItem(at: url) }
                        failedReplacementIDs.insert(candidate.sourceIdentifier)
                        entries.append(.init(source: candidate.sourceName, status: .failed, reason: "The changed source image could not be read or decoded."))
                        continue
                    }
                    replacements.append(
                        LiveFolderEntry(
                            sourceIdentifier: candidate.sourceIdentifier,
                            sourceName: candidate.sourceName,
                            managedFilename: prepared.filename,
                            sourceByteCount: candidate.sourceByteCount,
                            sourceModificationDate: candidate.sourceModificationDate
                        )
                    )
                    preparedFidelity.merge(prepared.mediaFidelityByFilename) { _, new in new }
                    entries.append(.init(source: candidate.sourceName, status: .accepted))
                } else {
                    failedReplacementIDs.insert(candidate.sourceIdentifier)
                    entries.append(.init(source: candidate.sourceName, status: .failed, reason: "The changed source image could not be read or decoded."))
                }
            }
        }

        let replacementByID = Dictionary(replacements.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var finalEntries: [LiveFolderEntry] = []
        var managedNames: [String] = []
        for candidate in reconciliation.retained {
            guard !failedAddedIDs.contains(candidate.sourceIdentifier) else { continue }
            let final: LiveFolderEntry
            if failedReplacementIDs.contains(candidate.sourceIdentifier),
               let old = existingByID[candidate.sourceIdentifier] {
                // Keep the last known-good managed bytes and metadata so a later watcher event
                // retries the changed source instead of treating the failed copy as current.
                final = old
            } else {
                final = replacementByID[candidate.sourceIdentifier] ?? candidate
            }
            finalEntries.append(final)
            managedNames.append(final.managedFilename)
        }
        for candidate in reconciliation.added {
            guard let added = addedByID[candidate.sourceIdentifier] else { continue }
            finalEntries.append(added)
            managedNames.append(added.managedFilename)
        }

        // Keep the source order deterministic and the current source where possible.
        let orderedByID = Dictionary(finalEntries.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        finalEntries = scan.candidates.compactMap { orderedByID[$0.sourceIdentifier] }
        managedNames = finalEntries.map(\.managedFilename)

        guard let index = await waitForMediaReplacement(currentIndexIfUnchanged) else {
            for prepared in preparedAdded.compactMap(\.1) {
                for url in prepared.managedURLs { try? FileManager.default.removeItem(at: url) }
            }
            for replacement in replacements {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(replacement.managedFilename))
            }
            return ImportBatchResult()
        }

        if finalEntries.isEmpty && !scan.candidates.isEmpty {
            var active = source
            active.status = .active
            guard storeLiveFolderSource(id, source: active) else { return statusSaveFailure() }
            return ImportBatchResult(entries: entries)
        }

        let oldPhotos = photos
        let oldSpaceURLs = spaceImages[id]
        let oldItem = photos[index]
        let latestIdentifier = oldItem.liveFolderEntries[safe: oldItem.folderImageIndex]?.sourceIdentifier
        let currentID = latestIdentifier.flatMap { id in finalEntries.contains { $0.sourceIdentifier == id } ? id : nil }
        let selectedID = currentID ?? finalEntries.first?.sourceIdentifier
        photos[index].spaceImageFilenames = managedNames
        photos[index].liveFolderEntries = finalEntries
        let retainedNames = Set(managedNames)
        photos[index].mediaFidelity = photos[index].mediaFidelity.filter { retainedNames.contains($0.key) }
        photos[index].mediaFidelity.merge(preparedFidelity) { _, new in new }
        for filename in retainedNames where photos[index].mediaFidelity[filename] == nil {
            photos[index].mediaFidelity[filename] = .sourceBytes
        }
        photos[index].folderImageIndex = finalEntries.firstIndex(where: { $0.sourceIdentifier == selectedID }) ?? 0
        photos[index].liveFolderSource?.status = finalEntries.isEmpty ? .empty : .active
        photos[index].liveFolderSource?.lastKnownResourceIdentifier = finalEntries.first?.sourceIdentifier
        photos[index].liveFolderSource?.lastReconciledAt = Date()
        if let refreshedBookmark = refreshedBookmark(for: access.url, source: photos[index].liveFolderSource) {
            photos[index].liveFolderSource?.bookmarkData = refreshedBookmark
        }
        spaceImages[id] = managedNames.map { storageDir.appendingPathComponent($0) }

        guard persist() else {
            photos = oldPhotos
            spaceImages[id] = oldSpaceURLs
            for prepared in preparedAdded.compactMap(\.1) {
                for url in prepared.managedURLs { try? FileManager.default.removeItem(at: url) }
            }
            for replacement in replacements {
                if replacement.managedFilename != existingByID[replacement.sourceIdentifier]?.managedFilename {
                    try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(replacement.managedFilename))
                }
            }
            return ImportBatchResult(entries: entries + [
                .init(source: source.displayName, status: .failed, reason: "The live folder Space could not be saved.")
            ])
        }

        // The new model is durable. Only then remove old managed copies that no longer have a
        // reference. This also handles a rename without leaving a duplicate cache file.
        let oldManaged = Set(oldItem.spaceImageFilenames)
        let newManaged = Set(managedNames)
        for filename in oldManaged.subtracting(newManaged) {
            removeStoredFileIfUnreferenced(filename)
        }
        let displayedFilename = oldItem.spaceImageFilenames[safe: oldItem.folderImageIndex]
        let refreshedFilename = managedNames[safe: photos[index].folderImageIndex]
        // A new/renamed sibling does not change the displayed bytes. Re-decoding
        // the current slide would refit its native geometry and invalidate the
        // just-finished resize's history even though its media stayed the same.
        if displayedFilename != refreshedFilename { updateLiveFolderWindow(for: photos[index]) }
        installLiveFolderWatcher(for: photos[index])

        for skipped in reconciliation.skipped {
            entries.append(.init(source: skipped.sourceName, status: .skipped, reason: "The live Space cache limit was reached."))
        }
        if scan.candidates.isEmpty {
            entries.append(.init(source: source.displayName, status: .skipped, reason: "No supported images were found; the last managed snapshot remains available."))
        }
        return ImportBatchResult(entries: entries)
    }

    @discardableResult
    func storeLiveFolderSource(_ id: UUID, source: LiveFolderSource) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let previous = photos[index].liveFolderSource else { return false }
        photos[index].liveFolderSource = source
        guard persist() else {
            photos[index].liveFolderSource = previous
            return false
        }
        return true
    }

    func liveFolderStatusDescription(for id: UUID) -> String? {
        guard let source = photos.first(where: { $0.id == id })?.liveFolderSource else { return nil }
        return "\(source.displayName) · \(source.status.displayName)"
    }

    private func createOrRefreshLiveFolderSpace(
        folderURL: URL,
        source: LiveFolderSource,
        requiresSecurityScope: Bool
    ) async -> ImportBatchResult {
        let initial = await scanLiveFolderForImport(folderURL, source: source, requiresSecurityScope: requiresSecurityScope)
        guard !initial.entries.isEmpty, initial.acceptedCount > 0 else { return initial }

        // `scanLiveFolderForImport` creates one complete item, so this path cannot overwrite an
        // existing Space accidentally. The managed files are already durable only after commit.
        return initial
    }

    private func scanLiveFolderForImport(
        _ folderURL: URL,
        source: LiveFolderSource,
        requiresSecurityScope: Bool
    ) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        let generation = desktopGeneration
        guard let access = resolveLiveFolderSource(source, overrideURL: folderURL, requiresSecurityScope: requiresSecurityScope) else {
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: "The folder could not be opened. Choose a different folder.")
            ])
        }
        let scanURL = access.url
        let scan = await Task.detached(priority: .utility) { LiveFolderScanner.scan(scanURL) }.value
        defer { access.stop() }
        guard !Task.isCancelled, desktopGeneration == generation else { return ImportBatchResult() }
        guard scan.failure != .missing else {
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: "The folder is unavailable.")
            ])
        }
        guard !scan.candidates.isEmpty else {
            return ImportBatchResult(entries: [
                .init(source: source.displayName, status: .failed, reason: "The folder contains no supported images.")
            ])
        }

        let bounded = LiveFolderSpacePolicy.boundedCandidates(scan.candidates, currentSourceIdentifier: nil)
        let directory = storageDir
        let prepare = prepareImportedURL
        let prepared = await withTaskGroup(of: (LiveFolderCandidate, PhotoIngest.Prepared?).self) { group in
            for candidate in bounded.selected {
                let url = access.url.appendingPathComponent(candidate.sourceName, isDirectory: false)
                group.addTask { (candidate, prepare(url, directory)) }
            }
            var values: [(LiveFolderCandidate, PhotoIngest.Prepared?)] = []
            for await value in group { values.append(value) }
            return values
        }
        guard !Task.isCancelled, desktopGeneration == generation else {
            for (_, file) in prepared {
                for url in file?.managedURLs ?? [] { try? FileManager.default.removeItem(at: url) }
            }
            return ImportBatchResult(entries: bounded.selected.map {
                .init(source: $0.sourceName, status: .skipped,
                      reason: "The import was cancelled or the desktop changed. Add the folder again to this setup.")
            })
        }

        var valid: [LiveFolderEntry] = []
        var mediaFidelity: [String: ArchiveMediaFidelity] = [:]
        var resultEntries: [ImportBatchResult.Entry] = []
        for candidate in bounded.selected {
            guard let preparedFile = prepared.first(where: { $0.0.sourceIdentifier == candidate.sourceIdentifier })?.1 else {
                resultEntries.append(.init(source: candidate.sourceName, status: .failed, reason: "The source image could not be read or decoded."))
                continue
            }
            guard PhotoContent.load(from: preparedFile.url) != nil else {
                for url in preparedFile.managedURLs { try? FileManager.default.removeItem(at: url) }
                resultEntries.append(.init(source: candidate.sourceName, status: .failed, reason: "The source image could not be read or decoded."))
                continue
            }
            valid.append(.init(
                sourceIdentifier: candidate.sourceIdentifier,
                sourceName: candidate.sourceName,
                managedFilename: preparedFile.filename,
                sourceByteCount: candidate.byteCount,
                sourceModificationDate: candidate.modificationDate
            ))
            mediaFidelity.merge(preparedFile.mediaFidelityByFilename) { _, new in new }
            resultEntries.append(.init(source: candidate.sourceName, status: .accepted))
        }

        guard !valid.isEmpty else {
            for (_, preparedFile) in prepared { if let preparedFile { try? FileManager.default.removeItem(at: preparedFile.url) } }
            return ImportBatchResult(entries: resultEntries)
        }

        var item = PhotoItem(filename: "")
        item.customName = source.displayName
        item.spaceImageFilenames = valid.map(\.managedFilename)
        item.liveFolderEntries = valid
        item.mediaFidelity = mediaFidelity
        item.liveFolderSource = source
        item.liveFolderSource?.status = .active
        item.liveFolderSource?.lastKnownResourceIdentifier = valid.first?.sourceIdentifier
        item.liveFolderSource?.lastReconciledAt = Date()
        item.rotationInterval = "30s"
        item.folderSizeMode = "dynamic"

        guard commitImportedItems([item], replacing: false) else {
            for (_, preparedFile) in prepared { if let preparedFile { try? FileManager.default.removeItem(at: preparedFile.url) } }
            return ImportBatchResult(entries: resultEntries.map { .init(source: $0.source, status: .failed, reason: "The live folder Space could not be saved.") })
        }

        for skipped in bounded.skipped {
            resultEntries.append(.init(source: skipped.sourceName, status: .skipped, reason: "The live Space cache limit was reached."))
        }
        return ImportBatchResult(entries: resultEntries)
    }

    private struct LiveFolderAccess {
        let url: URL
        let didStartAccess: Bool
        let stop: () -> Void
    }

    private func resolveLiveFolderSource(
        _ source: LiveFolderSource,
        overrideURL: URL?,
        requiresSecurityScope: Bool
    ) -> LiveFolderAccess? {
        var stale = false
        let resolvedURL: URL?
        if let overrideURL {
            resolvedURL = overrideURL
        } else if let bookmarkData = source.bookmarkData {
            resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } else if !source.sourcePath.isEmpty {
            resolvedURL = URL(fileURLWithPath: source.sourcePath, isDirectory: true)
        } else {
            resolvedURL = nil
        }
        guard let url = resolvedURL else { return nil }

        let didStart = url.startAccessingSecurityScopedResource()
        guard !requiresSecurityScope || didStart else { return nil }
        let stop: () -> Void = { if didStart { url.stopAccessingSecurityScopedResource() } }
        return LiveFolderAccess(url: url, didStartAccess: didStart, stop: stop)
    }

    private func makeLiveFolderSource(for url: URL, displayName: String? = nil) -> LiveFolderSource {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        return LiveFolderSource(
            bookmarkData: bookmark,
            sourcePath: url.standardizedFileURL.path,
            displayName: displayName ?? url.lastPathComponent,
            status: bookmark == nil ? .needsRelink : .active
        )
    }

    private func refreshedBookmark(for url: URL, source: LiveFolderSource?) -> Data? {
        guard source?.bookmarkData != nil else { return nil }
        return try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func updateLiveFolderWindow(for item: PhotoItem) {
        guard let window = windows[item.id] else { return }
        let urls = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
        spaceImages[item.id] = urls
        guard let url = urls[safe: item.folderImageIndex], let content = PhotoContent.load(from: url) else { return }
        let key = url.lastPathComponent
        let targetFrame = item.folderImageConfigs[key].map { NSRectFromString($0.frameString) }
        window.swapImage(content, targetFrame: targetFrame, mode: item.folderSizeMode, animate: false)
        setupRotationTimer(for: item)
    }

    func installLiveFolderWatcher(for item: PhotoItem) {
        guard let source = item.liveFolderSource, !source.sourcePath.isEmpty else { return }
        liveFolderState.watchers[item.id]?.cancel()
        guard let access = resolveLiveFolderSource(source, overrideURL: nil, requiresSecurityScope: true) else {
            if let index = photos.firstIndex(where: { $0.id == item.id }),
               var unavailable = photos[index].liveFolderSource {
                unavailable.status = .needsRelink
                _ = storeLiveFolderSource(item.id, source: unavailable)
            }
            return
        }
        defer { access.stop() }
        do {
            let watcher = try LiveFolderWatcher(url: access.url, queue: .global(qos: .utility)) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleLiveFolderReconcile(item.id)
                }
            }
            liveFolderState.watchers[item.id] = watcher
        } catch {
            // A missing/unmounted source is represented in the model and can be relinked later.
            if let index = photos.firstIndex(where: { $0.id == item.id }),
               var unavailable = photos[index].liveFolderSource {
                unavailable.status = .missing
                _ = storeLiveFolderSource(item.id, source: unavailable)
            }
        }
    }

    // Called from PhotoManager's load/rebuild path in ImageManager.swift so watcher state is
    // restored after every durable model install.
    func installLiveFolderWatchers(only ids: Set<UUID>? = nil) {
        for item in photos where item.liveFolderSource != nil && ids?.contains(item.id) != false {
            installLiveFolderWatcher(for: item)
        }
        guard liveFolderState.notificationTokens.isEmpty else { return }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for item in self.photos where item.liveFolderSource?.status.needsRelink == true {
                        self.scheduleLiveFolderReconcile(item.id)
                    }
                }
            }
            liveFolderState.notificationTokens.append(token)
        }
    }

    func stopLiveFolderWatcher(for id: UUID) {
        liveFolderState.tasks[id]?.cancel()
        liveFolderState.tasks.removeValue(forKey: id)
        liveFolderState.watchers[id]?.cancel()
        liveFolderState.watchers.removeValue(forKey: id)
    }

    /// Bulk settings transactions need to discard a watcher when a duplicated item is rolled
    /// back after its single durable commit fails. Keep the actual watcher state private while
    /// exposing this narrow cleanup hook to the selection transaction.
    func stopLiveFolderWatcherForSelection(_ id: UUID) {
        stopLiveFolderWatcher(for: id)
    }

    func stopAllLiveFolderWatchers() {
        for task in liveFolderState.tasks.values { task.cancel() }
        liveFolderState.tasks.removeAll()
        for watcher in liveFolderState.watchers.values { watcher.cancel() }
        liveFolderState.watchers.removeAll()
        for token in liveFolderState.notificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        liveFolderState.notificationTokens.removeAll()
        Self.liveFolderRuntimeLock.lock()
        Self.liveFolderRuntime.removeObject(forKey: self)
        Self.liveFolderRuntimeLock.unlock()
    }

    private func scheduleLiveFolderReconcile(_ id: UUID) {
        liveFolderState.tasks[id]?.cancel()
        liveFolderState.tasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveFolderDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            _ = await self.reconcileLiveFolder(id)
        }
    }
}
