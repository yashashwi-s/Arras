import Foundation

/// The durable kind of media behind a widget.
///
/// This is intentionally a small value model rather than a Photos/AVFoundation object.  A
/// saved layout can therefore be decoded without a live player, and old layouts that do not
/// carry this field continue to mean an ordinary still (the renderer still detects legacy GIFs
/// from their bytes).
enum PhotoMediaKind: String, Codable, Equatable, Sendable {
    case still
    case animatedImage = "animated-image"
    case video
    case livePhoto = "live-photo"

    var displayName: String {
        switch self {
        case .still: return "Still image"
        case .animatedImage: return "Animated image"
        case .video: return "Video"
        case .livePhoto: return "Live Photo"
        }
    }

    var isVideoKind: Bool {
        self == .video || self == .livePhoto
    }
}

/// Portable metadata for a media asset.  `filename` remains the primary `PhotoItem` field for
/// backwards compatibility: it is the still for a Live Photo and the movie for a standalone
/// video.  Related files are referenced by generated, managed filenames and are included in
/// archives through the normal filename-reference path.
struct PhotoMedia: Codable, Equatable, Sendable {
    var kind: PhotoMediaKind
    var posterFilename: String?
    var pairedVideoFilename: String?
    /// Video playback is deliberately muted by default.  This field is retained as a setting
    /// so a future UI can expose a policy without changing the media/archive schema again; the
    /// current renderer never emits audio.
    var isMuted: Bool

    init(
        kind: PhotoMediaKind = .still,
        posterFilename: String? = nil,
        pairedVideoFilename: String? = nil,
        isMuted: Bool = true
    ) {
        self.kind = kind
        self.posterFilename = posterFilename
        self.pairedVideoFilename = pairedVideoFilename
        self.isMuted = isMuted
    }

    static let still = PhotoMedia()

    private enum CodingKeys: String, CodingKey {
        case kind, posterFilename, pairedVideoFilename, isMuted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(PhotoMediaKind.init(rawValue:)) ?? .still
        posterFilename = try container.decodeIfPresent(String.self, forKey: .posterFilename)
        pairedVideoFilename = try container.decodeIfPresent(String.self, forKey: .pairedVideoFilename)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? true
    }
}
