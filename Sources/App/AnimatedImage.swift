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
    /// once installed, so steady-state playback costs no app-side CPU --
    /// matching the app's near-zero-CPU / ~20MB idle footprint goal, unlike
    /// a Timer/CADisplayLink that would wake the app process every frame.
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

    var size: NSSize {
        switch self {
        case .still(let image): return image.size
        case .animated(_, let representative): return representative.size
        }
    }

    /// Loads whichever is appropriate for `url`, based on its extension.
    ///
    /// Every photo saved before this feature existed is a plain `.jpg`, so
    /// this always takes the `.still` branch for old data -- no PhotoItem
    /// schema migration needed for backward compatibility. Animated content
    /// is always stored as `.gif` (see AnimatedImage.writeGIF), so the
    /// extension alone is a reliable, cheap signal without opening the file
    /// twice.
    static func load(from url: URL) -> PhotoContent? {
        if url.pathExtension.lowercased() == "gif",
           let frames = AnimatedImageIO.decodeForPlayback(url: url),
           let representative = NSImage(contentsOf: url) {
            return .animated(frames, representative: representative)
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        return .still(image)
    }
}

/// Recovers and re-encodes animated image data, and decodes it back for
/// playback. See the comments below for why extraction and playback each
/// need their own approach.
enum AnimatedImageIO {

    // MARK: - Import-side extraction (from an in-memory NSImage)

    /// Attempts to recover every frame + per-frame delay from an `NSImage`.
    ///
    /// Design note: the import call sites (NSOpenPanel, PhotosPicker) live
    /// in ContentView.swift/AppDelegate.swift, which other agents are
    /// editing in parallel, and today they only ever hand ImageManager an
    /// `NSImage` -- never the source `URL`/`Data`. Rather than thread a new
    /// parameter through those files, we recover the animation from the
    /// `NSImage` itself: the first `NSBitmapImageRep` in
    /// `image.representations` exposes `.frameCount`, `.currentFrame`,
    /// `.currentFrameDuration` and `.loopCount` -- the same private
    /// machinery `NSImageView.animates` relies on. Stepping `.currentFrame`
    /// and reading `.cgImage`/`.currentFrameDuration` at each index recovers
    /// every frame intact. Verified empirically against both GIF and APNG
    /// sources (frame images and per-frame durations matched ground truth
    /// read directly via CGImageSource). It does NOT work for animated
    /// WebP -- AppKit splits WebP frames into separate static
    /// `NSBitmapImageRep`s with no delay metadata attached to any of them,
    /// so an animated WebP silently falls back to a still first frame here
    /// (returns nil, and the caller's normal JPEG-still path takes over).
    static func extractFrames(from image: NSImage) -> AnimatedImageFrames? {
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
              let rawCount = bitmap.value(forProperty: .frameCount) as? Int,
              rawCount > 1 else {
            return nil
        }

        let originalFrame = bitmap.value(forProperty: .currentFrame) as? Int ?? 0
        var images: [CGImage] = []
        var delays: [TimeInterval] = []
        images.reserveCapacity(rawCount)
        delays.reserveCapacity(rawCount)

        for i in 0..<rawCount {
            bitmap.setProperty(.currentFrame, withValue: i)
            guard let cg = bitmap.cgImage else { continue }
            let rawDelay = (bitmap.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1
            images.append(cg)
            delays.append(clampDelay(rawDelay))
        }
        // Restore the rep's cursor -- it's shared mutable state on the
        // NSImage the caller still owns.
        bitmap.setProperty(.currentFrame, withValue: originalFrame)

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
    /// We deliberately re-mux to GIF rather than trying to preserve the
    /// original container's bytes verbatim (which we don't have access to
    /// in the first place -- see `extractFrames` above). GIF is the one
    /// animated format ImageIO can both decode and encode with per-frame
    /// delay + loop-count metadata through the same simple
    /// `CGImageDestination` API, so it behaves identically regardless of
    /// whether the source was GIF (lossless -- GIF is already
    /// palette-quantized, so re-quantizing on write is a no-op in practice)
    /// or APNG (introduces 256-color quantization -- an acceptable
    /// tradeoff for desktop-widget use, which is small looping
    /// stickers/clips rather than photographic gradients). Standardizing
    /// storage on one container also means the playback decoder only ever
    /// needs to understand GIF metadata.
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

    static func decodeForPlayback(data: Data) -> AnimatedImageFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        var images: [CGImage] = []
        var delays: [TimeInterval] = []
        images.reserveCapacity(count)
        delays.reserveCapacity(count)

        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
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
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            return (png[kCGImagePropertyAPNGLoopCount] as? Int) ?? 0
        }
        return 0
    }
}
