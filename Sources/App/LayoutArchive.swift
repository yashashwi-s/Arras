import Foundation
import AppKit

// MARK: - Layout Export/Import
//
// An `.arras` archive is a portable single ZIP containing a manifest, managed
// media and referenced fonts. The STORE-only reader/writer preserves those bytes
// without relying on an external process or a Finder directory package.

// MARK: - Manifest

/// Top-level contents of an `.arras` bundle's manifest.json.
///
/// `formatVersion` exists so a future change to the archive layout (not just to
/// `PhotoItem`, which already tolerates missing keys) can detect and adapt to older
/// bundles instead of failing to decode them silently.
struct LayoutManifest: Codable {
    /// v3 adds export scope, media integrity, and provenance metadata. Every added field is
    /// optional so a v1 bundle still decodes, and a v1 app reading a v2 bundle simply
    /// ignores what it doesn't know.
    static let currentFormatVersion = 3

    let formatVersion: Int
    let appVersion: String
    let exportedAt: Date
    let photos: [PhotoItem]

    /// Number of widgets, so a bundle can be described without unpacking it.
    let itemCount: Int?

    /// App-wide settings, absent unless the user chose to include them.
    let preferences: ExportedPreferences?

    /// Screen-independent positions, keyed by `PhotoItem.id` string.
    let relativeFrames: [String: RelativeFrame]?

    /// Screen-independent positions for per-image Space frames:
    /// photo id -> image filename -> position.
    let relativeImageFrames: [String: [String: RelativeFrame]]?

    /// Scope, integrity hashes, and honest source-fidelity wording for new exports.
    /// Missing on older archives, which therefore receive unknown provenance on import.
    let exportMetadata: ArchiveExportMetadata?
}

/// A window position expressed as fractions of the screen's `visibleFrame` rather than
/// in absolute points.
///
/// Absolute coordinates are meaningless on a Mac with a different display: a widget
/// parked in the bottom-right of a 1440-wide laptop screen lands somewhere near the
/// middle of a 5K display. Storing the centre as a fraction keeps a layout's *shape*
/// intact across machines, which is what "move my setup to another Mac" actually means.
struct RelativeFrame: Codable {
    /// Centre of the widget, 0...1 across the screen's visible area.
    var centerX: Double
    var centerY: Double
    /// Width as a fraction of screen width, so a widget keeps its visual weight
    /// rather than shrinking to a stamp on a much larger display.
    var widthFraction: Double

    init(frame: NSRect, in visibleFrame: NSRect) {
        let w = max(visibleFrame.width, 1)
        let h = max(visibleFrame.height, 1)
        centerX = Double((frame.midX - visibleFrame.minX) / w)
        centerY = Double((frame.midY - visibleFrame.minY) / h)
        widthFraction = Double(frame.width / w)
    }

    /// Rebuilds an absolute frame on the target screen, preserving the source aspect
    /// ratio. Sizes are clamped so a bad or extreme fraction can't produce a widget
    /// too small to grab or larger than the screen.
    func absoluteFrame(in visibleFrame: NSRect, aspectRatio: CGFloat) -> NSRect {
        let width = min(
            max(CGFloat(widthFraction) * visibleFrame.width, 80),
            visibleFrame.width
        )
        let height = aspectRatio > 0 ? width / aspectRatio : width
        let cx = visibleFrame.minX + CGFloat(centerX) * visibleFrame.width
        let cy = visibleFrame.minY + CGFloat(centerY) * visibleFrame.height
        return NSRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }
}

/// App-wide settings that live in `UserDefaults` rather than in `photos.json`.
///
/// Without these an `.arras` only carries half a setup — the widgets arrive but the
/// hotkey, snapping, and login behaviour don't. Import is opt-in precisely because
/// these are global: a layout someone shares should never silently rebind the
/// recipient's system-wide shortcut or change what launches at login.
/// Every field is Optional on purpose: an absent key means "this backup doesn't carry that
/// setting", which is also exactly what an older app reading a newer file sees. That makes the
/// format forward- and backward-compatible without any `decodeIfPresent` bookkeeping, and it
/// is what lets the export dialog offer per-group checkboxes — an unchecked group is simply nil.
struct ExportedPreferences: Codable {
    // General
    var launchAtLogin: Bool?
    var snapToEdgesEnabled: Bool?
    var snapToOtherAppsEnabled: Bool?
    var hideMenuBarIcon: Bool?

    // Global shortcut
    var globalHotKeyEnabled: Bool?
    var globalHotKeyShortcut: Shortcut?

    // Menu bar contents
    var menuBarItems: [String: Bool]?

    // Updates
    var updateCheckFrequency: TimeInterval?
    var automaticUpdatesEnabled: Bool?

    // Privacy
    var excludeFromScreenCapture: Bool?
    var autoHideForConferencingApps: Bool?
    var hideWhenFullscreenActive: Bool?

