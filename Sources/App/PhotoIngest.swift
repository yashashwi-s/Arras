import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns imported bytes into a file in the photo store, off the main actor.
///
/// The old path went `Data -> NSImage -> tiffRepresentation -> NSBitmapImageRep -> JPEG`, all
/// synchronously on the main actor, once per photo. Measured on a 4032x3024 JPEG that is
/// ~74ms per image, of which `tiffRepresentation` alone is 34ms and allocates a 34MB
/// uncompressed buffer — and for a source that was already JPEG the round trip made the file
/// *bigger*. Picking twenty photos froze the UI for several seconds before anything appeared.
///
/// Nothing here touches `PhotoManager`, so it is safe to run concurrently.
enum PhotoIngest {
    /// Longest edge kept when storing a still. Widgets render at a few hundred points; storing
    /// 48 megapixels costs disk, memory, and a full-resolution decode every time the widget is
    /// re-shown or a thumbnail is drawn.
    private static let maxPixelSize = 2560

    struct Prepared: Sendable {
        let filename: String
        let url: URL
        /// The file's own name, kept so a widget can be labelled with it. Stored files are
        /// named by UUID, so without capturing this at import the original is gone.
        let originalName: String?
        let mediaFidelity: ArchiveMediaFidelity
        let media: PhotoMedia
        /// A generated poster for a standalone movie.  Live Photos use their still as the
        /// representative and therefore do not need a separate poster file.
        let posterURL: URL?
        let pairedVideoURL: URL?

        var managedURLs: [URL] {
            [url, posterURL, pairedVideoURL].compactMap { $0 }
        }

        var managedFilenames: [String] {
            managedURLs.map(\.lastPathComponent)
        }

        /// Fidelity belongs to each stored artifact, not to the logical media item. A video
        /// keeps its movie bytes but generates a JPEG poster, while a Live Photo can combine a
        /// transformed still with an unchanged paired movie.
        var mediaFidelityByFilename: [String: ArchiveMediaFidelity] {
            var result = [filename: mediaFidelity]
            if let posterFilename = media.posterFilename {
                result[posterFilename] = .transformed
            }
            if let pairedVideoFilename = media.pairedVideoFilename {
                result[pairedVideoFilename] = .sourceBytes
            }
            return result
        }
    }

