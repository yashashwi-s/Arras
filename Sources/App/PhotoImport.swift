import AppKit
import UniformTypeIdentifiers

/// Ways of getting an image into the app that aren't the open panel: the
/// pasteboard (⌘V) and drags onto the menu bar icon. Both funnel into
/// `addPhoto`, so imported images pick up the same defaults as any other.
extension PhotoManager {

    /// Image formats accepted from a drag or a paste. Matches what `NSImage`
    /// can actually decode — anything else is silently skipped rather than
    /// creating an empty widget.
    static let importableTypes: [UTType] = [.image, .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

    /// Whether there's something on the pasteboard we could turn into a widget.
    /// Drives menu item enablement so ⌘V never looks available when it isn't.
    var pasteboardHasImage: Bool {
        Self.imageCount(on: .general) > 0
    }

    /// Creates widgets from every image on the pasteboard.
    /// - Returns: the number of widgets created.
    @discardableResult
    func addFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Int {
        // File URLs are checked first on purpose: copying a file in Finder puts
        // both the URL *and* a downscaled preview on the pasteboard, and the
        // original file is the higher-fidelity source of the two.
        let urls = Self.imageFileURLs(on: pasteboard)
        if !urls.isEmpty {
            return addImages(from: urls)
        }

        guard let image = NSImage(pasteboard: pasteboard), image.isValid else {
            recordMediaImportFailure("The pasted image could not be decoded.")
            return 0
        }
        addPhoto(image)
        return 1
        // Left on the NSImage path deliberately: a pasteboard image has no original file
        // behind it, so there are no source bytes to pass through.
    }

    /// Creates widgets from image files on disk. Used by drag-and-drop.
    ///
    /// Returns how many files *look* importable and kicks the real work off in the
    /// background — the caller (a drag handler) has no way to await, and the batched path
    /// prepares the files concurrently off the main actor.
    /// - Returns: the number of widgets that will be created.
    @discardableResult
    func addImages(from urls: [URL]) -> Int {
        let candidates = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return Self.importableTypes.contains { type.conforms(to: $0) }
        }
        guard !candidates.isEmpty else { return 0 }
        Task { @MainActor in await addPhotos(urls: candidates) }
        return candidates.count
    }

    // MARK: - Pasteboard inspection

    /// File URLs on the pasteboard that point at decodable images.
    static func imageFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: importableTypes.map(\.identifier)
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    /// How many images the pasteboard is offering, without decoding them.
    static func imageCount(on pasteboard: NSPasteboard) -> Int {
        let urls = imageFileURLs(on: pasteboard)
        if !urls.isEmpty { return urls.count }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) ? 1 : 0
    }
}
