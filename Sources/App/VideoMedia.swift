import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Runtime-only value passed from the media loader to the window layer.  It intentionally holds
/// no AVPlayer: a player belongs to exactly one widget window and is created/released with that
/// window's lifecycle.
struct VideoPlaybackContent {
    let url: URL
    let poster: NSImage
    let pairedVideoURL: URL?
    var referenceSettings = PhotoReferenceSettings()
    var editedPoster: NSImage?

    var size: NSSize { (editedPoster ?? poster).size }
}

enum VideoPlaybackStatus: String, Equatable, Sendable {
    case notVideo
    case playing
    case paused

    var displayName: String {
        switch self {
        case .notVideo: return "Not a video"
        case .playing: return "Playing"
        case .paused: return "Paused"
        }
    }
}

/// Public AVFoundation-only helpers used by the importer and the renderer.  No Photos private
/// APIs are involved: a Live Photo is represented as its exported still plus its paired movie.
enum VideoMediaSupport {
    /// Keep local managed copies bounded.  This is deliberately generous enough for a short
    /// desktop clip while preventing an accidental multi-gigabyte camera recording from being
    /// copied into Application Support without an honest failure.
    static let maxSourceBytes: Int64 = 512 * 1024 * 1024

    static func isSupportedVideoURL(_ url: URL) -> Bool {
        PhotoImportPolicy.isVideo(url)
    }

    static func isPlayableVideo(at url: URL) -> Bool {
        let asset = AVAsset(url: url)
        guard asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty else { return false }
        return asset.duration.isNumeric && asset.duration.seconds >= 0
    }

    /// Generates a poster using the preferred track transform, so portrait movies do not arrive
    /// rotated sideways.  The poster is always a concrete bitmap rather than an NSImage drawing
    /// handler; it can therefore be cached, archived, and shown while playback is paused.
    static func posterImage(for url: URL) -> NSImage? {
        let asset = AVAsset(url: url)
        guard asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = asset.duration
        let seconds: Double
        if duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 {
            seconds = min(0.1, max(0, duration.seconds - 0.001))
        } else {
            seconds = 0
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func jpegData(for image: NSImage, quality: CGFloat = 0.88) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
