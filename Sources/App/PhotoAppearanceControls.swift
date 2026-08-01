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
    // MARK: - Mat (passe-partout)

    func setMat(_ id: UUID, width: CGFloat, colorHex: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].matWidth = max(0, width)
        photos[index].matColorHex = colorHex
        if let window = windows[id] {
            (window.contentView as? DraggablePhotoView)?
                .setMat(width: photos[index].matWidth, color: photos[index].matColor)
            // The mat grows the widget outward, so the window has to grow with it.
            window.refreshCanvasInset()
        }
        persist()
    }

    // MARK: - Shape mask

    func setShapeMask(_ id: UUID, _ shape: PhotoShapeMask) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].shapeMask = shape.rawValue
        (windows[id]?.contentView as? DraggablePhotoView)?.setShapeMask(shape)
        persist()
    }

    // MARK: - Border style (dashed/dotted) and gradient

    func setBorderStyle(_ id: UUID, _ style: PhotoBorderStyle) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].borderStyle = style.rawValue
        (windows[id]?.contentView as? DraggablePhotoView)?.setBorderStyle(style)
        persist()
    }

    func setBorderGradient(_ id: UUID, enabled: Bool, colorHex: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].borderGradientEnabled = enabled
        photos[index].borderGradientColorHex = colorHex
        (windows[id]?.contentView as? DraggablePhotoView)?
            .setBorderGradient(enabled: enabled, color: photos[index].borderGradientColor)
        persist()
    }

    // MARK: - Tilt

    func setTilt(_ id: UUID, _ degrees: Double) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(-12, min(12, degrees))
        photos[index].tiltDegrees = clamped
        if let window = windows[id] {
            (window.contentView as? DraggablePhotoView)?.setTilt(CGFloat(clamped))
            // A rotated photo sweeps a larger box; without this the corners are clipped by
            // the window's own straight edges.
            window.refreshCanvasInset()
        }
        clearStylePreset(id)
        persist()
    }

    // MARK: - Style presets

    func applyPreset(_ id: UUID, _ preset: StylePreset) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let v = preset.values

        photos[index].stylePreset = preset.rawValue
        photos[index].cornerRadius = v.cornerRadius
        photos[index].shadowEnabled = v.shadowEnabled
        photos[index].shadowBlur = v.shadowBlur
        photos[index].shadowOpacity = v.shadowOpacity
        photos[index].borderWidth = v.borderWidth
        photos[index].borderColorHex = v.borderColorHex
        photos[index].borderStyle = v.borderStyle.rawValue
        photos[index].borderGradientEnabled = v.borderGradientEnabled
        photos[index].borderGradientColorHex = v.borderGradientColorHex
        photos[index].matWidth = v.matWidth
        photos[index].matColorHex = v.matColorHex
        photos[index].shapeMask = v.shapeMask.rawValue
        photos[index].tiltDegrees = v.tiltDegrees
        photos[index].vignetteEnabled = v.vignetteEnabled

        applyLiveAppearance(photos[index])
        persist()
    }

    /// Marks a photo as hand-tuned rather than following a named preset, so the picker falls
    /// back to showing no selection instead of a stale preset name after any single-field
    /// edit. Every fine-grained setter in the appearance panel calls this.
    func clearStylePreset(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }), photos[index].stylePreset != nil else { return }
        photos[index].stylePreset = nil
        persist()
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
        // Mat, shadow and tilt all changed at once; re-derive the padding once at the end.
        window.refreshCanvasInset()
    }
}
