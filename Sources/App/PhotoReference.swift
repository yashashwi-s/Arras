import AppKit
import AVFoundation
import CoreImage
import ImageIO

/// Non-destructive image edits; crop coordinates use the original image's lower-left origin.
struct PhotoReferenceSettings: Codable, Equatable, Sendable {
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false
    var grayscale = false
    var cropX = 0.0
    var cropY = 0.0
    var cropWidth = 1.0
    var cropHeight = 1.0
    var note = ""
    var sourceURL = ""

    var normalized: Self {
        var result = self
        result.quarterTurns = ((quarterTurns % 4) + 4) % 4
        func clamp(_ value: Double, _ lower: Double, _ upper: Double, fallback: Double) -> Double {
            value.isFinite ? min(upper, max(lower, value)) : fallback
        }
        result.cropWidth = clamp(cropWidth, 0.05, 1, fallback: 1)
        result.cropHeight = clamp(cropHeight, 0.05, 1, fallback: 1)
        result.cropX = clamp(cropX, 0, 1 - result.cropWidth, fallback: 0)
        result.cropY = clamp(cropY, 0, 1 - result.cropHeight, fallback: 0)
        result.note = String(note.prefix(8000))
        result.sourceURL = String(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2048))
        return result
    }

    var hasImageEdits: Bool {
        let value = normalized
        return value.quarterTurns != 0 || value.flipHorizontal || value.flipVertical || value.grayscale
            || value.cropX != 0 || value.cropY != 0 || value.cropWidth != 1 || value.cropHeight != 1
    }

    var renderKey: String {
        let s = normalized
        return "\(s.quarterTurns):\(s.flipHorizontal):\(s.flipVertical):\(s.grayscale):\(s.cropX):\(s.cropY):\(s.cropWidth):\(s.cropHeight)"
    }

    var webURL: URL? {
        guard let url = URL(string: sourceURL), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    init() {}
    enum CodingKeys: String, CodingKey {
        case quarterTurns, flipHorizontal, flipVertical, grayscale, cropX, cropY, cropWidth, cropHeight, note, sourceURL
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        grayscale = try c.decodeIfPresent(Bool.self, forKey: .grayscale) ?? false
        cropX = try c.decodeIfPresent(Double.self, forKey: .cropX) ?? 0
        cropY = try c.decodeIfPresent(Double.self, forKey: .cropY) ?? 0
        cropWidth = try c.decodeIfPresent(Double.self, forKey: .cropWidth) ?? 1
        cropHeight = try c.decodeIfPresent(Double.self, forKey: .cropHeight) ?? 1
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        self = normalized
    }
}

enum PhotoReferenceRenderer {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func filtered(_ original: CIImage, settings: PhotoReferenceSettings) -> CIImage {
        let s = settings.normalized
        let bounds = original.extent
        let crop = CGRect(x: bounds.minX + bounds.width * s.cropX,
                          y: bounds.minY + bounds.height * s.cropY,
                          width: max(1, bounds.width * s.cropWidth), height: max(1, bounds.height * s.cropHeight))
            .integral.intersection(bounds)
        var result = original.cropped(to: crop)
        result = result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][s.quarterTurns]
        result = result.oriented(orientation)
        if s.flipHorizontal { result = result.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: result.extent.width, ty: 0)) }
        if s.flipVertical { result = result.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: result.extent.height)) }
        if s.grayscale { result = result.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) }
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
    }

    static func videoComposition(for asset: AVAsset, settings: PhotoReferenceSettings) async throws -> AVVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let edited = filtered(request.sourceImage, settings: settings)
            let fitted = edited.transformed(by: CGAffineTransform(
                scaleX: request.renderSize.width / edited.extent.width,
                y: request.renderSize.height / edited.extent.height))
            request.finish(with: fitted, context: context)
        })
        composition.renderSize = outputSize(for: composition.renderSize, settings: settings)
        return composition
    }

    /// Bound interactive preview work without reducing the desktop or exported originals.
    static func previewSource(_ original: NSImage) -> NSImage? {
        guard let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1280 / CGFloat(max(cg.width, cg.height)))
        let result = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(result, from: result.extent) else { return nil }
        return NSImage(cgImage: image, size: result.extent.size)
    }

    static func outputSize(for size: CGSize, settings: PhotoReferenceSettings) -> CGSize {
        let canvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        return filtered(canvas, settings: settings).extent.size
    }

    static func image(_ original: NSImage, settings: PhotoReferenceSettings) -> NSImage? {
        guard settings.hasImageEdits else { return original }
        guard let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let edited = filtered(CIImage(cgImage: cg), settings: settings)
        guard let result = context.createCGImage(edited, from: edited.extent) else { return nil }
        return NSImage(cgImage: result, size: edited.extent.size)
    }

    static func content(_ original: PhotoContent, settings: PhotoReferenceSettings) -> PhotoContent {
        guard settings.hasImageEdits else { return original }
        switch original {
        case .still(let source): return image(source, settings: settings).map(PhotoContent.still) ?? original
        case .animated(let frames, let representative):
            var editedFrames: [CGImage] = []
            for frame in frames.images {
                let edited = filtered(CIImage(cgImage: frame), settings: settings)
                guard let rendered = context.createCGImage(edited, from: edited.extent) else { return original }
                editedFrames.append(rendered)
            }
            guard let poster = image(representative, settings: settings) else { return original }
            return .animated(AnimatedImageFrames(images: editedFrames, delays: frames.delays, loopCount: frames.loopCount), representative: poster)
        case .video(var video):
            guard let poster = image(video.poster, settings: settings) else { return original }
            video.referenceSettings = settings
            video.editedPoster = poster
            return .video(video)
        case .livePhoto(let still, var video):
            guard let poster = image(still, settings: settings) else { return original }
            video.referenceSettings = settings
            video.editedPoster = image(video.poster, settings: settings)
            return .livePhoto(still: poster, video: video)
        }
    }
}

