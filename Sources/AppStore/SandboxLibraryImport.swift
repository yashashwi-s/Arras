import AppKit
import ImageIO

/// A user-selected copy, including saved setups and fonts, avoids assuming the unsandboxed
/// library is accessible or that a historical sandbox container contains the newest desktop.
enum SandboxLibraryImport {
    enum ImportError: LocalizedError {
        case destinationNotEmpty, invalidLibrary, unsafeFile(String), changedDesktop
        var errorDescription: String? {
            switch self {
            case .destinationNotEmpty:
                return "This app already has saved content. Export an .arras backup from the other app and use Import Backup to merge it instead."
            case .invalidLibrary:
                return "Choose the PhotoWidget library folder containing photos.json and its stored media. No existing library was changed."
            case .unsafeFile(let name):
                return "The library contains an unreadable or invalid file: \(name). No existing library was changed."
            case .changedDesktop:
                return "The desktop changed while the library was being prepared. Your current desktop was kept. Try the import again on an empty desktop."
            }
        }
    }

    static func destinationIsEmpty(_ directory: URL) -> Bool {
        let manifest = directory.appendingPathComponent("photos.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard let data = try? Data(contentsOf: manifest),
                  let photos = try? JSONDecoder().decode([PhotoItem].self, from: data), photos.isEmpty else { return false }
        }
        guard let setups = try? DesktopSetupLibrary.read(in: directory) else { return false }
        return setups.setups.isEmpty && setups.previous == nil && setups.removed == nil
    }

    static func prepare(from source: URL, stagingParent: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try safeFile("photos.json", in: canonicalSource)
        if fileManager.fileExists(atPath: canonicalSource.appendingPathComponent("setups.json").path) {
            _ = try safeFile("setups.json", in: canonicalSource)
        }
        guard let data = try? Data(contentsOf: manifest),
              let original = try? JSONDecoder().decode([PhotoItem].self, from: data),
              Set(original.map(\.id)).count == original.count,
              let originalSetups = try? DesktopSetupLibrary.read(in: canonicalSource) else { throw ImportError.invalidLibrary }

        let staging = stagingParent.appendingPathComponent("ArrasLibraryImport-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var ready = false
        defer { if !ready { try? fileManager.removeItem(at: staging) } }
        let all = original + originalSetups.retainedPhotos
        let media = Set(all.flatMap { PhotoManager.managedFilenames(in: $0) })
        for name in media {
            let file = try safeFile(name, in: canonicalSource)
            let copied = staging.appendingPathComponent(name)
            try fileManager.copyItem(at: file, to: copied)
            if VideoMediaSupport.isSupportedVideoURL(copied) {
                guard VideoMediaSupport.isPlayableVideo(at: copied) else { throw ImportError.unsafeFile(name) }
            } else {
                guard let image = CGImageSourceCreateWithURL(copied as CFURL, nil),
                      CGImageSourceGetCount(image) > 0,
                      CGImageSourceCreateThumbnailAtIndex(image, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 128
                      ] as CFDictionary) != nil else { throw ImportError.unsafeFile(name) }
            }
        }
        let fonts = Set(all.flatMap { $0.desktopCollage?.fontFileNames ?? [] })
        if !fonts.isEmpty {
            let fontSource = CollageFontLibrary.directory(in: canonicalSource)
            guard fontSource.resolvingSymlinksInPath().deletingLastPathComponent() == canonicalSource else {
                throw ImportError.unsafeFile(fontSource.lastPathComponent)
            }
            let fontDestination = CollageFontLibrary.directory(in: staging)
            try fileManager.createDirectory(at: fontDestination, withIntermediateDirectories: true)
            for name in fonts {
                guard CollageFontLibrary.isManagedFilename(name) else { throw ImportError.unsafeFile(name) }
                let copied = fontDestination.appendingPathComponent(name)
                try fileManager.copyItem(at: safeFile(name, in: fontSource), to: copied)
                guard !CollageFontLibrary.names(at: copied).isEmpty else { throw ImportError.unsafeFile(name) }
            }
        }

        // Access grants belong to the old signed app. Preserve the last snapshots and require
        // an explicit folder selection rather than treating persisted paths as authorization.
        func relink(_ photos: [PhotoItem]) -> [PhotoItem] {
            photos.map { photo in
                var copy = photo
                copy.liveFolderSource = copy.liveFolderSource?.archiveSnapshot
                return copy
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(relink(original)).write(to: staging.appendingPathComponent("photos.json"), options: .atomic)
        var setups = originalSetups
        for index in setups.setups.indices { setups.setups[index].photos = relink(setups.setups[index].photos) }
        if var previous = setups.previous { previous.photos = relink(previous.photos); setups.previous = previous }
        if let removed = setups.removed {
            setups.removed = RemovedWidgets(photos: relink(removed.photos), detachedChildren: removed.detachedChildren)
        }
        try setups.write(in: staging)
        ready = true
        return staging
    }

    /// Copy only files referenced by decoded models; never follow links outside the selection.
    private static func safeFile(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), name == URL(fileURLWithPath: name).lastPathComponent else {
            throw ImportError.unsafeFile(name)
        }
        let file = directory.appendingPathComponent(name)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.standardizedFileURL else {
            throw ImportError.unsafeFile(name)
        }
        return file
    }

    static func commit(_ staging: URL, to destination: URL,
                       move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        guard destinationIsEmpty(destination) else { throw ImportError.destinationNotEmpty }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: staging.appendingPathComponent("photos.json").path) else {
            throw ImportError.invalidLibrary
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent("PhotoWidget-before-import-" + UUID().uuidString, isDirectory: true)
        let hadDestination = fileManager.fileExists(atPath: destination.path)
        if hadDestination { try move(destination, backup) }
        do {
            try move(staging, destination)
        } catch {
            // A failed cross-volume move can leave a partial destination. The original
            // remains in backup until it has been restored successfully.
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            if hadDestination { try move(backup, destination) }
            throw error
        }
        // Retain any former empty library's unreferenced files for recovery.
    }
}

@MainActor
extension PhotoManager {
    var canImportExistingLibrary: Bool {
        photos.isEmpty && !hasPendingMediaImport && SandboxLibraryImport.destinationIsEmpty(storageDir)
    }

    func importExistingLibrary(from source: URL) async throws {
        guard canImportExistingLibrary else { throw SandboxLibraryImport.ImportError.destinationNotEmpty }
        let destination = storageDir
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
            throw SandboxLibraryImport.ImportError.invalidLibrary
        }
        let generation = desktopGeneration
        // Stage next to the destination so the final directory move stays on one volume.
        let stagingParent = destination.deletingLastPathComponent()
        beginMediaImport()
        defer { endMediaImport() }
        let staging = try await Task.detached(priority: .userInitiated) {
            try SandboxLibraryImport.prepare(from: source, stagingParent: stagingParent)
        }.value
        defer { try? FileManager.default.removeItem(at: staging) }
        guard !Task.isCancelled, desktopGeneration == generation, photos.isEmpty,
              SandboxLibraryImport.destinationIsEmpty(destination) else { throw SandboxLibraryImport.ImportError.changedDesktop }
        try SandboxLibraryImport.commit(staging, to: destination)
        loadSaved()
        removedWidgetCount = (try? DesktopSetupLibrary.read(in: destination).removed?.photos.count) ?? 0
        installLiveFolderWatchers()
    }
}
