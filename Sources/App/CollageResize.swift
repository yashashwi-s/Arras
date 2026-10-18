import AppKit

struct CollageResizeSnapshot {
    let originals: [PhotoItem]
    let pickup: [PhotoItem]
    let bounds: CGRect
    let limits: ClosedRange<CGFloat>
    var preview: [PhotoItem]
    var changed = false
}

@MainActor
extension PhotoManager {
    func beginCollageResize(_ id: UUID) -> CollageResizeSnapshot? {
        guard let parent = photos.first(where: { $0.id == id && $0.desktopCollage != nil }),
              !parent.isLocked, let window = windows[id] as? CollageDesktopWindow else { return nil }
        cancelCollageResize(id)
        suspendCollageAppearancePreview(id)
        let originals = [parent] + collageMembers(id)
        let bounds = window.displayedBounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Freeze visible spacing motion at pickup. Its durable destinations are
        // kept separately so a no-motion click or cancellation can resume them.
        let pickup = originals.map { item -> PhotoItem in
            var item = item
            item.frameString = NSStringFromRect(item.id == id ? bounds : collageFrame(item))
            if item.id == id { item.desktopCollage = window.settings }
            return item
        }
        for item in originals {
            if let flight = collageFlights.removeValue(forKey: item.id) { flight.step = nil; flight.stop() }
        }
        window.setPhotoFrame(bounds)
        let baseScale = parent.desktopCollage!.compositionScale
        var minimum = max(0.1 / baseScale, min(1, 64 / min(bounds.width, bounds.height)))
        for child in pickup.dropFirst() {
            let width = NSRectFromString(child.frameString).width
            if width > 0 { minimum = max(minimum, min(1, 80 / width)) }
        }
        let snapshot = CollageResizeSnapshot(originals: originals, pickup: pickup, bounds: bounds,
                                              limits: minimum...(8 / baseScale), preview: pickup)
        collageResizeSnapshots[id] = snapshot
        return snapshot
    }

