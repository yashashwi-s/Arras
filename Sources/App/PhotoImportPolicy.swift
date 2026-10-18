import Foundation
import UniformTypeIdentifiers

/// The single format gate shared by Finder imports, drops, Spaces, and live folders.
enum PhotoImportPolicy {
    static let imageTypes: [UTType] = [.image, .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
    /// The importer intentionally accepts only movie containers that AVFoundation can validate
    /// and that Finder can identify publicly.  A Live Photo's paired resource is supplied by the
    /// PhotoKit integration as bytes and enters through `PhotoIngest.prepareLivePhoto`.
    static let videoTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie]
    static let supportedTypes: [UTType] = imageTypes + videoTypes

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return videoTypes.contains { type.conforms(to: $0) }
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return imageTypes.contains { type.conforms(to: $0) }
    }

    static func isImportable(_ url: URL) -> Bool {
        isImage(url) || isVideo(url)
    }
}