    /// Which groups a backup carries. Drives the export checkboxes, and the import dialog's
    /// description of what a file will change.
    enum Group: String, CaseIterable, Identifiable {
        case general, shortcut, menuBar, updates, privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General (login, snapping, menu bar icon)"
            case .shortcut: return "Global shortcut"
            case .menuBar: return "Menu bar commands"
            case .updates: return "Update behavior"
            case .privacy: return "Privacy"
            }
        }
    }

    /// Snapshot of the current app settings, limited to `groups`.
    ///
    /// The old version of this exported five settings out of roughly seventeen and said
    /// nothing about the omission, so restoring on a new Mac quietly lost the update
    /// frequency, automatic-install choice, every menu bar toggle and all three privacy switches.
    @MainActor
    static func current(launchAtLogin: Bool, groups: Set<Group> = Set(Group.allCases)) -> ExportedPreferences {
        var prefs = ExportedPreferences()

        if groups.contains(.general) {
            prefs.launchAtLogin = launchAtLogin
            prefs.snapToEdgesEnabled = SnapEngine.shared.isEnabled
            prefs.snapToOtherAppsEnabled = SnapEngine.shared.includesOtherApps
            prefs.hideMenuBarIcon = UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        }
        if groups.contains(.shortcut) {
            prefs.globalHotKeyEnabled = HotKeyManager.shared.isEnabled
            prefs.globalHotKeyShortcut = HotKeyManager.shared.shortcut
        }
        if groups.contains(.menuBar) {
            var items: [String: Bool] = [:]
            for item in MenuBarCustomization.Item.allCases {
                items[item.rawValue] = MenuBarCustomization.shared.isVisible(item)
            }
            prefs.menuBarItems = items
        }
#if !ARRAS_APP_STORE
        if groups.contains(.updates) {
            prefs.updateCheckFrequency = Updater.shared.checkFrequency.rawValue
            prefs.automaticUpdatesEnabled = Updater.shared.automaticUpdatesEnabled
        }
#endif
        if groups.contains(.privacy) {
            prefs.excludeFromScreenCapture = UserDefaults.standard.bool(forKey: "presence.excludeFromScreenCapture")
            prefs.autoHideForConferencingApps = UserDefaults.standard.bool(forKey: "presence.autoHideForConferencingApps")
            prefs.hideWhenFullscreenActive = UserDefaults.standard.bool(forKey: "presence.hideWhenFullscreenActive")
        }
        return prefs
    }

    /// Which groups this file actually carries.
    var groups: Set<Group> {
        var found: Set<Group> = []
        if launchAtLogin != nil || snapToEdgesEnabled != nil || hideMenuBarIcon != nil { found.insert(.general) }
        if globalHotKeyEnabled != nil || globalHotKeyShortcut != nil { found.insert(.shortcut) }
        if menuBarItems != nil { found.insert(.menuBar) }
        if updateCheckFrequency != nil || automaticUpdatesEnabled != nil { found.insert(.updates) }
        if excludeFromScreenCapture != nil || autoHideForConferencingApps != nil || hideWhenFullscreenActive != nil {
            found.insert(.privacy)
        }
        return found
    }

    /// A short human-readable list, so the import dialog can say what it is about to change.
    var summary: String {
        let names = Group.allCases.filter { groups.contains($0) }.map { $0.rawValue }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

enum LayoutArchiveError: LocalizedError, Equatable {
    case notAZipFile
    case missingManifest
    case emptyLayout
    case widgetNotFound(UUID)
    case missingStoredMedia(String)
    case couldNotStageMedia(String)
    case couldNotCommit
    case unsupportedFormatVersion(Int)
    case missingStoredFont(String)

    var errorDescription: String? {
        switch self {
        case .notAZipFile: return "That file isn't a valid .arras bundle."
        case .missingManifest: return "That bundle is missing its layout data."
        case .emptyLayout: return "There are no photos to export."
        case .widgetNotFound: return "That widget is no longer available to export."
        case .missingStoredMedia(let filename):
            return "The stored image \(filename) could not be included in the layout bundle."
        case .couldNotStageMedia(let filename):
            return "The imported media \(filename) could not be staged safely."
        case .couldNotCommit:
            return "The current layout could not be saved, so the import was not applied."
        case .unsupportedFormatVersion(let version):
            return "This backup uses format version \(version), which this version of Arras cannot import safely."
        case .missingStoredFont(let filename):
            return "The layout's custom font \(filename) is missing or could not be opened."
        }
    }
}

/// One validated widget waiting for the user's import selection. Media is staged outside the
/// durable photo store until `commitImport` is called, so Cancel and a failed Replace can cleanly
/// discard every byte without touching the current layout.
struct LayoutImportCandidate: Identifiable {
    let id: Int
    let item: PhotoItem
    let stagedURLs: [URL]
    let mediaCount: Int
    var stagedFontURLs: [URL] = []

    var typeName: String {
        if item.desktopCollage != nil { return "Collage" }
        if !item.spaceImageFilenames.isEmpty { return "Space" }
        return "Photo"
    }

    var displayName: String {
        if let customName = item.customName?.trimmingCharacters(in: .whitespacesAndNewlines), !customName.isEmpty {
            return customName
        }
        if !item.filename.isEmpty {
            let name = (item.filename as NSString).deletingPathExtension
            if !name.isEmpty { return name }
        }
        return typeName
    }
}

struct LayoutImportPreflight {
    let manifest: LayoutManifest
    let candidates: [LayoutImportCandidate]
    let skippedReasons: [String]
    let stagingDirectory: URL

    var skippedCount: Int { skippedReasons.count }
    var hasCandidates: Bool { !candidates.isEmpty }

    /// Removes all staged media. This is idempotent so callers can use it after either Cancel or
    /// a successful commit without needing a second ownership flag.
    func cleanup() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

// MARK: - PhotoManager Export/Import

extension PhotoManager {
    enum LayoutImportMode {
        case replace
        case merge
    }

    /// Writes every current widget (photos, slideshows, and desktop collages) plus its
    /// positions and aesthetic settings into a whole-layout `.arras` bundle. The existing API
    /// remains the default path; `archivalQuality` adds integrity/provenance metadata while
    /// retaining the exact stored bytes in either mode.
    @discardableResult
    func exportLayout(
        to url: URL,
        preferenceGroups: Set<ExportedPreferences.Group> = [],
        archivalQuality: Bool = false
    ) throws -> ArchiveExportReport {
        try exportArchive(
            items: photos,
            to: url,
            preferenceGroups: preferenceGroups,
            archivalQuality: archivalQuality,
            scope: .wholeLayout
        )
    }

    /// Exports one widget as a portable `.arras` bundle. A slideshow includes all
    /// of its referenced media, while a regular widget includes its primary stored file.
    @discardableResult
    func exportWidget(
        _ id: UUID,
        to url: URL,
        archivalQuality: Bool = false
    ) throws -> ArchiveExportReport {
        guard let item = photos.first(where: { $0.id == id }) else {
            throw LayoutArchiveError.widgetNotFound(id)
        }
        let items: [PhotoItem]
        if item.desktopCollage != nil {
            items = [item] + photos.filter { $0.collageParentID == item.id }
        } else {
            items = [item]
        }
        return try exportArchive(
            items: items,
            to: url,
            preferenceGroups: [],
            archivalQuality: archivalQuality,
            scope: .widget
        )
    }

    /// Shared writer for whole-layout and per-widget exports. The ZIP is STORE-only, so the
    /// archive always contains the exact bytes currently in the photo store. Archival mode is an
    /// explicit audit guarantee (hashes plus provenance wording), not a promise to recreate
    /// camera originals that were downsampled or re-encoded before Arras stored them.
    private func exportArchive(
        items: [PhotoItem],
        to url: URL,
        preferenceGroups: Set<ExportedPreferences.Group>,
        archivalQuality: Bool,
        scope: LayoutArchiveScope
    ) throws -> ArchiveExportReport {
        guard !items.isEmpty else { throw LayoutArchiveError.emptyLayout }

        // A live folder's managed media is portable; its security-scoped bookmark, absolute
        // path, and resource fingerprint are machine-local and must never enter an archive.
        let includedIDs = Set(items.map(\.id))
        let sanitizedItems = items.map { source -> PhotoItem in
            var snapshot = archiveSafeSnapshot(of: source)
            if let parentID = snapshot.collageParentID, !includedIDs.contains(parentID) { snapshot.collageParentID = nil }
            return snapshot
        }

        var writer = SimpleZipWriter()
        var writtenImages = Set<String>()
        var mediaRecords: [ArchiveMediaRecord] = []
        var fidelityByFilename: [String: ArchiveMediaFidelity] = [:]
        var payloadsByFilename: [String: Data] = [:]
        var orderedFilenames: [String] = []

        for item in sanitizedItems {
            if referencedFilenames(of: item).allSatisfy(\.isEmpty), item.desktopCollage == nil {
                throw LayoutArchiveError.missingStoredMedia(item.filename)
            }
            for name in referencedFilenames(of: item) where !name.isEmpty && !writtenImages.contains(name) {
                writtenImages.insert(name)
                // Stored references must be leaf filenames. Refuse a corrupt model value such
                // as `../secret` rather than allowing an export to read outside the media store.
                guard (name as NSString).lastPathComponent == name,
                      name != ".", name != ".." else {
                    throw LayoutArchiveError.missingStoredMedia(name)
                }
                let source = storageDir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: source) else {
                    throw LayoutArchiveError.missingStoredMedia(name)
                }
                writer.addEntry(name: "images/\(name)", data: data)
                payloadsByFilename[name] = data
                orderedFilenames.append(name)
            }
            for name in referencedFilenames(of: item) where !name.isEmpty {
                let fidelity = item.mediaFidelity[name] ?? .unknown
                if let existing = fidelityByFilename[name] {
                    fidelityByFilename[name] = existing.merged(with: fidelity)
                } else {
                    fidelityByFilename[name] = fidelity
                }
            }
        }
        mediaRecords = orderedFilenames.compactMap { filename in
            guard let data = payloadsByFilename[filename] else { return nil }
            return ArchiveMediaRecord(
                filename: filename,
                data: data,
                fidelity: fidelityByFilename[filename] ?? .unknown
            )
        }

        let fontNames = Set(sanitizedItems.flatMap { $0.desktopCollage?.fontFileNames ?? [] })
        for name in fontNames {
            guard CollageFontLibrary.isManagedFilename(name),
                  let data = try? Data(contentsOf: CollageFontLibrary.directory(in: storageDir).appendingPathComponent(name)) else {
                throw LayoutArchiveError.missingStoredFont(name)
            }
            writer.addEntry(name: "fonts/\(name)", data: data)
        }

        // Record every frame as a fraction of the screen it currently sits on, so the
        // layout can be rebuilt in proportion on a Mac with different displays.
        var relativeFrames: [String: RelativeFrame] = [:]
        var relativeImageFrames: [String: [String: RelativeFrame]] = [:]
        for item in sanitizedItems {
            let key = item.id.uuidString
            if let relative = Self.relativeFrame(for: item.frameString) {
                relativeFrames[key] = relative
            }
            var perImage: [String: RelativeFrame] = [:]
            for (filename, config) in item.folderImageConfigs {
                if let relative = Self.relativeFrame(for: config.frameString) {
                    perImage[filename] = relative
                }
            }
            if !perImage.isEmpty { relativeImageFrames[key] = perImage }
        }

        let sourceStatus = ArchiveSourceStatus(media: mediaRecords)
        let exportMetadata = ArchiveExportMetadata(
            scope: scope,
            archivalQuality: archivalQuality,
            media: mediaRecords,
            statement: ArchiveExportMetadata.statement(
                archivalQuality: archivalQuality,
                sourceStatus: sourceStatus
            )
        )
        let manifest = LayoutManifest(
            formatVersion: LayoutManifest.currentFormatVersion,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            exportedAt: Date(),
            photos: sanitizedItems,
            itemCount: sanitizedItems.count,
            preferences: preferenceGroups.isEmpty ? nil : .current(launchAtLogin: launchAtLogin, groups: preferenceGroups),
            relativeFrames: relativeFrames.isEmpty ? nil : relativeFrames,
            relativeImageFrames: relativeImageFrames.isEmpty ? nil : relativeImageFrames,
            exportMetadata: exportMetadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        writer.addEntry(name: "manifest.json", data: try encoder.encode(manifest))

        try writer.write(to: url)
        return ArchiveExportReport(
            scope: scope,
            widgetCount: sanitizedItems.count,
            mediaCount: mediaRecords.count,
            archivalQuality: archivalQuality,
            sourceStatus: sourceStatus,
            statement: exportMetadata.statement
        )
    }

    /// Imports an `.arras` bundle. In `.replace` mode the current layout is replaced in one
    /// durable model commit after every imported media payload has been staged and decoded —
    /// callers must still confirm this with the user, since a successful replacement can't be
    /// undone. In `.merge` mode imported photos are appended in the same single commit.
    ///
    /// Every imported item gets a fresh id and fresh image filenames (via
    /// `PhotoItem(filename:)`) so importing the same bundle twice — or into a Mac that
    /// already has some of these photos — never collides. Entries whose image data is missing
    /// from the bundle or cannot be decoded are skipped rather than creating an empty widget,
    /// and any saved frame that would land completely off every connected screen is recentered
    /// onto the main screen instead of appearing there.
    @discardableResult
    func importLayout(from url: URL, mode: LayoutImportMode) throws -> Int {
        let preflight = try preflightImportLayout(from: url)
        return try commitImport(
            preflight,
            selectedIDs: Set(preflight.candidates.map(\.id)),
            mode: mode
        )
    }

    /// Parses, validates, and stages every widget without changing the durable layout. The
    /// resulting candidates are safe to show in a selection UI; only `commitImport` moves the
    /// selected files into the library and changes `photos.json`.
    func preflightImportLayout(from url: URL) throws -> LayoutImportPreflight {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let reader = try SimpleZipReader(data: try Data(contentsOf: url))
        guard let manifestData = reader.entryData(named: "manifest.json") else {
            throw LayoutArchiveError.missingManifest
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LayoutManifest.self, from: manifestData)
        guard manifest.formatVersion > 0,
              manifest.formatVersion <= LayoutManifest.currentFormatVersion else {
            throw LayoutArchiveError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard Set(manifest.photos.map(\.id)).count == manifest.photos.count else {
            throw LayoutArchiveError.missingManifest
        }
        let stagingDirectory = storageDir.appendingPathComponent(
            ".arras-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var shouldKeepStaging = false
        defer {
            if !shouldKeepStaging {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        var integrityRecords: [String: ArchiveMediaRecord] = [:]
        for record in manifest.exportMetadata?.media ?? [] {
            integrityRecords[record.filename] = record
        }
        var fontMap: [String: URL] = [:]
        let fontDirectory = CollageFontLibrary.directory(in: stagingDirectory)
        for name in Set(manifest.photos.flatMap { $0.desktopCollage?.fontFileNames ?? [] }) {
            guard CollageFontLibrary.isManagedFilename(name),
                  let payload = reader.entryData(named: "fonts/\(name)"), payload.count <= 20_000_000 else {
                throw LayoutArchiveError.missingStoredFont(name)
            }
            try FileManager.default.createDirectory(at: fontDirectory, withIntermediateDirectories: true)
            let newName = UUID().uuidString + "." + (name as NSString).pathExtension.lowercased()
            let stagedURL = fontDirectory.appendingPathComponent(newName)
            try payload.write(to: stagedURL, options: .atomic)
            guard !CollageFontLibrary.names(at: stagedURL).isEmpty else { throw LayoutArchiveError.missingStoredFont(name) }
            fontMap[name] = stagedURL
        }
        var candidates: [LayoutImportCandidate] = []
        var skippedReasons: [String] = []

        for (index, sourceItem) in manifest.photos.enumerated() where !sourceItem.isRetiredCompositionContainer {
            var names: [String] = []
            for name in referencedFilenames(of: sourceItem) where !name.isEmpty && !names.contains(name) {
                names.append(name)
            }
            let sourceLabel = sourceItem.customName?.isEmpty == false
                ? sourceItem.customName!
                : (sourceItem.spaceImageFilenames.isEmpty ? "Photo" : "Space")
            guard !names.isEmpty || sourceItem.desktopCollage != nil else {
                skippedReasons.append("\(sourceLabel): no referenced media")
                continue
            }

            var payloads: [String: Data] = [:]
            var validationFailure: String?
            for name in names {
                guard let payload = reader.entryData(named: "images/\(name)") else {
                    validationFailure = "missing media \(name)"
                    break
                }
                if manifest.exportMetadata != nil {
                    guard let record = integrityRecords[name], record.matches(payload) else {
                        validationFailure = "media integrity check failed for \(name)"
                        break
                    }
                }
                payloads[name] = payload
            }
            guard validationFailure == nil else {
                skippedReasons.append("\(sourceLabel): \(validationFailure!)")
                continue
            }

            var filenameMap: [String: String] = [:]
            for name in names {
                let ext = (name as NSString).pathExtension
                filenameMap[name] = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
            }

            var stagedURLs: [URL] = []
            var stageError: String?
            for name in names {
                guard let payload = payloads[name], let newName = filenameMap[name] else { continue }
                let stagedURL = stagingDirectory.appendingPathComponent(newName)
                do {
                    try payload.write(to: stagedURL, options: .atomic)
                    stagedURLs.append(stagedURL)
                } catch {
                    stageError = newName
                    break
                }
            }
            func stagedURL(for originalName: String) -> URL? {
                guard let mappedName = filenameMap[originalName] else { return nil }
                return stagingDirectory.appendingPathComponent(mappedName)
            }

            func validates(_ media: PhotoMedia, primaryName: String) -> Bool {
                guard let primaryURL = stagedURL(for: primaryName) else { return false }
                let posterURL = media.posterFilename.flatMap { stagedURL(for: $0) }
                let pairedVideoURL = media.pairedVideoFilename.flatMap { stagedURL(for: $0) }
                if media.kind == .livePhoto && pairedVideoURL == nil { return false }
                return PhotoContent.load(
                    from: primaryURL,
                    posterURL: posterURL,
                    pairedVideoURL: pairedVideoURL
                ) != nil
            }

            let individuallyValid = stagedURLs.allSatisfy({ PhotoContent.load(from: $0) != nil })
            let primaryMediaValid = sourceItem.filename.isEmpty
                || validates(sourceItem.media, primaryName: sourceItem.filename)
            let collectionMediaValid = sourceItem.photosLibraryAssets.allSatisfy {
                validates($0.media, primaryName: $0.managedFilename)
            }
            guard stageError == nil,
                  stagedURLs.count == names.count,
                  individuallyValid,
                  primaryMediaValid,
                  collectionMediaValid else {
                for stagedURL in stagedURLs { try? FileManager.default.removeItem(at: stagedURL) }
                skippedReasons.append("\(sourceLabel): media could not be staged or decoded")
                continue
            }

            var item = remapped(sourceItem, filenameMap: filenameMap)
            if var settings = item.desktopCollage {
                if let file = settings.captionStyle.fontFileName { settings.captionStyle.fontFileName = fontMap[file]?.lastPathComponent }
                for i in settings.labels.indices {
                    if let file = settings.labels[i].style.fontFileName { settings.labels[i].style.fontFileName = fontMap[file]?.lastPathComponent }
                }
                item.desktopCollage = settings
            }
            for name in names {
                let mappedName = filenameMap[name]!
                item.mediaFidelity[mappedName] = integrityRecords[name]?.fidelity ?? item.mediaFidelity[mappedName] ?? .unknown
            }
            candidates.append(
                LayoutImportCandidate(
                    id: index,
                    item: item,
                    stagedURLs: stagedURLs,
                    mediaCount: names.count,
                    stagedFontURLs: (sourceItem.desktopCollage?.fontFileNames ?? []).compactMap { fontMap[$0] }
                )
            )
        }

        let importedIDsBySourceID = Dictionary(uniqueKeysWithValues: candidates.map {
            (manifest.photos[$0.id].id, $0.item.id)
        })
        let importedCollages = Set(candidates.filter { $0.item.desktopCollage != nil }.map(\.item.id))
        candidates = candidates.map { candidate in
            var item = candidate.item
            if let parent = item.collageParentID, let mapped = importedIDsBySourceID[parent],
               importedCollages.contains(mapped), item.desktopCollage == nil,
               mapped != item.id {
                item.collageParentID = mapped
            } else { item.collageParentID = nil }
            return LayoutImportCandidate(
                id: candidate.id,
                item: item,
                stagedURLs: candidate.stagedURLs,
                mediaCount: candidate.mediaCount,
                stagedFontURLs: candidate.stagedFontURLs
            )
        }

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        var transformedByID: [UUID: PhotoItem] = [:]
        for parent in candidates.map(\.item) where parent.desktopCollage != nil {
            let originalID = manifest.photos[candidates.first { $0.item.id == parent.id }!.id].id.uuidString
            let source = NSRectFromString(parent.frameString)
            let target = manifest.relativeFrames?[originalID]?.absoluteFrame(in: screen, aspectRatio: source.width / max(1, source.height))
                ?? NSRectFromString(Self.clampFrameString(parent.frameString, toFit: screen))
            let members = [parent] + candidates.map(\.item).filter { $0.collageParentID == parent.id }
            for item in adaptImportedCollage(members, to: target, in: screen) { transformedByID[item.id] = item }
        }
        candidates = candidates.map { candidate in
            LayoutImportCandidate(id: candidate.id, item: transformedByID[candidate.item.id] ?? candidate.item,
                                  stagedURLs: candidate.stagedURLs, mediaCount: candidate.mediaCount,
                                  stagedFontURLs: candidate.stagedFontURLs)
        }
        shouldKeepStaging = true
        return LayoutImportPreflight(
            manifest: manifest,
            candidates: candidates,
            skippedReasons: skippedReasons,
            stagingDirectory: stagingDirectory
        )
    }

    /// Commits only the preflight candidates selected by the user. A failed move or model write
    /// removes moved media and leaves the old layout untouched; Preferences are deliberately
    /// applied by the caller only after this method succeeds.
    @discardableResult
    func commitImport(
        _ preflight: LayoutImportPreflight,
        selectedIDs: Set<Int>,
        mode: LayoutImportMode
    ) throws -> Int {
        defer { preflight.cleanup() }
        let selected = preflight.candidates.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return 0 }

        let fileManager = FileManager.default
        var movedURLs: [URL] = []
        var registeredFonts: [URL] = []
        do {
            let fonts = Set(selected.flatMap(\.stagedFontURLs))
            if !fonts.isEmpty { try fileManager.createDirectory(at: CollageFontLibrary.directory(in: storageDir), withIntermediateDirectories: true) }
            for stagedFont in fonts {
                let destination = CollageFontLibrary.directory(in: storageDir).appendingPathComponent(stagedFont.lastPathComponent)
                guard !fileManager.fileExists(atPath: destination.path) else { throw LayoutArchiveError.couldNotStageMedia(stagedFont.lastPathComponent) }
                try fileManager.moveItem(at: stagedFont, to: destination)
                movedURLs.append(destination)
                guard let newlyRegistered = CollageFontLibrary.registerForImport(destination) else { throw LayoutArchiveError.missingStoredFont(stagedFont.lastPathComponent) }
                if newlyRegistered { registeredFonts.append(destination) }
            }
            for candidate in selected {
                for stagedURL in candidate.stagedURLs {
                    let destination = storageDir.appendingPathComponent(stagedURL.lastPathComponent)
                    guard !fileManager.fileExists(atPath: destination.path) else {
                        throw LayoutArchiveError.couldNotStageMedia(stagedURL.lastPathComponent)
                    }
                    try fileManager.moveItem(at: stagedURL, to: destination)
                    movedURLs.append(destination)
                }
            }

            let selectedItemIDs = Set(selected.map(\.item.id))
            let items = selected.map { candidate -> PhotoItem in
                var item = candidate.item
                if let parentID = item.collageParentID, !selectedItemIDs.contains(parentID) { item.collageParentID = nil }
                return item
            }
            guard commitImportedItems(items, replacing: mode == .replace) else {
                throw LayoutArchiveError.couldNotCommit
            }
            return items.count
        } catch {
            for font in registeredFonts { CollageFontLibrary.unregister(font) }
            for movedURL in movedURLs {
                try? fileManager.removeItem(at: movedURL)
            }
            throw error
        }
    }

    func adaptImportedCollage(_ originals: [PhotoItem], to target: CGRect, in screen: CGRect) -> [PhotoItem] {
        guard let parent = originals.first, let settings = parent.desktopCollage else { return originals }
        let source = NSRectFromString(parent.frameString)
        guard source.width > 0, source.height > 0, target.width > 0 else { return originals }
        let proposed = min(target.width / source.width, screen.height / source.height)
        let scale = min(8 / settings.compositionScale, max(0.1 / settings.compositionScale, proposed))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(x: min(screen.maxX - size.width, max(screen.minX, target.midX - size.width / 2)),
                             y: min(screen.maxY - size.height, max(screen.minY, target.midY - size.height / 2)))
        return transformedCollageItems(originals, scale: scale, corner: .topRight, anchor: source.origin,
                                       translation: CGPoint(x: origin.x - source.minX, y: origin.y - source.minY))
    }

    /// Applies preferences carried by a bundle. Separate from `importLayout` and never
    /// implicit, because these are system-wide settings the recipient did not choose.
    func applyImportedPreferences(_ preferences: ExportedPreferences) {
        if let enabled = preferences.globalHotKeyEnabled {
            HotKeyManager.shared.isEnabled = enabled
        }
        if let shortcut = preferences.globalHotKeyShortcut {
            HotKeyManager.shared.shortcut = shortcut
        }
        if let snap = preferences.snapToEdgesEnabled {
            SnapEngine.shared.isEnabled = snap
        }
        if let snapApps = preferences.snapToOtherAppsEnabled {
            SnapEngine.shared.includesOtherApps = snapApps
        }
        if let items = preferences.menuBarItems {
            for item in MenuBarCustomization.Item.allCases {
                if let visible = items[item.rawValue] {
                    MenuBarCustomization.shared.setVisible(item, visible)
                }
            }
        }
#if !ARRAS_APP_STORE
        if let frequency = preferences.updateCheckFrequency,
           let parsed = Updater.CheckFrequency(rawValue: frequency) {
            Updater.shared.checkFrequency = parsed
        }
        if let automatic = preferences.automaticUpdatesEnabled {
            Updater.shared.automaticUpdatesEnabled = automatic
        }
#endif
        if let value = preferences.excludeFromScreenCapture {
            setExcludeFromScreenCapture(value)
        }
        if let value = preferences.autoHideForConferencingApps {
            setAutoHideForConferencingApps(value)
        }
        if let value = preferences.hideWhenFullscreenActive {
            setHideWhenFullscreenActive(value)
        }
        if let hide = preferences.hideMenuBarIcon {
            UserDefaults.standard.set(hide, forKey: "hideMenuBarIcon")
        }
        // Left last: it can present system UI, and it is the one setting with an
        // effect outside the app.
        if let launch = preferences.launchAtLogin, launch != launchAtLogin {
            setLaunchAtLogin(launch)
        }
    }

    /// Reads a bundle's manifest without importing anything, so the UI can describe
    /// what is inside before the user commits.
    static func inspect(_ url: URL) throws -> LayoutManifest {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let reader = try SimpleZipReader(data: try Data(contentsOf: url))
        guard let manifestData = reader.entryData(named: "manifest.json") else {
            throw LayoutArchiveError.missingManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LayoutManifest.self, from: manifestData)
        guard manifest.formatVersion > 0,
              manifest.formatVersion <= LayoutManifest.currentFormatVersion else {
            throw LayoutArchiveError.unsupportedFormatVersion(manifest.formatVersion)
        }
        return manifest
    }

    // MARK: - Helpers

    private func referencedFilenames(of item: PhotoItem) -> [String] {
        var names: [String] = []
        if !item.filename.isEmpty { names.append(item.filename) }
        if let poster = item.media.posterFilename, !poster.isEmpty { names.append(poster) }
        if let paired = item.media.pairedVideoFilename, !paired.isEmpty { names.append(paired) }
        names.append(contentsOf: item.spaceImageFilenames)
        names.append(contentsOf: item.liveFolderEntries.map(\.managedFilename))
        names.append(contentsOf: item.photosLibraryAssets.flatMap(\.managedFilenames))
        return names
    }

    /// Rebuilds `source` with fresh filenames (and, via `PhotoItem(filename:)`, a fresh
    /// id) while preserving every other saved setting, including per-image position/size
    /// entries in `folderImageConfigs` — those are keyed by filename, so their keys need
    /// remapping too.
    private func remapped(_ source: PhotoItem, filenameMap: [String: String]) -> PhotoItem {
        let newPrimaryFilename = source.filename.isEmpty ? "" : (filenameMap[source.filename] ?? source.filename)
        var item = PhotoItem(filename: newPrimaryFilename, width: source.widgetWidth)

        item.frameString = source.frameString
        item.isLocked = source.isLocked
        item.isVisible = source.isVisible
        item.isFloating = source.isFloating
        item.depth = source.depth
        item.stackOrder = source.stackOrder
        item.opacity = source.opacity
        item.revealOnHover = source.revealOnHover
        item.customName = source.customName
        item.cornerRadius = source.cornerRadius
        item.shadowEnabled = source.shadowEnabled
        item.shadowBlur = source.shadowBlur
        item.shadowOpacity = source.shadowOpacity
        item.borderWidth = source.borderWidth
        item.borderColorHex = source.borderColorHex
        item.vignetteEnabled = source.vignetteEnabled

        item.desktopCollage = source.desktopCollage
        item.collageParentID = source.collageParentID

        // v2.1 appearance is portable user intent. Keep every field, including the optional
        // named preset, so an imported frame looks exactly like the one that was exported.
        item.matWidth = source.matWidth
        item.matColorHex = source.matColorHex
        item.shapeMask = source.shapeMask
        item.borderStyle = source.borderStyle
        item.borderGradientEnabled = source.borderGradientEnabled
        item.borderGradientColorHex = source.borderGradientColorHex
        item.tiltDegrees = source.tiltDegrees
        item.stylePreset = source.stylePreset

        item.spaceImageFilenames = source.spaceImageFilenames.map { filenameMap[$0] ?? $0 }
        item.folderSizeMode = source.folderSizeMode
        item.rotationInterval = source.rotationInterval
        item.folderImageIndex = source.folderImageIndex
        item.customRotationSeconds = source.customRotationSeconds
        item.playbackOrder = source.playbackOrder
        item.playbackSeed = source.playbackSeed
        item.playbackStep = source.playbackStep
        item.playbackHistory = source.playbackHistory.map { filenameMap[$0] ?? $0 }
        item.clickAction = source.clickAction

        item.mediaFidelity = source.mediaFidelity.reduce(into: [:]) { mapped, entry in
            mapped[filenameMap[entry.key] ?? entry.key] = entry.value
        }
        item.media = PhotoMedia(
            kind: source.media.kind,
            posterFilename: source.media.posterFilename.map { filenameMap[$0] ?? $0 },
            pairedVideoFilename: source.media.pairedVideoFilename.map { filenameMap[$0] ?? $0 },
            isMuted: source.media.isMuted
        )
        item.focalPoint = source.focalPoint
        item.reference = source.reference

        var remappedConfigs: [String: FolderImageConfig] = [:]
        for (key, config) in source.folderImageConfigs {
            remappedConfigs[filenameMap[key] ?? key] = config
        }
        item.folderImageConfigs = remappedConfigs

        // Imported live folders are snapshots until the recipient explicitly relinks them. Keep
        // the marker and source names for an eventual relink, but never restore the exporting
        // Mac's bookmark, path, or volume-specific resource identifiers.
        if let source = source.liveFolderSource {
            item.liveFolderSource = source.archiveSnapshot
        }
        item.liveFolderEntries = source.liveFolderEntries.map {
            LiveFolderEntry(
                // Resource identifiers are volume-specific fingerprints. Keep the managed
                // filename and source name for the snapshot, but discover fresh IDs only after
                // the recipient explicitly relinks this folder.
                sourceIdentifier: "",
                sourceName: $0.sourceName,
                managedFilename: filenameMap[$0.managedFilename] ?? $0.managedFilename,
                sourceByteCount: $0.sourceByteCount,
                sourceModificationDate: $0.sourceModificationDate
            )
        }

        if let source = source.photosLibrarySource {
            item.photosLibrarySource = source.archiveSnapshot
        }
        item.photosLibraryAssets = source.photosLibraryAssets.map { asset in
            PhotosLibraryAsset(
                localIdentifier: "",
                displayName: asset.displayName,
                managedFilename: filenameMap[asset.managedFilename] ?? asset.managedFilename,
                media: PhotoMedia(
                    kind: asset.media.kind,
                    posterFilename: asset.media.posterFilename.map { filenameMap[$0] ?? $0 },
                    pairedVideoFilename: asset.media.pairedVideoFilename.map { filenameMap[$0] ?? $0 },
                    isMuted: asset.media.isMuted
                ),
                status: .snapshot,
                sourceModificationDate: nil,
                sourceByteCount: asset.sourceByteCount,
                pairedVideoByteCount: asset.pairedVideoByteCount,
                lastError: nil
            )
        }

        // Portable per-photo preferences: these describe intent, not hardware, so they
        // travel.
        item.isSpaceBound = source.isSpaceBound
        item.scheduleEnabled = source.scheduleEnabled
        item.scheduleStartMinutes = source.scheduleStartMinutes
        item.scheduleEndMinutes = source.scheduleEndMinutes
        item.scheduleWeekdays = source.scheduleWeekdays

        // Display bindings deliberately do NOT travel.
        //
        // displayIdentifier and savedDisplayFrames are fingerprints of the *exporting*
        // Mac's monitors. On any other machine they can never match, so per-display
        // restore would silently do nothing — and isHiddenForDisplay could arrive true,
        // leaving a widget permanently invisible with no way to reason about why.
        // PhotoItem's initialiser already defaults these; stating it explicitly keeps a
        // later "copy every field" refactor from quietly reintroducing the bug.
        item.displayIdentifier = nil
        item.savedDisplayFrames = [:]
        item.isHiddenForDisplay = false

        return item
    }

    private func archiveSafeSnapshot(of source: PhotoItem) -> PhotoItem {
        var snapshot = source
        if let liveSource = source.liveFolderSource {
            snapshot.liveFolderSource = liveSource.archiveSnapshot
        }
        // Sanitize entries independently of the source metadata. A malformed or older store
        // can retain a live-folder entry after its source was cleared; archives must never leak
        // the source's machine/resource identifier in that case.
        snapshot.liveFolderEntries = source.liveFolderEntries.map {
            LiveFolderEntry(
                sourceIdentifier: "",
                sourceName: $0.sourceName,
                managedFilename: $0.managedFilename,
                sourceByteCount: $0.sourceByteCount,
                sourceModificationDate: $0.sourceModificationDate
            )
        }
        if let photosSource = source.photosLibrarySource {
            snapshot.photosLibrarySource = photosSource.archiveSnapshot
        }
        // Treat the asset list as sensitive on its own as well. A malformed or older store can
        // retain entries after its source metadata was cleared; archive export must never leak
        // PhotoKit local identifiers in that case.
        snapshot.photosLibraryAssets = source.photosLibraryAssets.map { $0.archiveSnapshot }
        return snapshot
    }

    /// Expresses a saved frame relative to whichever screen currently contains it.
    private static func relativeFrame(for frameString: String) -> RelativeFrame? {
        guard !frameString.isEmpty else { return nil }
        let rect = NSRectFromString(frameString)
        guard rect.width > 0, rect.height > 0 else { return nil }

        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return nil }
        return RelativeFrame(frame: rect, in: visibleFrame)
    }

    /// If `frameString` decodes to a rect that doesn't overlap any connected screen
    /// (e.g. it was saved on a Mac with a different monitor arrangement), recenters it
    /// on `visibleFrame` instead of leaving it permanently off-screen and unreachable.
    private static func clampFrameString(_ frameString: String, toFit visibleFrame: NSRect) -> String {
        guard !frameString.isEmpty else { return frameString }
        var rect = NSRectFromString(frameString)
        guard rect.width > 0, rect.height > 0 else { return frameString }

        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(rect) }
        if !onAnyScreen {
            rect.origin = NSPoint(x: visibleFrame.midX - rect.width / 2, y: visibleFrame.midY - rect.height / 2)
        }
        return NSStringFromRect(rect)
    }
}

// MARK: - Minimal ZIP writer (STORE only)

struct SimpleZipWriter {
    private struct Entry {
        let name: String
        let data: Data
        let crc32: UInt32
    }

    private var entries: [Entry] = []

    mutating func addEntry(name: String, data: Data) {
        entries.append(Entry(name: name, data: data, crc32: ZipCRC32.checksum(data)))
    }

    func write(to url: URL) throws {
        var body = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []

        for entry in entries {
            localHeaderOffsets.append(UInt32(body.count))
            let nameBytes = Array(entry.name.utf8)

            body.appendUInt32LE(0x0403_4b50)
            body.appendUInt16LE(20)        // version needed to extract
            body.appendUInt16LE(0x0800)    // language encoding flag: filename is UTF-8
            body.appendUInt16LE(0)         // compression method: stored
            body.appendUInt16LE(0)         // mod time (unused)
            body.appendUInt16LE(0x21)      // mod date: Jan 1 1980, a fixed placeholder
            body.appendUInt32LE(entry.crc32)
            body.appendUInt32LE(UInt32(entry.data.count))
            body.appendUInt32LE(UInt32(entry.data.count))
            body.appendUInt16LE(UInt16(nameBytes.count))
            body.appendUInt16LE(0)         // extra field length
            body.append(contentsOf: nameBytes)
            body.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)

            centralDirectory.appendUInt32LE(0x0201_4b50)
            centralDirectory.appendUInt16LE(20)     // version made by
            centralDirectory.appendUInt16LE(20)     // version needed to extract
            centralDirectory.appendUInt16LE(0x0800)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0x21)
            centralDirectory.appendUInt32LE(entry.crc32)
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt16LE(UInt16(nameBytes.count))
            centralDirectory.appendUInt16LE(0)      // extra field length
            centralDirectory.appendUInt16LE(0)      // file comment length
            centralDirectory.appendUInt16LE(0)      // disk number start
            centralDirectory.appendUInt16LE(0)      // internal file attributes
            centralDirectory.appendUInt32LE(0)      // external file attributes
            centralDirectory.appendUInt32LE(localHeaderOffsets[index])
            centralDirectory.append(contentsOf: nameBytes)
        }

        var end = Data()
        end.appendUInt32LE(0x0605_4b50)
        end.appendUInt16LE(0)   // this disk
        end.appendUInt16LE(0)   // disk with central directory start
        end.appendUInt16LE(UInt16(entries.count))
        end.appendUInt16LE(UInt16(entries.count))
        end.appendUInt32LE(UInt32(centralDirectory.count))
        end.appendUInt32LE(UInt32(body.count))
        end.appendUInt16LE(0)   // comment length

        var full = Data(capacity: body.count + centralDirectory.count + end.count)
        full.append(body)
        full.append(centralDirectory)
        full.append(end)
        try full.write(to: url, options: .atomic)
    }
}

// MARK: - Minimal ZIP reader (STORE only)

struct SimpleZipReader {
    private struct IndexedEntry {
        let localHeaderOffset: Int
        let compressedSize: Int
        let method: UInt16
    }

    private let bytes: [UInt8]
    private var index: [String: IndexedEntry] = [:]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard let eocdOffset = Self.findEndOfCentralDirectory(in: bytes) else {
            throw LayoutArchiveError.notAZipFile
        }

        let centralDirCount = Int(bytes.readUInt16LE(at: eocdOffset + 10))
        var offset = Int(bytes.readUInt32LE(at: eocdOffset + 16))

        for _ in 0..<centralDirCount {
            guard offset + 46 <= bytes.count, bytes.readUInt32LE(at: offset) == 0x0201_4b50 else { break }

            let method = bytes.readUInt16LE(at: offset + 10)
            let compressedSize = Int(bytes.readUInt32LE(at: offset + 20))
            let nameLength = Int(bytes.readUInt16LE(at: offset + 28))
            let extraLength = Int(bytes.readUInt16LE(at: offset + 30))
            let commentLength = Int(bytes.readUInt16LE(at: offset + 32))
            let localHeaderOffset = Int(bytes.readUInt32LE(at: offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            index[name] = IndexedEntry(localHeaderOffset: localHeaderOffset, compressedSize: compressedSize, method: method)
            offset = nameStart + nameLength + extraLength + commentLength
        }
    }

    /// Only the STORE (uncompressed) method is supported, since that's all this app's
    /// own writer ever produces. A bundle re-compressed by an outside tool would fail
    /// this check and the caller reports it as an invalid bundle.
    func entryData(named name: String) -> Data? {
        guard let entry = index[name], entry.method == 0 else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, bytes.readUInt32LE(at: header) == 0x0403_4b50 else { return nil }

        let nameLength = Int(bytes.readUInt16LE(at: header + 26))
        let extraLength = Int(bytes.readUInt16LE(at: header + 28))
        let dataStart = header + 30 + nameLength + extraLength
        guard dataStart <= bytes.count,
              entry.compressedSize <= bytes.count - dataStart else { return nil }
        let dataEnd = dataStart + entry.compressedSize

        return Data(bytes[dataStart..<dataEnd])
    }

    private static func findEndOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let searchFloor = max(0, bytes.count - 22 - 65536)
        var i = bytes.count - 22
        while i >= searchFloor {
            if bytes.readUInt32LE(at: i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }
}

// MARK: - Byte helpers

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

private extension Array where Element == UInt8 {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

// MARK: - CRC32

private enum ZipCRC32 {
    private static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[tableIndex] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
