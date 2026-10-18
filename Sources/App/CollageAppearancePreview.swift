import AppKit

struct CollageAppearanceDraft {
    let session: UUID
    var settings: DesktopCollageSettings
    var suspended = false
    var renderedSettings: DesktopCollageSettings?
    var renderedFrames: [UUID: CGRect] = [:]
}

struct CollageAppearanceLayout {
    let settings: DesktopCollageSettings
    let members: [PhotoItem]
    let frames: [UUID: CGRect]
    let bounds: CGRect
}

@MainActor
extension PhotoManager {
    /// Both live preview and Apply resolve from committed destinations. Native
    /// glass sees the actual wallpaper and size, while drafts stay out of JSON.
    func collageAppearanceLayout(_ id: UUID, settings: DesktopCollageSettings) -> CollageAppearanceLayout? {
        guard let parent = photos.first(where: { $0.id == id }), let previous = parent.desktopCollage else { return nil }
        var normalized = settings
        normalized.compositionScale = previous.compositionScale
        normalized.normalize()
        let members = collageLayoutMembers(id)
        let originals = members.map { CollageGeometry.footprint($0, frame: NSRectFromString($0.frameString)) }
        let changed = CollageGeometry.changingGap(originals, from: previous.effectiveGap, to: normalized.effectiveGap)
        var frames: [UUID: CGRect] = [:]
        for index in members.indices {
            frames[members[index].id] = NSRectFromString(members[index].frameString)
                .offsetBy(dx: changed[index].minX - originals[index].minX, dy: changed[index].minY - originals[index].minY)
        }
        return CollageAppearanceLayout(settings: normalized, members: members, frames: frames,
                                       bounds: CollageGeometry.enclosing(changed, fallback: NSRectFromString(parent.frameString), settings: normalized))
    }

    func beginCollageAppearancePreview(_ id: UUID, session: UUID) {
        endCollageAppearancePreview(id)
        guard let settings = photos.first(where: { $0.id == id })?.desktopCollage else { return }
        collageAppearanceDrafts[id] = CollageAppearanceDraft(session: session, settings: settings)
    }

    func previewCollageAppearance(_ id: UUID, session: UUID, settings: DesktopCollageSettings) {
        guard var draft = collageAppearanceDrafts[id], draft.session == session else { return }
        draft.settings = settings
        collageAppearanceDrafts[id] = draft
        refreshCollageAppearancePreview(id)
    }

    func refreshCollageAppearancePreview(_ id: UUID) {
        guard var draft = collageAppearanceDrafts[id], !draft.suspended,
              let layout = collageAppearanceLayout(id, settings: draft.settings),
              let window = windows[id] as? CollageDesktopWindow else { return }
        guard draft.renderedSettings != layout.settings || draft.renderedFrames != layout.frames || window.photoFrame != layout.bounds else { return }
        draft.settings.compositionScale = layout.settings.compositionScale
        draft.renderedSettings = layout.settings
        draft.renderedFrames = layout.frames
        collageAppearanceDrafts[id] = draft
        for (member, target) in layout.frames where windows[member]?.photoFrame != target {
            animateCollagePhoto(member, to: target, duration: min(0.18, layout.settings.duration))
        }
        window.settings = layout.settings
        window.render()
        window.preview(to: layout.bounds)
        enforceCollageOrdering(id)
    }

    func suspendCollageAppearancePreview(_ id: UUID) {
        guard var draft = collageAppearanceDrafts[id] else { return }
        draft.suspended = true
        draft.renderedSettings = nil
        collageAppearanceDrafts[id] = draft
        for member in collageMembers(id) {
            if let flight = collageFlights.removeValue(forKey: member.id) { flight.step = nil; flight.stop() }
        }
    }

    func resumeCollageAppearancePreview(_ id: UUID) {
        guard var draft = collageAppearanceDrafts[id] else { return }
        draft.suspended = false
        collageAppearanceDrafts[id] = draft
        refreshCollageAppearancePreview(id)
    }

    func endCollageAppearancePreview(_ id: UUID, session: UUID? = nil, restore: Bool = true, animated: Bool = true, invalidateEditor: Bool = false) {
        guard let draft = collageAppearanceDrafts[id], session == nil || draft.session == session else { return }
        collageAppearanceDrafts.removeValue(forKey: id)
        if invalidateEditor { NotificationCenter.default.post(name: .collageAppearancePreviewInvalidated, object: draft.session) }
        guard restore else { return }
        for child in collageMembers(id) {
            if let flight = collageFlights.removeValue(forKey: child.id) { flight.step = nil; flight.stop() }
            let target = NSRectFromString(child.frameString)
            if windows[child.id]?.photoFrame != target { animateCollagePhoto(child.id, to: target, duration: animated ? min(0.18, draft.settings.duration) : 0) }
        }
        fitCollageWindow(id, animated: animated)
        enforceCollageOrdering(id)
    }
}

extension Notification.Name {
    static let collageAppearancePreviewInvalidated = Notification.Name("collageAppearancePreviewInvalidated")
}
