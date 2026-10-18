import AppKit
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Decoded animation ready for playback: one CGImage per frame plus its
/// display duration, and how many times the whole sequence should repeat.
struct AnimatedImageFrames {
    let images: [CGImage]
    let delays: [TimeInterval]     // one per image, already clamped
    let loopCount: Int             // GIF convention: 0 == loop forever

    var totalDuration: TimeInterval { delays.reduce(0, +) }

    /// A discrete (non-interpolated) keyframe animation that steps
    /// `layer.contents` through each frame. This runs on the render server
    /// once installed, avoiding an app-side timer that wakes for every frame.
    /// Decoded frames and compositing still consume memory and system resources.
    func makeContentsAnimation() -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.calculationMode = .discrete
        anim.values = images
        anim.duration = totalDuration
        anim.repeatCount = loopCount == 0 ? .greatestFiniteMagnitude : Float(loopCount)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards

        let total = totalDuration
        var keyTimes: [NSNumber] = []
        var cumulative: TimeInterval = 0
        for delay in delays {
            keyTimes.append(NSNumber(value: total > 0 ? cumulative / total : 0))
            cumulative += delay
        }
        anim.keyTimes = keyTimes
        return anim
    }
}

/// What a desktop window should render: a plain still, or a decoded
/// animation. Bundling these behind one type keeps DesktopPhotoWindow's API
/// to a single entry point instead of an "if animated" branch at every call
/// site in ImageManager.
enum PhotoContent {
    case still(NSImage)
    case animated(AnimatedImageFrames, representative: NSImage)
    case video(VideoPlaybackContent)
    case livePhoto(still: NSImage, video: VideoPlaybackContent)

    var size: NSSize {
        switch self {
        case .still(let image): return image.size
        case .animated(_, let representative): return representative.size
        case .video(let video): return video.size
        case .livePhoto(let still, _): return still.size
        }
    }

    var representativeImage: NSImage {
        switch self {
        case .still(let image): return image
        case .animated(_, let representative): return representative
        case .video(let video): return video.editedPoster ?? video.poster
        case .livePhoto(let still, _): return still
        }
    }

    /// The paired movie, if this content is a standalone video or exported Live Photo.
    var videoContent: VideoPlaybackContent? {
        switch self {
        case .video(let video), .livePhoto(_, let video): return video
        case .still, .animated: return nil
        }
    }

    var mediaModel: PhotoMedia {
        switch self {
        case .still: return PhotoMedia(kind: .still)
        case .animated: return PhotoMedia(kind: .animatedImage)
        case .video: return PhotoMedia(kind: .video)
        case .livePhoto: return PhotoMedia(kind: .livePhoto)
        }
    }

    /// Loads whichever is appropriate for `url`, based on its extension.
    ///
    /// Every photo saved before this feature existed is a plain `.jpg`, so
    /// this still decodes old data without a PhotoItem schema migration.
    /// ImageIO identifies multi-frame GIF/APNG/WebP payloads and is retained
    /// as a fallback for BMP/WebP files when AppKit does not vend an NSImage
    /// representation directly.
    static func load(from url: URL) -> PhotoContent? {
        load(from: url, posterURL: nil, pairedVideoURL: nil)
    }

    /// Loads a managed primary file and optional generated poster/paired movie.  The optional
    /// arguments are deliberately URL-based so the model can remain Codable and archive-safe.
    static func load(from url: URL, posterURL: URL?, pairedVideoURL: URL?) -> PhotoContent? {
        if VideoMediaSupport.isSupportedVideoURL(url) {
            guard let video = makeVideoContent(
                url: url,
                posterURL: posterURL,
                pairedVideoURL: pairedVideoURL
            ) else { return nil }
            return .video(video)
        }

        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        if let frames = AnimatedImageIO.decodeForPlayback(data: data),
           let representative = NSImage(contentsOf: url) ?? image(at: source, index: 0) {
            return .animated(frames, representative: representative)
        }
        guard let image = NSImage(contentsOf: url) ?? image(at: source, index: 0) else { return nil }
        if let pairedVideoURL {
            guard let video = makeVideoContent(url: pairedVideoURL, posterURL: nil, pairedVideoURL: nil) else {
                return nil
            }
            return .livePhoto(still: image, video: video)
        }
        return .still(image)
    }

    private static func makeVideoContent(
        url: URL,
        posterURL: URL?,
        pairedVideoURL: URL?
    ) -> VideoPlaybackContent? {
        guard VideoMediaSupport.isPlayableVideo(at: url) else { return nil }
        let poster = posterURL.flatMap { NSImage(contentsOf: $0) }
            ?? VideoMediaSupport.posterImage(for: url)
        guard let poster, poster.size.width > 0, poster.size.height > 0 else { return nil }
        return VideoPlaybackContent(url: url, poster: poster, pairedVideoURL: pairedVideoURL)
    }

    private static func image(at source: CGImageSource, index: Int) -> NSImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Recovers and re-encodes animated image data, and decodes it back for
/// playback. See the comments below for why extraction and playback each
/// need their own approach.
enum AnimatedImageIO {

    // MARK: - Import-side extraction (from an in-memory NSImage)