@MainActor
extension PhotoManager {
    enum ReferenceError: LocalizedError {
        case missing, changed, unfinishedEdit, mediaUnavailable, saveFailed
        var errorDescription: String? {
            switch self {
            case .missing: return "This photo is no longer on the desktop."
            case .changed: return "This photo’s reference edits changed while the editor was open. Close and reopen the editor to use the latest version."
            case .unfinishedEdit: return "Finish moving or editing this photo or its collage, then apply the reference edits again."
            case .mediaUnavailable: return "The original photo couldn’t be loaded. Restore the missing media and try again."
            case .saveFailed: return "Your edits couldn’t be saved. Your previous settings are still in place."
            }
        }
    }

    func applyReference(_ settings: PhotoReferenceSettings, to id: UUID,
                        replacing expected: PhotoReferenceSettings) throws {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              photos[index].desktopCollage == nil else { throw ReferenceError.missing }
        guard photos[index].reference == expected else { throw ReferenceError.changed }
        let normalized = settings.normalized
        guard normalized != photos[index].reference else { return }
        guard !replacementConflictsWithArrangement(photos[index]) else { throw ReferenceError.unfinishedEdit }
        let previous = photos
        let original = photos[index]
        // Notes and source links do not change pixels or geometry. Reloading their
        // window would restart playback and can invalidate completed resize history.
        if normalized.renderKey == original.reference.renderKey {
            photos[index].reference = normalized
            guard persist() else { photos = previous; throw ReferenceError.saveFailed }
            (windows[id]?.contentView as? DraggablePhotoView)?.referenceSettings = normalized
            return
        }
        guard let content = loadDisplayContent(for: original) else { throw ReferenceError.mediaUnavailable }
        photos[index].reference = normalized
        let fixedPlaylist = !original.spaceImageFilenames.isEmpty && original.folderSizeMode == "fixed"
        if !fixedPlaylist {
            let renderedSize = PhotoReferenceRenderer.outputSize(for: content.size, settings: normalized)
            var frame = windows[id]?.photoFrame ?? NSRectFromString(original.frameString)
            if frame.width > 0, renderedSize.width > 0, renderedSize.height > 0 {
                frame.size.height = frame.width * renderedSize.height / renderedSize.width
                if windows[id] != nil { storeCollageFrame(id, frame) }
                else {
                    photos[index].frameString = NSStringFromRect(frame)
                    photos[index].widgetWidth = frame.width
                    if let display = original.displayIdentifier {
                        photos[index].savedDisplayFrames[display] = NSStringFromRect(frame)
                    }
                }
                if !original.spaceImageFilenames.isEmpty {
                    let active = original.spaceImageFilenames[min(max(0, original.folderImageIndex), original.spaceImageFilenames.count - 1)]
                    photos[index].folderImageConfigs[active] = FolderImageConfig(frameString: NSStringFromRect(frame), widgetWidth: frame.width)
                }
            }
        }
        // A crop or quarter turn changes the member's footprint. Save its display
        // placement and enclosing bounds together before replacing native content.
        let parent = original.collageParentID
        if let parent { fitCollageModel(parent) }
        guard persist() else { photos = previous; throw ReferenceError.saveFailed }
        invalidateThumbnails(for: photos[index])
        // Recreate only an existing window. Hidden widgets and suppressed collages must stay hidden.
        if let window = windows.removeValue(forKey: id) {
            window.hidePhoto()
            createWindow(for: photos[index], content: content)
            if let parent { syncCollages(only: [parent]) }
        }
        if let parent { fitCollageWindow(parent) }
    }
}
