import AppKit

struct RemovedWidgets: Codable {
    let photos: [PhotoItem]
    let detachedChildren: [UUID: UUID]
}

@MainActor
extension PhotoManager {
    /// Recovery is written before the desktop changes, so removal never deletes
    /// the last managed copy. The previous removal is released only after commit.
    func prepareRemovalRecovery(_ removed: [PhotoItem]) throws -> DesktopSetupLibrary {
        let previous = try DesktopSetupLibrary.read(in: storageDir)
        var next = previous
        let ids = Set(removed.map(\.id))
        let detached = photos.compactMap { item -> (UUID, UUID)? in
            guard !ids.contains(item.id), let parent = item.collageParentID, ids.contains(parent) else { return nil }
            return (item.id, parent)
        }
        next.removed = RemovedWidgets(photos: removed, detachedChildren: Dictionary(uniqueKeysWithValues: detached))
        try next.write(in: storageDir)
        return previous
    }

    func restoreRemovedWidgets() throws {
        var library = try DesktopSetupLibrary.read(in: storageDir)
        guard let recovery = library.removed else { throw SetupError.missing }
        let existingIDs = Set(photos.map(\.id))
        let restored = recovery.photos.filter { !existingIDs.contains($0.id) }
        try validateStoredPhotos(restored)
        var combined = photos + restored
        let restoredParentIDs = Set(restored.filter { $0.desktopCollage != nil }.map(\.id))
        var rejoinedIDs: Set<UUID> = []
        for index in combined.indices {
            let id = combined[index].id
            // Do not steal a child moved into another collage after removal.
            if combined[index].collageParentID == nil,
               let parent = recovery.detachedChildren[id], restoredParentIDs.contains(parent) {
                combined[index].collageParentID = parent
                rejoinedIDs.insert(id)
            }
        }
        let affectedParents = restoredParentIDs.union(restored.compactMap(\.collageParentID))
        let affectedIDs = Set(restored.map(\.id)).union(rejoinedIDs).union(photos.filter {
            affectedParents.contains($0.id) || $0.collageParentID.map { affectedParents.contains($0) } == true
        }.map(\.id))
        // Recovery changes only these scenes. Unrelated appearance drafts stay
        // live and out of the committed model, just as they do during an Add.
        guard !hasArrangementInteraction(affecting: affectedIDs) else { throw SetupError.unfinishedArrangement }
        let previous = photos
        photos = combined
        // Detached children may have been moved, resized or hidden since removal. Fit to their
        // current committed geometry before saving; the old backdrop bounds are no longer valid.
        for parent in affectedParents { fitCollageModel(parent) }
        guard persist() else { photos = previous; throw SetupError.couldNotSave }
        // The active store may have been missing at launch while removal recovery survived.
        // Retained custom fonts still need registration before recovered text is rendered.
        if restored.contains(where: { $0.desktopCollage?.fontFileNames.isEmpty == false }) {
            CollageFontLibrary.load(in: storageDir)
        }
        activateCommittedAdditions(restored)
        for parent in affectedParents.subtracting(restoredParentIDs) { fitCollageWindow(parent, animated: false) }
        syncCollages(only: affectedParents)
        // Keeping the recovery record on a failed cleanup is harmless: duplicate
        // IDs are skipped on retry, and its managed files stay protected.
        library.removed = nil
        try library.write(in: storageDir)
        removedWidgetCount = 0
        for name in recovery.photos.flatMap({ storedFilenames(in: $0) }) { removeStoredFileIfUnreferenced(name) }
    }

    func discardRemovedWidgets() throws {
        var library = try DesktopSetupLibrary.read(in: storageDir)
        let discarded = library.removed?.photos ?? []
        library.removed = nil
        try library.write(in: storageDir)
        removedWidgetCount = 0
        for name in discarded.flatMap({ storedFilenames(in: $0) }) { removeStoredFileIfUnreferenced(name) }
    }
}