    /// Attempts to recover every frame + per-frame delay from an `NSImage`.
    ///
    /// Clipboard/AppKit imports may provide only an NSImage, so recover frame timing
    /// from its bitmap representation. File imports preserve original source bytes instead.
    /// Animated WebP without AppKit timing metadata falls back to a still on this path.
    static func extractFrames(from image: NSImage) -> AnimatedImageFrames? {
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
              let rawCount = bitmap.value(forProperty: .frameCount) as? Int,
              rawCount > 1, rawCount <= 10_000 else {
            return nil
        }

        let originalFrame = bitmap.value(forProperty: .currentFrame) as? Int ?? 0
        defer { bitmap.setProperty(.currentFrame, withValue: originalFrame) }
        let edge = playbackEdge(frameCount: rawCount)
        var retainedBytes = 0
        var images: [CGImage] = []
        var delays: [TimeInterval] = []
        images.reserveCapacity(rawCount)
        delays.reserveCapacity(rawCount)

        for i in 0..<rawCount {
            bitmap.setProperty(.currentFrame, withValue: i)
            guard let source = bitmap.cgImage else { return nil }
            let ratio = min(1, CGFloat(edge) / CGFloat(max(source.width, source.height)))
            let width = max(1, Int(CGFloat(source.width) * ratio))
            let height = max(1, Int(CGFloat(source.height) * ratio))
            // Copy each frame: AppKit's current-frame cursor can reuse its backing pixels.
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let cg = context.makeImage() else { return nil }
            let bytes = cg.bytesPerRow * cg.height
            guard bytes <= playbackByteBudget - retainedBytes else { return nil }
            retainedBytes += bytes
            let rawDelay = (bitmap.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1
            images.append(cg)
            delays.append(clampDelay(rawDelay))
        }
        guard images.count > 1 else { return nil }
        let loopCount = (bitmap.value(forProperty: .loopCount) as? Int) ?? 0
        return AnimatedImageFrames(images: images, delays: delays, loopCount: loopCount)
    }

    /// Browsers clamp absurdly small GIF delays (some encoders emit 0,
    /// historically meaning "as fast as possible") up to a sane minimum so
    /// playback doesn't strobe. We match that convention.
    static func clampDelay(_ delay: Double) -> TimeInterval {
        delay < 0.02 ? 0.1 : delay
    }

    // MARK: - Storage (re-encode recovered frames as a single GIF file)

    /// Re-encodes recovered frames as a standalone animated GIF on disk.
    ///
    /// Used only when an AppKit import does not provide original bytes. Large frames
    /// may already be downsampled and GIF encoding quantizes colors. File imports
    /// retain their original container instead.
    @discardableResult
    static func writeGIF(_ frames: AnimatedImageFrames, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.images.count, nil
        ) else { return false }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: frames.loopCount]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        for (image, delay) in zip(frames.images, frames.delays) {
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ]
            CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Playback-side decode (from a file already on disk)

    /// Reads frames + delays back out of a file on disk via `CGImageSource`,
    /// honoring `kCGImagePropertyGIFDelayTime` /
    /// `kCGImagePropertyGIFUnclampedDelayTime` (preferring the unclamped
    /// value, same as browsers). This is intentionally independent of the
    /// NSImage-based extractor above: it's the standard, documented way to
    /// read GIF timing metadata, and it avoids depending on the mutable
    /// "current frame" cursor semantics of NSBitmapImageRep for what is
    /// effectively a fresh decode every time a Space rotates or the app
    /// relaunches. It also generalizes to APNG/WebP dictionaries for free,
    /// in case a future import path ever hands us those bytes directly.
    static func decodeForPlayback(url: URL) -> AnimatedImageFrames? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeForPlayback(data: data)
    }

    private static let playbackByteBudget = 64 * 1024 * 1024

    private static func playbackEdge(frameCount: Int) -> Int {
        // Allow for decoder row alignment as well as the actual byte check below.
        min(1536, max(1, Int(sqrt(Double(playbackByteBudget / frameCount / 4))) - 32))
    }

    static func decodeForPlayback(data: Data) -> AnimatedImageFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 10_000 else { return nil }
        // Preserve timing and every frame while bounding the decoded playback footprint.
        // Source bytes remain intact in storage; this is only a display-size decode.
        let byteBudget = playbackByteBudget
        let edge = playbackEdge(frameCount: count)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        var decodedBytes = 0
        var images: [CGImage] = []
        var delays: [TimeInterval] = []
        images.reserveCapacity(count)
        delays.reserveCapacity(count)

        for i in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { return nil }
            let bytes = cg.bytesPerRow * cg.height
            guard bytes <= byteBudget - decodedBytes else { return nil }
            decodedBytes += bytes
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            images.append(cg)
            delays.append(clampDelay(frameDelay(from: props) ?? 0.1))
        }
        guard images.count > 1 else { return nil }

        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        return AnimatedImageFrames(images: images, delays: delays, loopCount: loopCount(from: fileProps))
    }

    private static func frameDelay(from props: [CFString: Any]?) -> Double? {
        guard let props else { return nil }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            return (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            return (webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? (webp[kCGImagePropertyWebPDelayTime] as? Double)
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            return (png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                ?? (png[kCGImagePropertyAPNGDelayTime] as? Double)
        }
        return nil
    }

    private static func loopCount(from props: [CFString: Any]?) -> Int {
        guard let props else { return 0 }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            return (gif[kCGImagePropertyGIFLoopCount] as? Int) ?? 0
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            return (webp[kCGImagePropertyWebPLoopCount] as? Int) ?? 0
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            return (png[kCGImagePropertyAPNGLoopCount] as? Int) ?? 0
        }
        return 0
    }
}
