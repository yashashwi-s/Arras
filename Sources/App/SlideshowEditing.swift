import Foundation

@MainActor
extension PhotoManager {
    /// Applies one complete slideshow editor snapshot. The durable playlist is committed before
    /// its cache or desktop window change, so a refused save leaves the currently shown image
    /// and its old source list intact.
    @discardableResult
    func applySlideshowEdit(_ id: UUID, imageFilenames: [String]) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              !photos[index].spaceImageFilenames.isEmpty,
              !imageFilenames.isEmpty,
              photos[index].allowsManualMediaEditing else { return false }

        let original = photos[index]
        var available = original.spaceImageFilenames.reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        for filename in imageFilenames {
            guard let count = available[filename], count > 0 else { return false }
            available[filename] = count - 1
        }

        let oldIndex = original.spaceImageFilenames.indices.contains(original.folderImageIndex)
            ? original.folderImageIndex
            : original.spaceImageFilenames.startIndex
        let displayedFilename = original.spaceImageFilenames[oldIndex]
        let replacementIndex = imageFilenames.firstIndex(of: displayedFilename)
            ?? min(oldIndex, imageFilenames.index(before: imageFilenames.endIndex))
        let retained = Set(imageFilenames)
        let replacementURL = storageDir.appendingPathComponent(imageFilenames[replacementIndex])
        let replacementContent: PhotoContent?
        if displayedFilename != imageFilenames[replacementIndex], windows[id] != nil {
            // Do not commit a playlist that leaves an open widget showing bytes it no longer
            // owns. Hidden slideshows have no window to repair and rebuild from the durable list.
            guard let content = loadMediaContent(
                for: original,
                filename: replacementURL.lastPathComponent,
                primaryURL: replacementURL
            ) else { return false }
            replacementContent = content
        } else {
            replacementContent = nil
        }

        photos[index].spaceImageFilenames = imageFilenames
        photos[index].folderImageIndex = replacementIndex
        photos[index].folderImageConfigs = original.folderImageConfigs.filter { retained.contains($0.key) }
        photos[index].mediaFidelity = original.mediaFidelity.filter { retained.contains($0.key) }
        photos[index].playbackStep = 0
        if original.playbackOrder == .noRepeat {
            var seen: Set<String> = []
            photos[index].playbackHistory = original.playbackHistory.filter {
                retained.contains($0) && seen.insert($0).inserted
            }
            let currentFilename = imageFilenames[replacementIndex]
            if !seen.contains(currentFilename) {
                photos[index].playbackHistory.append(currentFilename)
            }
        } else {
            photos[index].playbackHistory = []
        }

        guard persist() else {
            photos[index] = original
            return false
        }

        let item = photos[index]
        let urls = item.spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
        spaceImages[id] = urls
        if displayedFilename != item.spaceImageFilenames[item.folderImageIndex],
           let replacementContent {
            let targetFrame = item.folderImageConfigs[replacementURL.lastPathComponent]
                .map { NSRectFromString($0.frameString) }
            windows[id]?.swapImage(
                replacementContent,
                targetFrame: targetFrame,
                mode: item.folderSizeMode,
                animate: false
            )
        }
        invalidateThumbnails(for: original)
        invalidateThumbnails(for: item)

        for filename in Set(original.spaceImageFilenames) where !retained.contains(filename) {
            removeStoredFileIfUnreferenced(filename)
        }
        return true
    }
}
