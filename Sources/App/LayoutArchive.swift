import Foundation
import AppKit

// MARK: - Layout Export/Import ("Later" roadmap item)
//
// A `.tableau` bundle is a single file the user can AirDrop or email. We build it as a
// plain ZIP (manifest.json + images/*.jpg) written with our own minimal, STORE-only
// writer/reader below, rather than shelling out to /usr/bin/ditto via Process or relying
// on FileWrapper's directory-package serialization. Both of those alternatives write a
// real directory to disk (a "package" is only ever a Finder-UI illusion driven by a
// registered UTI we don't have), which defeats "single file you can email" and adds
// sandbox/Process-entitlement uncertainty for no benefit. A hand-rolled STORE-format ZIP
// is a genuine single file, needs no compression library (the JPEGs inside are already
// compressed, so DEFLATE would buy nothing), and is still openable by Archive Utility or
// any standard unzip tool if a user gets curious.

// MARK: - Manifest

/// Top-level contents of a `.tableau` bundle's manifest.json.
///
/// `formatVersion` exists so a future change to the archive layout (not just to
/// `PhotoItem`, which already tolerates missing keys) can detect and adapt to older
/// bundles instead of failing to decode them silently.
struct LayoutManifest: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let appVersion: String
    let exportedAt: Date
    let photos: [PhotoItem]
}

enum LayoutArchiveError: LocalizedError {
    case notAZipFile
    case missingManifest
    case emptyLayout

    var errorDescription: String? {
        switch self {
        case .notAZipFile: return "That file isn't a valid .tableau bundle."
        case .missingManifest: return "That bundle is missing its layout data."
        case .emptyLayout: return "There are no photos to export."
        }
    }
}

// MARK: - PhotoManager Export/Import

extension PhotoManager {
    enum LayoutImportMode {
        case replace
        case merge
    }

    /// Writes every current photo (single images and Spaces) plus their positions and
    /// aesthetic settings into a `.tableau` bundle at `url`. `url` must come from an
    /// `NSSavePanel` — the sandbox only grants write access to user-chosen paths.
    func exportLayout(to url: URL) throws {
        guard !photos.isEmpty else { throw LayoutArchiveError.emptyLayout }

        var writer = SimpleZipWriter()
        var writtenImages = Set<String>()

        for item in photos {
            for name in referencedFilenames(of: item) where !writtenImages.contains(name) {
                writtenImages.insert(name)
                let source = storageDir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: source) else { continue }
                writer.addEntry(name: "images/\(name)", data: data)
            }
        }

        let manifest = LayoutManifest(
            formatVersion: LayoutManifest.currentFormatVersion,
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            exportedAt: Date(),
            photos: photos
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        writer.addEntry(name: "manifest.json", data: try encoder.encode(manifest))

        try writer.write(to: url)
    }

    /// Imports a `.tableau` bundle. In `.replace` mode the current layout is removed
    /// first (windows closed, files deleted) — callers must confirm this with the user,
    /// since it can't be undone. In `.merge` mode imported photos are simply appended.
    ///
    /// Every imported item gets a fresh id and fresh image filenames (via
    /// `PhotoItem(filename:)`) so importing the same bundle twice — or into a Mac that
    /// already has some of these photos — never collides. Entries whose image data is
    /// missing from the bundle are skipped rather than creating an empty widget, and any
    /// saved frame that would land completely off every connected screen is recentered
    /// onto the main screen instead of appearing there.
    @discardableResult
    func importLayout(from url: URL, mode: LayoutImportMode) throws -> Int {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let reader = try SimpleZipReader(data: data)
        guard let manifestData = reader.entryData(named: "manifest.json") else {
            throw LayoutArchiveError.missingManifest
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(LayoutManifest.self, from: manifestData)

        if mode == .replace {
            removeAllPhotos()
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var importedCount = 0

        for sourceItem in manifest.photos {
            let names = referencedFilenames(of: sourceItem)
            guard !names.isEmpty else { continue }

            var payloads: [String: Data] = [:]
            var allPresent = true
            for name in names {
                guard let payload = reader.entryData(named: "images/\(name)") else {
                    allPresent = false
                    break
                }
                payloads[name] = payload
            }
            guard allPresent else { continue }   // skip rather than create an empty widget

            var filenameMap: [String: String] = [:]
            for name in names {
                filenameMap[name] = UUID().uuidString + ".jpg"
            }
            for (oldName, newName) in filenameMap {
                guard let payload = payloads[oldName] else { continue }
                try? payload.write(to: storageDir.appendingPathComponent(newName))
            }

            var newItem = remapped(sourceItem, filenameMap: filenameMap)
            newItem.frameString = Self.clampFrameString(newItem.frameString, toFit: visibleFrame)
            for (key, config) in newItem.folderImageConfigs {
                newItem.folderImageConfigs[key] = FolderImageConfig(
                    frameString: Self.clampFrameString(config.frameString, toFit: visibleFrame),
                    widgetWidth: config.widgetWidth
                )
            }

            addImportedItem(newItem)
            importedCount += 1
        }

        return importedCount
    }

    // MARK: - Helpers

    private func referencedFilenames(of item: PhotoItem) -> [String] {
        var names: [String] = []
        if !item.filename.isEmpty { names.append(item.filename) }
        names.append(contentsOf: item.spaceImageFilenames)
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
        item.opacity = source.opacity
        item.customName = source.customName
        item.cornerRadius = source.cornerRadius
        item.shadowEnabled = source.shadowEnabled
        item.shadowBlur = source.shadowBlur
        item.shadowOpacity = source.shadowOpacity
        item.borderWidth = source.borderWidth
        item.borderColorHex = source.borderColorHex
        item.vignetteEnabled = source.vignetteEnabled
        item.spaceImageFilenames = source.spaceImageFilenames.map { filenameMap[$0] ?? $0 }
        item.folderSizeMode = source.folderSizeMode
        item.rotationInterval = source.rotationInterval
        item.folderImageIndex = source.folderImageIndex
        item.customRotationSeconds = source.customRotationSeconds

        var remappedConfigs: [String: FolderImageConfig] = [:]
        for (key, config) in source.folderImageConfigs {
            remappedConfigs[filenameMap[key] ?? key] = config
        }
        item.folderImageConfigs = remappedConfigs

        return item
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

private struct SimpleZipWriter {
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

private struct SimpleZipReader {
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
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= bytes.count else { return nil }

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