    func resizeCollage(_ id: UUID, scale proposed: CGFloat, corner: CollageResizeCorner, finished: Bool) {
        guard var snapshot = collageResizeSnapshots[id], let window = windows[id] as? CollageDesktopWindow else { return }
        let scale = min(snapshot.limits.upperBound, max(snapshot.limits.lowerBound, proposed))
        guard scale.isFinite else { return }
        if finished && !snapshot.changed {
            cancelCollageResize(id, resumeMotion: true)
            return
        }
        let anchor = corner.anchor(in: snapshot.bounds)
        snapshot.changed = snapshot.changed || abs(scale - 1) > 0.000001
        snapshot.preview = transformedCollageItems(snapshot.pickup, scale: scale, corner: corner, anchor: anchor)
        collageResizeSnapshots[id] = snapshot
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.settings = snapshot.preview[0].desktopCollage!
            for child in snapshot.preview.dropFirst() { displayCollageResize(child) }
            window.setPhotoFrame(corner.frame(from: snapshot.bounds, scale: scale))
        }
        guard finished else { return }
        let before = photos
        let durableAnchor = corner.anchor(in: NSRectFromString(snapshot.originals[0].frameString))
        let translation = CGPoint(x: anchor.x - durableAnchor.x, y: anchor.y - durableAnchor.y)
        // Keep spacing destinations coherent with their gap metadata. Release
        // resumes any interrupted motion from the scaled visible pickup.
        let durable = transformedCollageItems(snapshot.originals, scale: scale, corner: corner,
                                              anchor: durableAnchor, translation: translation)
        for item in durable {
            guard let index = photos.firstIndex(where: { $0.id == item.id }) else { continue }
            copyCollageResizeGeometry(item, to: &photos[index])
            storeCollageFrame(item.id, NSRectFromString(item.frameString))
            if !photos[index].spaceImageFilenames.isEmpty {
                let names = photos[index].spaceImageFilenames
                let active = names[min(max(0, photos[index].folderImageIndex), names.count - 1)]
                photos[index].folderImageConfigs[active] = FolderImageConfig(frameString: item.frameString, widgetWidth: item.widgetWidth)
            }
        }
        guard persist() else {
            photos = before
            cancelCollageResize(id)
            return
        }
        var historyBefore = storedArrangementSnapshot(snapshot.originals)
        let ids = Set(snapshot.originals.map(\.id))
        let updated = photos.filter { ids.contains($0.id) }
        var historyAfter = storedArrangementSnapshot(updated)
        historyBefore.scaledDimensions = Dictionary(uniqueKeysWithValues: snapshot.originals.map { ($0.id, WidgetScaledDimensions($0)) })
        historyAfter.scaledDimensions = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, WidgetScaledDimensions($0)) })
        recordArrangement(name: "Resize Collage", before: historyBefore, after: historyAfter)
        collageResizeSnapshots.removeValue(forKey: id)
        let duration = min(0.2, window.settings.duration)
        for child in durable.dropFirst() where windows[child.id]?.photoFrame != NSRectFromString(child.frameString) {
            animateCollagePhoto(child.id, to: NSRectFromString(child.frameString), duration: duration)
        }
        window.fit(to: NSRectFromString(durable[0].frameString))
        resumeCollageAppearancePreview(id)
        syncCollages()
    }

    func cancelCollageResize(_ id: UUID, resumeMotion: Bool = false) {
        guard let snapshot = collageResizeSnapshots.removeValue(forKey: id) else { return }
        for child in snapshot.originals.dropFirst() {
            (windows[child.id]?.contentView as? DraggablePhotoView)?.applyScaledAppearance(child)
            let target = NSRectFromString(child.frameString)
            if resumeMotion { animateCollagePhoto(child.id, to: target, duration: min(0.2, snapshot.originals[0].desktopCollage!.duration)) }
            else { windows[child.id]?.setPhotoFrame(target) }
        }
        if let window = windows[id] as? CollageDesktopWindow {
            window.settings = snapshot.originals[0].desktopCollage!
            window.fit(to: NSRectFromString(snapshot.originals[0].frameString), animated: resumeMotion)
        }
        enforceCollageOrdering(id)
        resumeCollageAppearancePreview(id)
    }

    func transformedCollageItems(_ originals: [PhotoItem], scale: CGFloat, corner: CollageResizeCorner,
                                         anchor: CGPoint, translation: CGPoint = .zero) -> [PhotoItem] {
        let parent = originals[0]
        func transform(_ rect: CGRect) -> CGRect {
            CollageGeometry.scaled(rect, around: anchor, by: scale).offsetBy(dx: translation.x, dy: translation.y)
        }
        return originals.map { original in
            var item = original
            let frame = transform(NSRectFromString(original.frameString))
            item.frameString = NSStringFromRect(frame)
            item.widgetWidth = frame.width
            if var settings = item.desktopCollage {
                settings.compositionScale *= scale
                item.desktopCollage = settings
            } else {
                item.cornerRadius *= scale
                item.matWidth *= scale
                item.borderWidth *= scale
                item.shadowBlur *= scale
            }
            for (key, config) in original.folderImageConfigs where !config.frameString.isEmpty {
                let rect = transform(NSRectFromString(config.frameString))
                item.folderImageConfigs[key] = FolderImageConfig(frameString: NSStringFromRect(rect), widgetWidth: config.widgetWidth * scale)
            }
            for (display, saved) in original.savedDisplayFrames {
                let rect = NSRectFromString(saved)
                let profileAnchor = parent.savedDisplayFrames[display].map { corner.anchor(in: NSRectFromString($0)) }
                    ?? CGPoint(x: rect.midX, y: rect.midY)
                item.savedDisplayFrames[display] = NSStringFromRect(CollageGeometry.scaled(rect, around: profileAnchor, by: scale))
            }
            return item
        }
    }

    private func displayCollageResize(_ child: PhotoItem) {
        guard let window = windows[child.id] else { return }
        (window.contentView as? DraggablePhotoView)?.applyScaledAppearance(child)
        window.setPhotoFrame(NSRectFromString(child.frameString))
    }

    private func copyCollageResizeGeometry(_ source: PhotoItem, to target: inout PhotoItem) {
        target.frameString = source.frameString
        target.widgetWidth = source.widgetWidth
        target.desktopCollage = source.desktopCollage
        target.cornerRadius = source.cornerRadius
        target.matWidth = source.matWidth
        target.borderWidth = source.borderWidth
        target.shadowBlur = source.shadowBlur
        target.folderImageConfigs = source.folderImageConfigs
        target.savedDisplayFrames = source.savedDisplayFrames
    }
}