    /// Writes `data` into `directory` and returns what to record for it.
    ///
    /// - Animated sources keep their original bytes, so they still animate.
    /// - Stills are downsampled if oversized, and otherwise written through untouched when
    ///   they are already in a format `PhotoContent.load` can read — no decode, no re-encode.
    nonisolated static func prepare(data: Data, in directory: URL, originalName: String? = nil) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let type = CGImageSourceGetType(source) as String?
        if CGImageSourceGetCount(source) > 1,
           [UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier].contains(type ?? ""),
           CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 32
           ] as CFDictionary) != nil {
            // Keep the source container. The playback decoder understands GIF, APNG and WebP,
            // and retaining the matching extension prevents a WebP payload from being archived
            // under a misleading `.gif` filename.
            if let ext = passthroughExtension(for: type) {
                return write(
                    data,
                    extension: ext,
                    in: directory,
                    originalName: originalName,
                    mediaFidelity: .sourceBytes,
                    media: PhotoMedia(kind: .animatedImage)
                )
            }
        }

        let pixelWidth = property(source, kCGImagePropertyPixelWidth)
        let pixelHeight = property(source, kCGImagePropertyPixelHeight)
        let longestEdge = max(pixelWidth, pixelHeight)

        // Already a reasonable size and a format we can read back: keep the original bytes.
        if longestEdge <= maxPixelSize, let ext = passthroughExtension(for: type) {
            return write(
                data,
                extension: ext,
                in: directory,
                originalName: originalName,
                mediaFidelity: .sourceBytes,
                media: PhotoMedia(kind: .still)
            )
        }

        guard let downsampled = downsample(source) else {
            // Couldn't resize — better to store the original than to lose the import.
            if let ext = passthroughExtension(for: type) {
                return write(
                    data,
                    extension: ext,
                    in: directory,
                    originalName: originalName,
                    mediaFidelity: .sourceBytes,
                    media: PhotoMedia(kind: .still)
                )
            }
            return nil
        }
        return write(
            downsampled.data,
            extension: downsampled.fileExtension,
            in: directory,
            originalName: originalName,
            mediaFidelity: .transformed,
            media: PhotoMedia(kind: .still)
        )
    }

    nonisolated static func prepare(contentsOf url: URL, in directory: URL) -> Prepared? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if PhotoImportPolicy.isVideo(url) {
            return prepareVideo(contentsOf: url, in: directory)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return prepare(data: data, in: directory,
                       originalName: url.deletingPathExtension().lastPathComponent)
    }

    /// Validates and adopts a standalone MOV/MP4/M4V into the managed store.  The movie bytes
    /// are copied unchanged; the generated JPEG poster is a separate managed file so a paused
    /// or occluded widget never needs to reopen the user's source path.
    nonisolated static func prepareVideo(
        contentsOf url: URL,
        in directory: URL,
        originalName: String? = nil
    ) -> Prepared? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let resourceSize: Int64? = {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else { return nil }
            return Int64(fileSize)
        }()
        guard PhotoImportPolicy.isVideo(url),
              resourceSize.map({ $0 <= VideoMediaSupport.maxSourceBytes }) ?? true,
              let data = try? Data(contentsOf: url),
              Int64(data.count) <= VideoMediaSupport.maxSourceBytes else { return nil }

        let filename = UUID().uuidString + "." + url.pathExtension.lowercased()
        let storedURL = directory.appendingPathComponent(filename)
        do {
            try data.write(to: storedURL, options: .atomic)
        } catch {
            return nil
        }

        guard VideoMediaSupport.isPlayableVideo(at: storedURL),
              let poster = VideoMediaSupport.posterImage(for: storedURL),
              let posterData = VideoMediaSupport.jpegData(for: poster) else {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }

        let posterFilename = UUID().uuidString + ".jpg"
        let posterURL = directory.appendingPathComponent(posterFilename)
        do {
            try posterData.write(to: posterURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: storedURL)
            return nil
        }

        return Prepared(
            filename: filename,
            url: storedURL,
            originalName: originalName ?? url.deletingPathExtension().lastPathComponent,
            mediaFidelity: .sourceBytes,
            media: PhotoMedia(kind: .video, posterFilename: posterFilename),
            posterURL: posterURL,
            pairedVideoURL: nil
        )
    }

    /// Adopts video bytes delivered by PhotoKit without requiring a source URL. The temporary
    /// extension lets AVFoundation inspect the container; only the generated managed movie and
    /// poster survive the hand-off.
    nonisolated static func prepareVideo(
        data: Data,
        fileExtension: String,
        in directory: URL,
        originalName: String? = nil
    ) -> Prepared? {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let temporaryURL = directory.appendingPathComponent(UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext))
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return prepareVideo(contentsOf: temporaryURL, in: directory, originalName: originalName)
    }

    /// Internal bridge for the future PhotoKit source.  macOS exposes Live Photo resources as
    /// an exported still and paired movie; keeping this API byte-based avoids any dependency on
    /// PHLivePhotoView (which is not a general AppKit renderer).
    nonisolated static func prepareLivePhoto(
        stillData: Data,
        pairedVideoData: Data,
        in directory: URL,
        originalName: String? = nil
    ) -> Prepared? {
        guard let still = prepare(data: stillData, in: directory, originalName: originalName) else {
            return nil
        }

        let temporaryURL = directory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try pairedVideoData.write(to: temporaryURL, options: .atomic)
        } catch {
            cleanup(still)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard let paired = prepareVideo(contentsOf: temporaryURL, in: directory) else {
            cleanup(still)
            return nil
        }
        // The still is the Live Photo's representative.  The temporary standalone poster is
        // not needed, so avoid retaining an unreferenced managed file.
        if let posterURL = paired.posterURL {
            try? FileManager.default.removeItem(at: posterURL)
        }

        return Prepared(
            filename: still.filename,
            url: still.url,
            originalName: originalName ?? still.originalName,
            mediaFidelity: still.mediaFidelity.merged(with: paired.mediaFidelity),
            media: PhotoMedia(kind: .livePhoto, pairedVideoFilename: paired.filename),
            posterURL: nil,
            pairedVideoURL: paired.url
        )
    }

    // MARK: - Helpers

    private nonisolated static func property(_ source: CGImageSource, _ key: CFString) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return props?[key] as? Int ?? 0
    }

    /// Formats `PhotoContent.load` reads directly, so the bytes can be stored as they arrived.
    private nonisolated static func passthroughExtension(for type: String?) -> String? {
        guard let type, let utType = UTType(type) else { return nil }
        if utType.conforms(to: .jpeg) { return "jpg" }
        if utType.conforms(to: .png) { return "png" }
        if utType.conforms(to: .heic) { return "heic" }
        if utType.conforms(to: .tiff) { return "tiff" }
        if utType.conforms(to: .gif) { return "gif" }
        if utType.conforms(to: .bmp) { return "bmp" }
        if utType.conforms(to: .webP) { return "webp" }
        return nil
    }

    private nonisolated static func downsample(_ source: CGImageSource) -> (data: Data, fileExtension: String)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Honour EXIF orientation here, so nothing downstream has to.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let hasAlpha = cgImage.hasAlphaChannel
        let outputType: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = hasAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, hasAlpha ? "png" : "jpg")
    }

    private nonisolated static func write(
        _ data: Data,
        extension ext: String,
        in directory: URL,
        originalName: String?,
        mediaFidelity: ArchiveMediaFidelity,
        media: PhotoMedia = .still
    ) -> Prepared? {
        let filename = UUID().uuidString + "." + ext
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return Prepared(
                filename: filename,
                url: url,
                originalName: originalName,
                mediaFidelity: mediaFidelity,
                media: media,
                posterURL: nil,
                pairedVideoURL: nil
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func cleanup(_ prepared: Prepared) {
        for url in prepared.managedURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension CGImage {
    /// Whether the pixel format carries alpha. The skip variants are padding, not alpha.
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            return true
        case .none, .noneSkipLast, .noneSkipFirst:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - Batched import

extension PhotoManager {
    private struct PreparedImport {
        let index: Int
        let source: String
        let file: PhotoIngest.Prepared
    }

    private struct PreparedURLBatch {
        let entries: [Int: ImportBatchResult.Entry]
        let prepared: [PreparedImport]
    }

    private struct AdoptionOutcome {
        let accepted: Set<Int>
        let failures: [Int: String]
    }

    /// Imports many images at once: bytes are prepared concurrently off the main actor, then
    /// the whole batch lands in one main-actor hop with a single `persist()`.
    ///
    /// The result keeps unsupported inputs separate from files that were eligible but could
    /// not be read, decoded, or saved. This is the source of truth for every UI importer.
    @discardableResult
    func importPhotos(data items: [Data], sourceNames: [String]? = nil) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard !items.isEmpty else { return ImportBatchResult() }
        let directory = storageDir
        let generation = desktopGeneration
        let prepare = prepareImportedData

        let prepared = await withTaskGroup(of: (Int, PhotoIngest.Prepared?).self) { group in
            for (index, data) in items.enumerated() {
                group.addTask {
                    let originalName = sourceNames.flatMap { names in
                        names.indices.contains(index) ? names[index] : nil
                    }
                    return (index, prepare(
                        data,
                        directory,
                        originalName?.isEmpty == false ? originalName : nil
                    ))
                }
            }
            var results: [(Int, PhotoIngest.Prepared?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        var entries: [Int: ImportBatchResult.Entry] = [:]
        var imports: [PreparedImport] = []
        for (index, preparedFile) in prepared {
            let source = sourceNames.flatMap { names -> String? in
                guard names.indices.contains(index) else { return nil }
                let name = names[index]
                return name.isEmpty ? nil : name
            }
                ?? "Photo \(index + 1)"
            guard let preparedFile else {
                entries[index] = .init(
                    source: source,
                    status: .failed,
                    reason: "The image could not be decoded or stored."
                )
                continue
            }
            imports.append(PreparedImport(index: index, source: source, file: preparedFile))
        }

        let batch = PreparedURLBatch(entries: entries, prepared: imports)
        if let interrupted = discardInterruptedBatch(batch, generation: generation, itemCount: items.count) { return interrupted }
        return finish(entries: entries, imports: imports, itemCount: items.count)
    }

    /// Imports image files from Finder or a drop source. Unsupported files are retained in the
    /// result as skipped entries instead of disappearing during extension filtering.
    @discardableResult
    func importPhotos(urls: [URL]) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard !urls.isEmpty else { return ImportBatchResult() }
        let generation = desktopGeneration
        let batch = await prepareURLBatch(urls)
        if let interrupted = discardInterruptedBatch(batch, generation: generation, itemCount: urls.count) { return interrupted }
        return finish(entries: batch.entries, imports: batch.prepared, itemCount: urls.count)
    }

    /// Builds a Space from many images, using the same accepted/skipped/failed contract as a
    /// normal batch. Each accepted source becomes one ordered slot in the Space.
    @discardableResult
    func addSpace(urls: [URL]) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard !urls.isEmpty else { return ImportBatchResult() }
        let generation = desktopGeneration
        let batch = await prepareURLBatch(urls)
        if let interrupted = discardInterruptedBatch(batch, generation: generation, itemCount: urls.count) { return interrupted }
        var entries = batch.entries
        var valid = [PreparedImport]()

        for candidate in batch.prepared {
            guard !candidate.file.media.kind.isVideoKind,
                  loadPreparedContent(candidate.file) != nil else {
                discardPrepared(candidate.file)
                entries[candidate.index] = .init(
                    source: candidate.source,
                    status: .failed,
                    reason: candidate.file.media.kind.isVideoKind
                        ? "Videos can be added as standalone widgets, not Space slots."
                        : "The stored image could not be decoded."
                )
                continue
            }
            valid.append(candidate)
        }

        guard !valid.isEmpty else { return result(entries: entries, itemCount: urls.count) }

        var item = PhotoItem(filename: "")
        item.customName = "Space"
        item.spaceImageFilenames = valid.map { $0.file.filename }
        item.mediaFidelity = Dictionary(
            uniqueKeysWithValues: valid.map { ($0.file.filename, $0.file.mediaFidelity) }
        )
        item.rotationInterval = "30s"
        item.folderSizeMode = "dynamic"

        guard commitImportedItems([item], replacing: false) else {
            for candidate in valid {
                discardPrepared(candidate.file)
                entries[candidate.index] = .init(
                    source: candidate.source,
                    status: .failed,
                    reason: "The Space could not be saved."
                )
            }
            return result(entries: entries, itemCount: urls.count)
        }

        for candidate in valid {
            entries[candidate.index] = .init(source: candidate.source, status: .accepted)
        }
        return result(entries: entries, itemCount: urls.count)
    }

    /// Appends image files to an existing Space and persists the ordered slot list atomically.
    @discardableResult
    func appendPhotosToSpace(_ id: UUID, urls: [URL]) async -> ImportBatchResult {
        beginMediaImport()
        defer { endMediaImport() }
        guard !urls.isEmpty else { return ImportBatchResult() }
        guard let existingIndex = photos.firstIndex(where: { $0.id == id }) else {
            let entries = urls.map { url in
                ImportBatchResult.Entry(
                    source: sourceName(for: url),
                    status: .failed,
                    reason: "The Space no longer exists."
                )
            }
            return ImportBatchResult(entries: entries)
        }
        guard photos[existingIndex].allowsManualMediaEditing else {
            return ImportBatchResult(entries: urls.map { url in
                .init(
                    source: sourceName(for: url),
                    status: .failed,
                    reason: "Disconnect the linked source before adding files manually."
                )
            })
        }

        let generation = desktopGeneration
        let batch = await prepareURLBatch(urls)
        if let interrupted = discardInterruptedBatch(batch, generation: generation, itemCount: urls.count) { return interrupted }
        guard let currentIndex = photos.firstIndex(where: { $0.id == id }),
              photos[currentIndex].allowsManualMediaEditing else {
            for candidate in batch.prepared { discardPrepared(candidate.file) }
            let blocked = urls.map { url in
                ImportBatchResult.Entry(
                    source: sourceName(for: url),
                    status: .failed,
                    reason: "Disconnect the linked source before adding files manually."
                )
            }
            return ImportBatchResult(entries: blocked)
        }
        let index = currentIndex
        var entries = batch.entries
        var valid = [PreparedImport]()
        for candidate in batch.prepared {
            guard !candidate.file.media.kind.isVideoKind,
                  loadPreparedContent(candidate.file) != nil else {
                discardPrepared(candidate.file)
                entries[candidate.index] = .init(
                    source: candidate.source,
                    status: .failed,
                    reason: candidate.file.media.kind.isVideoKind
                        ? "Videos can be added as standalone widgets, not Space slots."
                        : "The stored image could not be decoded."
                )
                continue
            }
            valid.append(candidate)
        }
        guard !valid.isEmpty else { return result(entries: entries, itemCount: urls.count) }

        let previousPhotos = photos
        let previousSpaceImages = spaceImages[id]
        photos[index].spaceImageFilenames.append(contentsOf: valid.map { $0.file.filename })
        for candidate in valid {
            photos[index].mediaFidelity[candidate.file.filename] = candidate.file.mediaFidelity
        }
        var current = spaceImages[id]
            ?? previousPhotos[index].spaceImageFilenames.map { storageDir.appendingPathComponent($0) }
        current.append(contentsOf: valid.map { $0.file.url })
        spaceImages[id] = current

        guard persist() else {
            photos = previousPhotos
            spaceImages[id] = previousSpaceImages
            if previousSpaceImages == nil { spaceImages.removeValue(forKey: id) }
            for candidate in valid {
                discardPrepared(candidate.file)
                entries[candidate.index] = .init(
                    source: candidate.source,
                    status: .failed,
                    reason: "The Space could not be saved."
                )
            }
            return result(entries: entries, itemCount: urls.count)
        }

        for candidate in valid {
            entries[candidate.index] = .init(source: candidate.source, status: .accepted)
        }
        return result(entries: entries, itemCount: urls.count)
    }

    // MARK: - Preparation and adoption

    private func discardInterruptedBatch(_ batch: PreparedURLBatch, generation: UUID,
                                         itemCount: Int) -> ImportBatchResult? {
        guard Task.isCancelled || desktopGeneration != generation else { return nil }
        var entries = batch.entries
        for candidate in batch.prepared {
            discardPrepared(candidate.file)
            entries[candidate.index] = .init(source: candidate.source, status: .skipped,
                reason: "The import was cancelled or the desktop changed. Add the media again to this setup.")
        }
        return result(entries: entries, itemCount: itemCount)
    }

    private func prepareURLBatch(_ urls: [URL]) async -> PreparedURLBatch {
        let directory = storageDir
        let prepare = prepareImportedURL
        let candidates = urls.enumerated().filter { _, url in isImportable(url) }
        let prepared = await withTaskGroup(of: (Int, PhotoIngest.Prepared?).self) { group in
            for (index, url) in candidates {
                group.addTask {
                    (index, prepare(url, directory))
                }
            }
            var results: [(Int, PhotoIngest.Prepared?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        var entries: [Int: ImportBatchResult.Entry] = [:]
        for (index, url) in urls.enumerated() where !isImportable(url) {
            entries[index] = .init(
                source: sourceName(for: url),
                status: .skipped,
                reason: "The file type is not supported."
            )
        }

        var imports: [PreparedImport] = []
        for (index, preparedFile) in prepared {
            let source = sourceName(for: urls[index])
            guard let preparedFile else {
                entries[index] = .init(
                    source: source,
                    status: .failed,
                    reason: PhotoImportPolicy.isVideo(urls[index])
                        ? "The video could not be validated, its poster could not be generated, or it exceeds the local size limit."
                        : "The file could not be read or decoded."
                )
                continue
            }
            imports.append(PreparedImport(index: index, source: source, file: preparedFile))
        }
        return PreparedURLBatch(entries: entries, prepared: imports)
    }

    private func finish(
        entries: [Int: ImportBatchResult.Entry],
        imports: [PreparedImport],
        itemCount: Int
    ) -> ImportBatchResult {
        var entries = entries
        let outcome = adopt(imports)
        for candidate in imports {
            if outcome.accepted.contains(candidate.index) {
                entries[candidate.index] = .init(source: candidate.source, status: .accepted)
            } else {
                entries[candidate.index] = .init(
                    source: candidate.source,
                    status: .failed,
                    reason: outcome.failures[candidate.index] ?? "The image could not be saved."
                )
            }
        }
        return result(entries: entries, itemCount: itemCount)
    }

    /// Creates one widget per prepared file and saves once. A failed model write rolls back the
    /// in-memory layout and removes the staged files, so accepted means durable, not merely
    /// decoded.
    private func adopt(_ prepared: [PreparedImport]) -> AdoptionOutcome {
        guard !prepared.isEmpty else { return AdoptionOutcome(accepted: [], failures: [:]) }

        var usable: [PreparedImport] = []
        var failures: [Int: String] = [:]
        for candidate in prepared {
            guard loadPreparedContent(candidate.file) != nil else {
                failures[candidate.index] = "The stored image could not be decoded."
                discardPrepared(candidate.file)
                continue
            }
            usable.append(candidate)
        }
        guard !usable.isEmpty else { return AdoptionOutcome(accepted: [], failures: failures) }

        let items = usable.map { candidate -> PhotoItem in
            var item = PhotoItem(filename: candidate.file.filename)
            // A widget called "beach-house" beats "Photo 4".
            item.customName = candidate.file.originalName
            item.media = candidate.file.media
            item.mediaFidelity = candidate.file.mediaFidelityByFilename
            return item
        }
        guard commitImportedItems(items, replacing: false) else {
            for candidate in usable {
                failures[candidate.index] = "The image could not be saved to the photo library."
                discardPrepared(candidate.file)
            }
            return AdoptionOutcome(accepted: [], failures: failures)
        }
        return AdoptionOutcome(accepted: Set(usable.map(\.index)), failures: failures)
    }

    private func result(entries: [Int: ImportBatchResult.Entry], itemCount: Int) -> ImportBatchResult {
        ImportBatchResult(entries: (0..<itemCount).compactMap { entries[$0] })
    }

    private func isImportable(_ url: URL) -> Bool {
        PhotoImportPolicy.isImportable(url)
    }

    private func sourceName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func loadPreparedContent(_ file: PhotoIngest.Prepared) -> PhotoContent? {
        PhotoContent.load(
            from: file.url,
            posterURL: file.posterURL,
            pairedVideoURL: file.pairedVideoURL
        )
    }

    private func discardPrepared(_ file: PhotoIngest.Prepared) {
        for url in file.managedURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
