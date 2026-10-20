import Foundation
import CryptoKit

/// What Arras knows about the bytes behind a widget.
///
/// `sourceBytes` is only assigned when the byte-based importer retained the source payload
/// without downsampling or re-encoding. `transformed` covers an intentional resize/re-encode
/// (including NSImage-only pasteboard imports), while `unknown` is the safe value for legacy
/// layouts and callers that supplied an already-stored file without provenance.
enum ArchiveMediaFidelity: String, Codable, Equatable, Sendable {
    case sourceBytes = "source-bytes"
    case transformed
    case unknown

    var displayName: String {
        switch self {
        case .sourceBytes: return "source bytes retained"
        case .transformed: return "transformed before storage"
        case .unknown: return "source provenance unavailable"
        }
    }

    func merged(with other: ArchiveMediaFidelity) -> ArchiveMediaFidelity {
        if self == .unknown || other == .unknown { return .unknown }
        if self == .transformed || other == .transformed { return .transformed }
        return .sourceBytes
    }
}

enum LayoutArchiveScope: String, Codable, Equatable, Sendable {
    case wholeLayout = "whole-layout"
    case widget

    var displayName: String {
        switch self {
        case .wholeLayout: return "whole layout"
        case .widget: return "widget"
        }
    }
}

/// Per-file integrity and provenance information carried by new archives.
///
/// The hash describes the bytes in `images/`, not an unavailable camera/original file. That
/// distinction is deliberate: an archival export can prove what it preserved without claiming
/// to have recovered source originals that Arras never retained.
struct ArchiveMediaRecord: Codable, Equatable, Sendable {
    let filename: String
    let byteCount: Int
    let sha256: String
    let fidelity: ArchiveMediaFidelity

    init(filename: String, data: Data, fidelity: ArchiveMediaFidelity) {
        self.filename = filename
        self.byteCount = data.count
        self.sha256 = ArchiveMediaRecord.sha256(data)
        self.fidelity = fidelity
    }

    /// Hash managed files in bounded chunks; exports never need a payload-sized Data buffer.
    init(filename: String, url: URL, fidelity: ArchiveMediaFidelity) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, UInt64(size) <= ArchiveResourceLimits.entryBytes else {
            throw ArchiveIOError.tooLarge
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= size - count else { throw ArchiveIOError.sourceChanged }
            count += chunk.count
            hash.update(data: chunk)
        }
        guard count == size else { throw ArchiveIOError.sourceChanged }
        self.filename = filename
        byteCount = count
        sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        self.fidelity = fidelity
    }

    func matches(_ data: Data) -> Bool {
        data.count == byteCount && Self.sha256(data) == sha256
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ArchiveExportMetadata: Codable, Equatable, Sendable {
    let scope: LayoutArchiveScope
    let archivalQuality: Bool
    let media: [ArchiveMediaRecord]
    let statement: String

    var sourceStatus: ArchiveSourceStatus {
        ArchiveSourceStatus(media: media)
    }

    static func statement(
        archivalQuality: Bool,
        sourceStatus: ArchiveSourceStatus
    ) -> String {
        let prefix = archivalQuality
            ? "Archival-quality mode copied the exact bytes currently stored by Arras."
            : "This archive copied the exact bytes currently stored by Arras."
        switch sourceStatus {
        case .allSourceBytes:
            return prefix + " Arras retained the source payload for every exported media file; this is not a claim about any separate camera original."
        case .someTransformed:
            return prefix + " Some media was transformed before storage (for example, downsampled or re-encoded), so source originals are not included."
        case .provenanceUnavailable:
            return prefix + " Source provenance is unavailable for some media, so this archive makes no original-quality claim."
        }
    }
}

enum ArchiveSourceStatus: String, Codable, Equatable, Sendable {
    case allSourceBytes = "all-source-bytes"
    case someTransformed = "some-transformed"
    case provenanceUnavailable = "provenance-unavailable"

    init(media: [ArchiveMediaRecord]) {
        guard !media.isEmpty else {
            self = .provenanceUnavailable
            return
        }
        if media.contains(where: { $0.fidelity == .unknown }) {
            self = .provenanceUnavailable
        } else if media.contains(where: { $0.fidelity == .transformed }) {
            self = .someTransformed
        } else {
            self = .allSourceBytes
        }
    }

    var displayName: String {
        switch self {
        case .allSourceBytes: return "source bytes retained"
        case .someTransformed: return "some media transformed before storage"
        case .provenanceUnavailable: return "source provenance unavailable"
        }
    }
}

struct ArchiveExportReport: Equatable, Sendable {
    let scope: LayoutArchiveScope
    let widgetCount: Int
    let mediaCount: Int
    let archivalQuality: Bool
    let sourceStatus: ArchiveSourceStatus
    let statement: String

    var summary: String {
        let widgetWord = widgetCount == 1 ? "widget" : "widgets"
        let mediaWord = mediaCount == 1 ? "media file" : "media files"
        return "Exported \(widgetCount) \(widgetWord) with \(mediaCount) \(mediaWord).\n\n\(statement)"
    }
}
