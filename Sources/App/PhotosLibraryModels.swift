import Foundation

// MARK: - Durable Photos library metadata

/// The three collection families Arras can present without relying on Photos' private UI.
enum PhotosLibraryCollectionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case userAlbum = "user-album"
    case smartAlbum = "smart-album"
    case sharedAlbum = "shared-album"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userAlbum: return "Album"
        case .smartAlbum: return "Smart Album"
        case .sharedAlbum: return "Shared Album"
        }
    }
}

enum PhotosLibraryCollectionStatus: String, Codable, Equatable, Sendable {
    case active
    case empty
    case syncing
    case missing
    case needsRelink
    case failed

    var displayName: String {
        switch self {
        case .active: return "Live"
        case .empty: return "Album is empty"
        case .syncing: return "Syncing"
        case .missing: return "Album unavailable"
        case .needsRelink: return "Needs relink"
        case .failed: return "Refresh failed"
        }
    }

    var needsRelink: Bool {
        self == .missing || self == .needsRelink
    }
}

enum PhotosLibraryAssetStatus: String, Codable, Equatable, Sendable {
    case active
    case downloading
    case missing
    case inaccessible
    case failed
    case snapshot

    var displayName: String {
        switch self {
        case .active: return "Available"
        case .downloading: return "Downloading"
        case .missing: return "Missing from Photos"
        case .inaccessible: return "Not accessible"
        case .failed: return "Refresh failed"
        case .snapshot: return "Saved snapshot"
        }
    }
}

/// Metadata for a selected Photos album. The local identifier is deliberately optional in
/// archive snapshots: the managed files remain renderable, but a different Mac must explicitly
/// choose a replacement collection before any Photos reconciliation can resume.
struct PhotosLibrarySource: Codable, Equatable, Sendable {
    var localIdentifier: String
    var collectionType: PhotosLibraryCollectionType
    var displayName: String
    var status: PhotosLibraryCollectionStatus
    var lastReconciledAt: Date?
    var lastError: String?

    init(
        localIdentifier: String,
        collectionType: PhotosLibraryCollectionType,
        displayName: String,
        status: PhotosLibraryCollectionStatus = .active,
        lastReconciledAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.collectionType = collectionType
        self.displayName = displayName
        self.status = status
        self.lastReconciledAt = lastReconciledAt
        self.lastError = lastError
    }

    /// Removes the Photos library identity while retaining enough context to offer a reselect.
    var archiveSnapshot: PhotosLibrarySource {
        PhotosLibrarySource(
            localIdentifier: "",
            collectionType: collectionType,
            displayName: displayName,
            status: .needsRelink,
            lastReconciledAt: nil,
            lastError: nil
        )
    }
}

/// One Photos asset's durable identity and managed copies. The still is always the primary
/// filename; a Live Photo's paired movie and a standalone video's poster are related managed
/// files referenced through `media` and therefore travel through the normal archive path.
struct PhotosLibraryAsset: Codable, Equatable, Sendable {
    var localIdentifier: String
    var displayName: String
    var managedFilename: String
    var media: PhotoMedia
    var status: PhotosLibraryAssetStatus
    var sourceModificationDate: Date?
    var sourceByteCount: Int64?
    var pairedVideoByteCount: Int64?
    /// Resource-type codes identify the cached representation, not a Photos asset.
    /// Missing in older snapshots; revalidate once instead of assuming edited bytes.
    var sourceResourceTypes: [Int]?
    var lastError: String?

    init(
        localIdentifier: String,
        displayName: String,
        managedFilename: String,
        media: PhotoMedia = .still,
        status: PhotosLibraryAssetStatus = .active,
        sourceModificationDate: Date? = nil,
        sourceByteCount: Int64? = nil,
        pairedVideoByteCount: Int64? = nil,
        sourceResourceTypes: [Int]? = nil,
        lastError: String? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.displayName = displayName
        self.managedFilename = managedFilename
        self.media = media
        self.status = status
        self.sourceModificationDate = sourceModificationDate
        self.sourceByteCount = sourceByteCount
        self.pairedVideoByteCount = pairedVideoByteCount
        self.sourceResourceTypes = sourceResourceTypes
        self.lastError = lastError
    }

