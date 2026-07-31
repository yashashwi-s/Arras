import AppKit

// MARK: - Borders, frames & depth (v2.1)
//
// PhotoManager.windows and .persist() are both `private` to ImageManager.swift, which this
// file must not edit (another agent owns it concurrently). Every DesktopPhotoWindow is
// stamped with its owning photo's id at creation (`window.photoId = item.id`, see
// createWindow), so `liveWindow(for:)` below finds the same window ImageManager would have
// looked up in its private dictionary, just via NSApp.windows instead. persistAppearance()
// mirrors ImageManager.persist() exactly (same encoder, same file) for the same reason.

@MainActor
private func liveWindow(for id: UUID) -> DesktopPhotoWindow? {
    NSApp.windows.first { ($0 as? DesktopPhotoWindow)?.photoId == id } as? DesktopPhotoWindow
}

extension PhotoManager {
    // MARK: - Mat (passe-partout)

    func setMat(_ id: UUID, width: CGFloat, colorHex: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].matWidth = max(0, width)
        photos[index].matColorHex = colorHex
        (liveWindow(for: id)?.contentView as? DraggablePhotoView)?
            .setMat(width: photos[index].matWidth, color: photos[index].matColor)
        persistAppearance()
    }

    // MARK: - Shape mask

    func setShapeMask(_ id: UUID, _ shape: PhotoShapeMask) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].shapeMask = shape.rawValue
        (liveWindow(for: id)?.contentView as? DraggablePhotoView)?.setShapeMask(shape)
        persistAppearance()
    }

    // MARK: - Border style (dashed/dotted) and gradient

    func setBorderStyle(_ id: UUID, _ style: PhotoBorderStyle) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].borderStyle = style.rawValue
        (liveWindow(for: id)?.contentView as? DraggablePhotoView)?.setBorderStyle(style)
        persistAppearance()
    }

    func setBorderGradient(_ id: UUID, enabled: Bool, colorHex: String) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].borderGradientEnabled = enabled
        photos[index].borderGradientColorHex = colorHex
        (liveWindow(for: id)?.contentView as? DraggablePhotoView)?
            .setBorderGradient(enabled: enabled, color: photos[index].borderGradientColor)
        persistAppearance()
    }

    // MARK: - Tilt

    func setTilt(_ id: UUID, _ degrees: Double) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(-12, min(12, degrees))
        photos[index].tiltDegrees = clamped
        (liveWindow(for: id)?.contentView as? DraggablePhotoView)?.setTilt(CGFloat(clamped))
        persistAppearance()
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
        persistAppearance()
    }

    /// Marks a photo as hand-tuned rather than following a named preset, so the picker falls
    /// back to showing no selection instead of a stale preset name after any single-field
    /// edit. Every fine-grained setter in ContentView's Appearance group calls this.
    func clearStylePreset(_ id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }), photos[index].stylePreset != nil else { return }
        photos[index].stylePreset = nil
        persistAppearance()
    }

    /// Pushes every appearance field of `item` onto its live window in one shot -- used by
    /// preset application, where a dozen fields change together and re-deriving each one
    /// through its own single-field setter would mean a dozen separate redraw passes for
    /// what the user experiences as one click.
    private func applyLiveAppearance(_ item: PhotoItem) {
        guard let window = liveWindow(for: item.id),
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
    }

    /// Mirrors ImageManager.persist(): same JSONEncoder configuration, same destination file.
    /// Duplicated rather than exposed because `persist()` and `dataFile` are both private to
    /// ImageManager.swift.
    private func persistAppearance() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(photos) else { return }
        try? data.write(to: storageDir.appendingPathComponent("photos.json"), options: .atomic)
    }
}
