import AppKit

// MARK: - Borders, frames & depth
//
// These setters look up the live window through `PhotoManager.windows`, the same dictionary
// every other setter uses. They used to scan `NSApp.windows` for a window whose `photoId`
// matched, which looked equivalent and was not: widget windows are created with
// `isReleasedWhenClosed = false` on purpose, so a closed one stays in `NSApp.windows` for the
// life of the process. After a single hide/show cycle — or a monitor unplug, or a privacy
// auto-hide — the scan returned the corpse, and mat, shape, stroke, gradient, tilt and every
// style preset silently stopped applying while the four setters that live in ImageManager
// carried on working.

extension PhotoManager {
    /// Persist the photo and its enclosing collage together before changing live windows.
    /// A failed save must leave both the preview and desktop at their last saved appearance.
    func editAppearance(_ id: UUID, _ edit: (inout PhotoItem) -> Void) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let previous = photos
        edit(&photos[index])
        photos[index].stylePreset = nil
        let parent = photos[index].collageParentID
        if let parent { fitCollageModel(parent) }
        guard persist() else { photos = previous; return }
        applyLiveAppearance(photos[index])
        if let parent { fitCollageWindow(parent) }
    }

    func setMat(_ id: UUID, width: CGFloat, colorHex: String) {
        guard width.isFinite else { return }
        editAppearance(id) { $0.matWidth = max(0, width); $0.matColorHex = colorHex }
    }

    func setShapeMask(_ id: UUID, _ shape: PhotoShapeMask) {
        editAppearance(id) { $0.shapeMask = shape.rawValue }
    }

    func setBorderStyle(_ id: UUID, _ style: PhotoBorderStyle) {
        editAppearance(id) { $0.borderStyle = style.rawValue }
    }

    func setBorderGradient(_ id: UUID, enabled: Bool, colorHex: String) {
        editAppearance(id) { $0.borderGradientEnabled = enabled; $0.borderGradientColorHex = colorHex }
    }

    func setTilt(_ id: UUID, _ degrees: Double) {
        guard degrees.isFinite else { return }
        editAppearance(id) { $0.tiltDegrees = max(-12, min(12, degrees)) }
    }

    // MARK: - Style presets

    func applyPreset(_ id: UUID, _ preset: StylePreset) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let previous = photos
        photos[index] = preset.applying(to: photos[index])

        let parent = photos[index].collageParentID
        if let parent { fitCollageModel(parent) }
        guard persist() else { photos = previous; return }
        applyLiveAppearance(photos[index])
        if let parent { fitCollageWindow(parent) }
    }

    /// Pushes every appearance field of `item` onto its live window in one shot -- used by
    /// preset application, where a dozen fields change together and re-deriving each one
    /// through its own single-field setter would mean a dozen separate redraw passes for
    /// what the user experiences as one click.
    private func applyLiveAppearance(_ item: PhotoItem) {
        guard let window = windows[item.id],
              let view = window.contentView as? DraggablePhotoView else { return }
        view.setCornerRadius(item.cornerRadius)
        window.applyShadowSettings(enabled: item.shadowEnabled, blur: item.shadowBlur, opacity: item.shadowOpacity)
        view.applyBorder(width: item.borderWidth, color: item.borderColor)
        view.setBorderStyle(PhotoBorderStyle(rawValue: item.borderStyle) ?? .solid)
        view.setBorderGradient(enabled: item.borderGradientEnabled, color: item.borderGradientColor)
        view.setMat(width: item.matWidth, color: item.matColor)
        view.setShapeMask(PhotoShapeMask(rawValue: item.shapeMask) ?? .roundedRect)
        view.setTilt(CGFloat(item.tiltDegrees))
        if item.vignetteEnabled {
            view.applyVignette()
        } else {
            view.removeVignette()
        }
        window.setPhotoOpacity(item.opacity)
        window.setRevealOnHover(item.revealOnHover, animated: false)
        view.setFocalPoint(
            item.focalPoint,
            cropEnabled: !item.spaceImageFilenames.isEmpty && item.folderSizeMode == "fixed"
        )
        // Mat, shadow and tilt all changed at once; re-derive the padding once at the end.
        window.refreshCanvasInset()
    }

    /// Re-renders an already-mutated appearance snapshot without saving. Selection-wide style
    /// paste uses this hook so every target updates together and the manager can perform one
    /// transactional photos.json write.
    func refreshLiveAppearance(_ item: PhotoItem) {
        applyLiveAppearance(item)
    }
}