    var managedFilenames: [String] {
        [managedFilename, media.posterFilename, media.pairedVideoFilename].compactMap { filename in
            guard let filename, !filename.isEmpty else { return nil }
            return filename
        }
    }

    func matchesCurrentResource(_ descriptor: PhotosAssetDescriptor, resourceTypes: [Int]?) -> Bool {
        guard let sourceResourceTypes, !sourceResourceTypes.isEmpty else { return false }
        return status == .active && localIdentifier == descriptor.localIdentifier
            && sourceModificationDate == descriptor.modificationDate
            && sourceResourceTypes == resourceTypes
    }

    /// Archive-safe identity. The stored bytes remain a usable snapshot, but no Photos asset
    /// identifier leaks into a portable file and no imported snapshot can silently rebind.
    var archiveSnapshot: PhotosLibraryAsset {
        PhotosLibraryAsset(
            localIdentifier: "",
            displayName: displayName,
            managedFilename: managedFilename,
            media: media,
            status: .snapshot,
            sourceModificationDate: nil,
            sourceByteCount: sourceByteCount,
            pairedVideoByteCount: pairedVideoByteCount,
            lastError: nil
        )
    }
}

/// A value-only selection returned by the native chooser. Keeping PHAssetCollection out of this
/// model prevents Photos framework objects from entering persistence or crossing task boundaries.
struct PhotosLibraryCollectionSelection: Equatable, Identifiable, Sendable {
    let localIdentifier: String
    let collectionType: PhotosLibraryCollectionType
    let displayName: String
    let assetCount: Int

    var id: String { localIdentifier }
}

enum PhotosLibrarySyncState: Equatable {
    case idle
    case authorizing
    case syncing(collection: String, completed: Int, total: Int, fraction: Double, message: String)
    case failed(String)

    var displayName: String {
        switch self {
        case .idle: return ""
        case .authorizing: return "Requesting Photos access…"
        case .syncing(_, let completed, let total, _, let message):
            return total > 0 ? "\(message) \(completed) of \(total)" : message
        case .failed(let message): return message
        }
    }
}

struct PhotosAssetDescriptor: Equatable, Sendable {
    let localIdentifier: String
    let displayName: String
    let mediaKind: PhotoMediaKind
    let modificationDate: Date?
    let estimatedBytes: Int64
}

enum PhotosLibraryCollectionPolicy {
    static let maxManagedAssets = LiveFolderSpacePolicy.maxManagedFiles
    static let maxManagedBytes = LiveFolderSpacePolicy.maxManagedBytes
    static let allowNetworkDownloads = true
    static let allowMutedVideoAssets = true

    static func bounded(
        _ candidates: [PhotosAssetDescriptor],
        currentAssetIdentifier: String?
    ) -> (selected: [PhotosAssetDescriptor], skipped: [PhotosAssetDescriptor]) {
        guard !candidates.isEmpty else { return ([], []) }

        var prioritized = candidates
        if let currentAssetIdentifier,
           let index = prioritized.firstIndex(where: { $0.localIdentifier == currentAssetIdentifier }) {
            let current = prioritized.remove(at: index)
            prioritized.insert(current, at: 0)
        }

        var selected: [PhotosAssetDescriptor] = []
        var totalBytes: Int64 = 0
        for candidate in prioritized {
            let isCurrent = candidate.localIdentifier == currentAssetIdentifier
            guard selected.count < maxManagedAssets else { continue }
            let estimated = max(0, candidate.estimatedBytes)
            let remaining = maxManagedBytes - min(totalBytes, maxManagedBytes)
            let exceeds = estimated > remaining
            if exceeds && !isCurrent { continue }
            selected.append(candidate)
            totalBytes += estimated
        }

        let selectedIDs = Set(selected.map(\.localIdentifier))
        let ordered = candidates.filter { selectedIDs.contains($0.localIdentifier) }
        let orderedIDs = Set(ordered.map(\.localIdentifier))
        return (ordered, candidates.filter { !orderedIDs.contains($0.localIdentifier) })
    }
}

