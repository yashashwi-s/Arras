import AppKit
import UniformTypeIdentifiers

/// Ways of getting an image into the app that aren't the open panel: the
/// pasteboard (⌘V) and drags onto the menu bar icon. Both funnel into the same
/// byte-based importer, so format detection and batch reporting stay consistent.
extension PhotoManager {

    /// Image and movie types advertised by drag/paste inputs. Preparation validates their
    /// bytes and reports unsupported or undecodable media through the shared batch result.
    static let importableTypes: [UTType] = PhotoImportPolicy.supportedTypes

    /// Whether there's something on the pasteboard we could turn into a widget.
    /// Drives menu item enablement so ⌘V never looks available when it isn't.
    var pasteboardHasImage: Bool {
        Self.imageCount(on: .general) > 0
    }

    /// Imports the pasteboard's original file bytes when Finder copied a file, or its image
    /// bytes when another app supplied a bitmap. Keeping the bytes intact is what lets WebP and
    /// BMP use the same persistence and archive path as the older image formats.
    @discardableResult
    func importFromPasteboard(_ pasteboard: NSPasteboard = .general) async -> ImportBatchResult {
        // File URLs are checked first on purpose: copying a file in Finder puts both the URL and
        // a downscaled preview on the pasteboard, and the original file is the higher-fidelity
        // source of the two.
        let urls = Self.imageFileURLs(on: pasteboard)
        if !urls.isEmpty {
            return await importPhotos(urls: urls)
        }

        if let data = Self.imageData(on: pasteboard) {
            return await importPhotos(data: [data], sourceNames: ["Clipboard image"])
        }

        guard let image = NSImage(pasteboard: pasteboard), image.isValid,
              let tiff = image.tiffRepresentation else {
            return ImportBatchResult(entries: [
                .init(
                    source: "Clipboard image",
                    status: .failed,
                    reason: "The pasteboard did not contain a decodable image."
                )
            ])
        }
        return await importPhotos(data: [tiff], sourceNames: ["Clipboard image"])
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
        if imageData(on: pasteboard) != nil { return 1 }
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) ? 1 : 0
    }

    /// Original image payloads on the pasteboard, including public.webp and public.bmp data.
    /// Some producers expose only an `NSImage`, so callers retain the TIFF fallback above.
    private static func imageData(on pasteboard: NSPasteboard) -> Data? {
        for rawType in pasteboard.types ?? [] {
            guard let type = UTType(rawType.rawValue), type.conforms(to: .image),
                  let data = pasteboard.data(forType: rawType) else { continue }
            return data
        }
        return nil
    }
}
