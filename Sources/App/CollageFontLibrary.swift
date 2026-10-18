import AppKit
import CoreText

enum CollageFontError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self { case .invalid: return "That file could not be opened as a font. Choose a TTF or OTF file."; case .tooLarge: return "That font file is too large to import." }
    }
}

struct ImportedCollageFont {
    let fileName: String
    let names: [String]
    let url: URL
}

enum CollageFontLibrary {
    static func isManagedFilename(_ name: String) -> Bool {
        name == (name as NSString).lastPathComponent && UUID(uuidString: (name as NSString).deletingPathExtension) != nil
            && ["ttf", "otf", "ttc"].contains((name as NSString).pathExtension.lowercased())
    }

    static func directory(in storage: URL) -> URL { storage.appendingPathComponent("Fonts", isDirectory: true) }

    static func names(at url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
    }

    static func register(_ url: URL) -> Bool { registerForImport(url) != nil }

    /// True means this operation registered it; false means it was already available.
    static func registerForImport(_ url: URL) -> Bool? {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Installed/system fonts may already be registered. Keep the requested
        // choice and local asset rather than replacing its persisted font name.
        guard let error else { return nil }
        return CFErrorGetCode(error.takeRetainedValue()) == CTFontManagerError.alreadyRegistered.rawValue ? false : nil
    }

    static func unregister(_ url: URL) {
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    static func load(in storage: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(in: storage), includingPropertiesForKeys: nil)) ?? []
        for url in urls where isManagedFilename(url.lastPathComponent) { _ = register(url) }
    }

    static func filesByFontName(in storage: URL) -> [String: String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(in: storage), includingPropertiesForKeys: nil)) ?? []
        var result: [String: String] = [:]
        for url in urls where isManagedFilename(url.lastPathComponent) {
            for name in names(at: url) { result[name] = url.lastPathComponent }
        }
        return result
    }

    /// Imports are reusable library assets, independent of editor acceptance.
    /// Deletion is explicit and protects saved layouts plus all open drafts.
    static func removeUnused(in storage: URL, retaining names: Set<String>) throws -> Int {
        let folder = directory(in: storage)
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        var protected = names
        let store = storage.appendingPathComponent("photos.json")
        if FileManager.default.fileExists(atPath: store.path) {
            // Fail closed if durable references cannot be verified, including
            // when the in-memory library could not load a damaged store.
            let items = try JSONDecoder().decode([PhotoItem].self, from: Data(contentsOf: store))
            protected.formUnion(items.flatMap { $0.desktopCollage?.fontFileNames ?? [] })
        }
        let setups = try DesktopSetupLibrary.read(in: storage)
        protected.formUnion(setups.retainedPhotos.flatMap { $0.desktopCollage?.fontFileNames ?? [] })
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var removed = 0
        for url in urls where isManagedFilename(url.lastPathComponent) && !protected.contains(url.lastPathComponent) {
            unregister(url)
            do { try FileManager.default.removeItem(at: url) }
            catch { _ = register(url); throw error }
            removed += 1
        }
        load(in: storage)
        return removed
    }

    static func importFont(from source: URL, into storage: URL) throws -> ImportedCollageFont {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw CollageFontError.tooLarge }
        let data = try Data(contentsOf: source)
        return try importFont(data: data, extension: source.pathExtension, into: storage)
    }

    static func importFont(data: Data, extension ext: String, into storage: URL) throws -> ImportedCollageFont {
        guard data.count <= 20_000_000 else { throw CollageFontError.tooLarge }
        guard ["ttf", "otf", "ttc"].contains(ext.lowercased()) else { throw CollageFontError.invalid }
        let name = UUID().uuidString + "." + ext.lowercased()
        let folder = directory(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let fontNames = names(at: url)
        guard !fontNames.isEmpty, register(url) else { try? FileManager.default.removeItem(at: url); throw CollageFontError.invalid }
        return ImportedCollageFont(fileName: name, names: fontNames, url: url)
    }
}
