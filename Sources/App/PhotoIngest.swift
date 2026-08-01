import AppKit
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

    struct Prepared {
        let filename: String
        let url: URL
        /// The file's own name, kept so a widget can be labelled with it. Stored files are
        /// named by UUID, so without capturing this at import the original is gone.
        let originalName: String?
    }

    /// Writes `data` into `directory` and returns what to record for it.
    ///
    /// - Animated sources keep their original bytes, so they still animate.
    /// - Stills are downsampled if oversized, and otherwise written through untouched when
    ///   they are already in a format `PhotoContent.load` can read — no decode, no re-encode.
    nonisolated static func prepare(data: Data, in directory: URL, originalName: String? = nil) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        if CGImageSourceGetCount(source) > 1, AnimatedImageIO.decodeForPlayback(data: data) != nil {
            return write(data, extension: "gif", in: directory, originalName: originalName)
        }

        let type = CGImageSourceGetType(source) as String?
        let pixelWidth = property(source, kCGImagePropertyPixelWidth)
        let pixelHeight = property(source, kCGImagePropertyPixelHeight)
        let longestEdge = max(pixelWidth, pixelHeight)

        // Already a reasonable size and a format we can read back: keep the original bytes.
        if longestEdge <= maxPixelSize, let ext = passthroughExtension(for: type) {
            return write(data, extension: ext, in: directory, originalName: originalName)
        }

        guard let downsampled = downsample(source) else {
            // Couldn't resize — better to store the original than to lose the import.
            if let ext = passthroughExtension(for: type) {
                return write(data, extension: ext, in: directory, originalName: originalName)
            }
            return nil
        }
        return write(downsampled, extension: "jpg", in: directory, originalName: originalName)
    }

    nonisolated static func prepare(contentsOf url: URL, in directory: URL) -> Prepared? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return prepare(data: data, in: directory,
                       originalName: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Helpers

    private nonisolated static func property(_ source: CGImageSource, _ key: CFString) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return props?[key] as? Int ?? 0
    }

    /// Formats `PhotoContent.load` (and therefore `NSImage(contentsOf:)`) reads directly, so
    /// the bytes can be stored as they arrived.
    private nonisolated static func passthroughExtension(for type: String?) -> String? {
        guard let type, let utType = UTType(type) else { return nil }
        switch utType {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .gif: return "gif"
        default: return nil
        }
    }

    private nonisolated static func downsample(_ source: CGImageSource) -> Data? {
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
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private nonisolated static func write(_ data: Data, extension ext: String, in directory: URL,
                                          originalName: String?) -> Prepared? {
        let filename = UUID().uuidString + "." + ext
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return Prepared(filename: filename, url: url, originalName: originalName)
        } catch {
            return nil
        }
    }
}

// MARK: - Batched import

extension PhotoManager {
    /// Imports many images at once: bytes are prepared concurrently off the main actor, then
    /// the whole batch lands in one main-actor hop with a single `persist()`.
    ///
    /// The per-item version of this did N full-resolution transcodes, N window creations, N
    /// JSON rewrites and — via `onMenuUpdate` — N status-menu rebuilds, each of which decoded a
    /// thumbnail for *every* photo already in the library. Importing 20 photos into an empty
    /// library meant 210 full-resolution decodes on the main thread to redraw a menu nobody
    /// had open.
    @discardableResult
    func addPhotos(data items: [Data]) async -> Int {
        guard !items.isEmpty else { return 0 }
        let directory = storageDir

        let prepared = await withTaskGroup(of: (Int, PhotoIngest.Prepared?).self) { group in
            for (index, data) in items.enumerated() {
                group.addTask {
                    (index, PhotoIngest.prepare(data: data, in: directory))
                }
            }
            var results: [(Int, PhotoIngest.Prepared?)] = []
            for await result in group { results.append(result) }
            // The task group finishes out of order; the user picked these in an order.
            return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }

        return adopt(prepared)
    }

    @discardableResult
    func addPhotos(urls: [URL]) async -> Int {
        guard !urls.isEmpty else { return 0 }
        let directory = storageDir

        let prepared = await withTaskGroup(of: (Int, PhotoIngest.Prepared?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    (index, PhotoIngest.prepare(contentsOf: url, in: directory))
                }
            }
            var results: [(Int, PhotoIngest.Prepared?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }

        return adopt(prepared)
    }

    /// Creates one widget per prepared file and saves once.
    private func adopt(_ prepared: [PhotoIngest.Prepared]) -> Int {
        guard !prepared.isEmpty else { return 0 }
        for file in prepared {
            var item = PhotoItem(filename: file.filename)
            // A widget called "beach-house" beats "Photo 4".
            item.customName = file.originalName
            photos.append(item)
            if let content = PhotoContent.load(from: file.url) {
                createWindow(for: item, content: content)
            }
        }
        persist()
        return prepared.count
    }

    /// Builds a Space from many images, preparing them concurrently.
    func addSpace(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let directory = storageDir

        let prepared = await withTaskGroup(of: (Int, PhotoIngest.Prepared?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, PhotoIngest.prepare(contentsOf: url, in: directory)) }
            }
            var results: [(Int, PhotoIngest.Prepared?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }
        guard !prepared.isEmpty else { return }

        var item = PhotoItem(filename: "")
        item.customName = "Space"
        item.spaceImageFilenames = prepared.map(\.filename)
        item.rotationInterval = "30s"
        item.folderSizeMode = "dynamic"
        photos.append(item)

        spaceImages[item.id] = prepared.map(\.url)
        if let first = prepared.first, let content = PhotoContent.load(from: first.url) {
            createWindow(for: item, content: content)
            setupRotationTimer(for: item)
        }
        // The old addSpace never persisted at all — a Space survived only because the
        // quit handler saved it, so a force-quit lost the whole thing.
        persist()
    }

    func appendPhotosToSpace(_ id: UUID, urls: [URL]) {
        Task { @MainActor in
            guard let index = self.photos.firstIndex(where: { $0.id == id }) else { return }
            let directory = self.storageDir

            let prepared = await withTaskGroup(of: (Int, PhotoIngest.Prepared?).self) { group in
                for (offset, url) in urls.enumerated() {
                    group.addTask { (offset, PhotoIngest.prepare(contentsOf: url, in: directory)) }
                }
                var results: [(Int, PhotoIngest.Prepared?)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
            }
            guard !prepared.isEmpty else { return }

            self.photos[index].spaceImageFilenames.append(contentsOf: prepared.map(\.filename))
            var current = self.spaceImages[id] ?? []
            current.append(contentsOf: prepared.map(\.url))
            self.spaceImages[id] = current
            self.persist()
        }
    }
}
