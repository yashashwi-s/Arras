import AppKit

@MainActor
struct CollageMoveSnapshot {
    let originals: [PhotoItem]
    var translation = CGPoint.zero
    var nativeParent: NSWindow?
    var nativeFollowers: [NSWindow] = []

    func detachFollowers() {
        guard let nativeParent else { return }
        for follower in nativeFollowers where follower.parent === nativeParent { nativeParent.removeChildWindow(follower) }
    }
}

@MainActor
struct CollageDrag {
    var pickup: CGRect
    var parentID: UUID?
    var targetID: UUID?
    var resized = false
    var hasProposed = false
    var sourceBounds: CGRect?
    var sourceRemainder: CGRect?
    var escapedSource = false
    var interruptedDestination: CGRect?
    var remainingDuration: TimeInterval = 0
}

@MainActor
extension PhotoManager {
    func collageMembers(_ id: UUID) -> [PhotoItem] { photos.filter { $0.collageParentID == id && $0.desktopCollage == nil } }
    /// Manual hiding removes layout obstacles; temporary display/presence hiding
    /// preserves the composition so calls and display changes do not rearrange it.
    func collageLayoutMembers(_ id: UUID) -> [PhotoItem] { collageMembers(id).filter(\.isVisible) }
    var collageRootItems: [PhotoItem] {
        let parents = Set(photos.filter { $0.desktopCollage != nil }.map(\.id))
        return photos.filter { item in
            guard item.desktopCollage == nil, let parent = item.collageParentID else { return true }
            return !parents.contains(parent)
        }
    }
    func collageFrame(_ item: PhotoItem) -> CGRect { windows[item.id]?.photoFrame ?? NSRectFromString(item.frameString) }
    func collageFootprint(_ item: PhotoItem) -> CGRect { CollageGeometry.footprint(item, frame: collageFrame(item)) }
    func effectiveDepth(of item: PhotoItem) -> WidgetDepth {
        guard let parent = item.collageParentID,
              let group = photos.first(where: { $0.id == parent && $0.desktopCollage != nil }) else { return item.depth }
        return group.depth
    }
    func isLockedByCollage(_ item: PhotoItem) -> Bool {
        guard let parent = item.collageParentID else { return false }
        return photos.first { $0.id == parent && $0.desktopCollage != nil }?.isLocked ?? false
    }
    func isEffectivelyLocked(_ item: PhotoItem) -> Bool { item.isLocked || isLockedByCollage(item) }

    func requestCollageEditor(_ id: UUID) {
        guard photos.contains(where: { $0.id == id && $0.desktopCollage != nil }) else { return }
        collageEditorID = id
        // Every request is delivered, including reopening the same collage.
        NotificationCenter.default.post(name: .openDesktopCollageSettings, object: id)
    }

    @discardableResult
    func addDesktopCollage(skin: CollageSkin = .glass) -> UUID? {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = CollageGeometry.emptyFrame(in: screen, avoiding: photos.filter { $0.isVisible }.map(collageFootprint))
        var item = PhotoItem(filename: "", width: frame.width)
        item.desktopCollage = DesktopCollageSettings(skin: skin)
        item.customName = "Collage"
        item.frameString = NSStringFromRect(frame)
        item.stackOrder = (photos.map(\.stackOrder).max() ?? 0) + 1
        if let display = NSScreen.main { item.displayIdentifier = DisplayManager.identifier(for: display) }
        photos.append(item)
        guard persist() else { photos.removeAll { $0.id == item.id }; return nil }
        createCollageWindow(item)
        return item.id
    }

    func createCollageWindow(_ item: PhotoItem) {
        guard let settings = item.desktopCollage else { return }
        let window = CollageDesktopWindow(settings: settings)
        window.setSettingsWindowActive(settingsWindowIsActive)
        window.photoId = item.id
        window.setPhotoFrame(NSRectFromString(item.frameString))
        window.setDepth(item.depth)
        window.setSpaceBound(item.isSpaceBound)
        window.setLocked(item.isLocked)
        window.setPhotoOpacity(item.opacity)
        window.sharingType = excludeFromScreenCapture ? .none : .readOnly
        window.onMove = { [weak self] frame, finished in self?.moveCollage(item.id, to: frame, finished: finished) }
        window.onMoveBegan = { [weak self, weak window] in
            guard let self, self.collageMoveSnapshots[item.id] == nil,
                  let window, let parent = self.photos.first(where: { $0.id == item.id }), !parent.isLocked else { return }
            self.suspendCollageAppearancePreview(item.id)
            var snapshot = CollageMoveSnapshot(originals: [parent] + self.collageMembers(item.id))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                window.setPhotoOrigin(window.photoFrame.origin)
                var followers: [NSWindow] = []
                for member in self.collageMembers(item.id) {
                    guard let follower = self.windows[member.id], follower.isVisible, follower.isOnActiveSpace else { continue }
                    follower.setPhotoOrigin(follower.photoFrame.origin)
                    followers.append(follower)
                }
                self.updateCollageLabels(item.id)
                if let label = self.collageLabelWindows[item.id], label.isVisible, label.isOnActiveSpace { followers.append(label) }
                // Native following applies to translation. A boundary animation
                // also moves its host within the scene and keeps explicit placement.
                if window.transition == nil {
                    snapshot.nativeParent = window
                    for follower in followers where follower.parent == nil {
                        window.addChildWindow(follower, ordered: .above)
                        snapshot.nativeFollowers.append(follower)
                    }
                }
                self.collageMoveSnapshots[item.id] = snapshot
                self.enforceCollageOrdering(item.id)
            }
            self.objectWillChange.send()
        }
        window.onMoveFinishedWithoutChange = { [weak self] in
            self?.collageMoveSnapshots[item.id]?.detachFollowers()
            self?.collageMoveSnapshots.removeValue(forKey: item.id)
            self?.resumeCollageAppearancePreview(item.id)
            self?.objectWillChange.send()
        }
        window.onResizeBegan = { [weak self] in self?.beginCollageResize(item.id) }
        window.onCompositionResize = { [weak self] scale, corner, finished in self?.resizeCollage(item.id, scale: scale, corner: corner, finished: finished) }
        window.onSnapExclusions = { [weak self] in Set(self?.collageMembers(item.id).map(\.id) ?? []) }
        window.onMoveCancelled = { [weak self] in self?.cancelCollageInteractions() }
        window.onEdit = { [weak self] in
            self?.requestCollageEditor(item.id)
        }
        window.onLockToggle = { [weak self] in self?.toggleLock(item.id) }
        window.onRemove = { [weak self] in self?.removePhoto(item.id) }
        window.onWindowInteraction = { [weak self] in self?.enforceCollageOrdering(item.id) }
        window.onRendered = { [weak self] in self?.updateCollageLabels(item.id) }
        window.onHidden = { [weak self] in self?.collageLabelWindows.removeValue(forKey: item.id)?.close() }
        windows[item.id] = window
        window.orderFront(nil)
        syncCollages(only: [item.id])
        // The new backdrop orders all photos above itself. Restore existing text
        // at this depth without refreshing unrelated appearance drafts.
        orderCollageLabels(at: window.level)
    }

    func wireCollageDrag(_ window: DesktopPhotoWindow, item: PhotoItem) {
        window.isCollageMember = { [weak self] in self?.photos.first { $0.id == item.id }?.collageParentID != nil }
        window.onBackgroundEventTarget = { [weak self, weak window] point in
            guard let self, let window else { return nil }
            let parents = self.photos.filter { $0.desktopCollage != nil && self.windows[$0.id]?.level == window.level }
                .sorted { $0.stackOrder > $1.stackOrder }
            guard let parent = parents.first(where: { parent in
                guard let surface = self.windows[parent.id] as? CollageDesktopWindow, surface.isVisible else { return false }
                return surface.containsBackgroundPoint(point)
            }), let backdrop = self.windows[parent.id] else { return nil }
            // A foreground shadow may cover another actual photo. That photo
            // keeps its own input; only genuinely empty collage space moves it.
            for other in self.photos.sorted(by: { $0.stackOrder > $1.stackOrder }) where other.desktopCollage == nil && other.id != item.id {
                guard let target = self.windows[other.id], target.isVisible, target.level == window.level,
                      let view = target.contentView as? DraggablePhotoView else { continue }
                if view.containsPhotoInteractionPoint(view.convert(target.convertPoint(fromScreen: point), from: nil)) { return target }
            }
            return backdrop
        }
        window.contentView?.setAccessibilityElement(true)
        window.contentView?.setAccessibilityRole(.image)
        window.contentView?.setAccessibilityLabel(label(for: item))
        window.contentView?.setAccessibilityIdentifier("desktop-photo-" + item.id.uuidString)
        window.onVisualGeometryChanged = { [weak self] in self?.refitCollageAfterPhotoChange(item.id) }
        window.onCollageDragBegan = { [weak self] resizing in self?.beginCollageDrag(item.id, resizing: resizing) }
        window.onCollageDragProposed = { [weak self] rect, bypass in self?.proposeCollageDrag(item.id, frame: rect, bypassSnap: bypass) }
        window.onCollageDragEnded = { [weak self] in self?.finishCollageDrag(item.id) ?? false }
        window.onCollageDragCancelled = { [weak self] in self?.cancelCollageDrag(item.id) }
        window.onWindowInteraction = { [weak self] in
            guard let self else { return }
            let parent = self.photos.first { $0.id == item.id }?.collageParentID
            let drag = self.collageDrags[item.id]
            for id in Set([parent, drag?.parentID, drag?.targetID].compactMap { $0 }) { self.enforceCollageOrdering(id) }
        }
    }

    func beginCollageDrag(_ id: UUID, resizing: Bool = false) {
        guard let item = photos.first(where: { $0.id == id && $0.desktopCollage == nil }), !isEffectivelyLocked(item), let window = windows[id] else { return }
        let hadDraft = item.collageParentID.map { collageAppearanceDrafts[$0] != nil } ?? false
        if let parent = item.collageParentID { suspendCollageAppearancePreview(parent) }
        let flight = collageFlights.removeValue(forKey: id)
        flight?.stop()
        var drag = CollageDrag(pickup: window.photoFrame, parentID: item.collageParentID, targetID: item.collageParentID, resized: resizing)
        if let flight {
            drag.interruptedDestination = NSRectFromString(item.frameString)
            drag.remainingDuration = max(0.05, flight.duration * Double(1 - flight.currentProgress))
        }
        if hadDraft {
            drag.interruptedDestination = NSRectFromString(item.frameString)
            drag.remainingDuration = 0.18
        }
        if let parent = photos.first(where: { $0.id == item.collageParentID }), let settings = parent.desktopCollage {
            let body = NSRectFromString(parent.frameString)
            drag.sourceBounds = body
            drag.sourceRemainder = CollageGeometry.enclosing(collageLayoutMembers(parent.id).filter { $0.id != id }.map { CollageGeometry.footprint($0, frame: NSRectFromString($0.frameString)) }, fallback: body, settings: settings)
        }
        collageDrags[id] = drag
        window.orderFront(nil)
        if let parent = drag.parentID { enforceCollageOrdering(parent) }
    }

    func proposeCollageDrag(_ id: UUID, frame: CGRect, bypassSnap: Bool) -> CGRect? {
        guard var drag = collageDrags[id], let item = photos.first(where: { $0.id == id }) else { return nil }
        drag.hasProposed = true
        if drag.resized {
            collageDrags[id] = drag
            if let parentID = drag.parentID,
               let parent = photos.first(where: { $0.id == parentID }),
               let settings = parent.desktopCollage,
               let surface = windows[parentID] as? CollageDesktopWindow {
                let siblings = collageLayoutMembers(parentID).filter { $0.id != id }.map(collageFootprint)
                let footprint = CollageGeometry.footprint(item, frame: frame)
                surface.setPhotoFrame(CollageGeometry.enclosing(siblings + [footprint], fallback: surface.photoFrame, settings: settings))
            }
            return frame
        }
        let footprint = CollageGeometry.footprint(item, frame: frame)
        let candidates = photos.filter { parent in
            guard parent.desktopCollage != nil, parent.isVisible, !parent.isLocked, parent.depth.isInteractive,
                  let window = windows[parent.id], window.isVisible else { return false }
            let siblings = collageLayoutMembers(parent.id).filter { $0.id != id }.map(collageFootprint)
            // Hover growth cannot enlarge its own acceptance area. After escape,
            // the source accepts re-entry only around what actually remains.
            let body: CGRect
            if parent.id == drag.parentID {
                body = (drag.escapedSource ? drag.sourceRemainder : drag.sourceBounds) ?? NSRectFromString(parent.frameString)
            } else {
                body = NSRectFromString(parent.frameString)
            }
            if parent.id == drag.targetID {
                return CollageGeometry.retains(footprint, body: body, siblings: siblings, gap: parent.desktopCollage!.effectiveGap)
            }
            return CollageGeometry.accepts(footprint, body: body, siblings: siblings, gap: parent.desktopCollage!.effectiveGap)
        }.sorted { lhs, rhs in
            if lhs.stackOrder != rhs.stackOrder { return lhs.stackOrder > rhs.stackOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Keep the current accepted group in overlaps until the pointer leaves
        // its drop zone, rather than switching between collages while rearranging.
        let target = candidates.first { $0.id == drag.targetID } ?? candidates.first
        let targetChanged = drag.targetID != target?.id
        let justEscaped = !drag.escapedSource && drag.parentID != nil && target?.id != drag.parentID
        if justEscaped { drag.escapedSource = true }
        if targetChanged {
            if let old = drag.targetID, old != drag.parentID {
                (windows[old] as? CollageDesktopWindow)?.isCandidate = false
                fitCollageWindow(old)
            }
            if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        drag.targetID = target?.id
        collageDrags[id] = drag
        if let source = drag.parentID, source != target?.id, drag.escapedSource,
           let surface = windows[source] as? CollageDesktopWindow, let remainder = drag.sourceRemainder {
            surface.isCandidate = false
            surface.isEmpty = collageLayoutMembers(source).allSatisfy { $0.id == id }
            surface.preview(to: remainder, restart: targetChanged)
            if justEscaped || targetChanged { enforceCollageOrdering(source) }
        }
        guard let target, let settings = target.desktopCollage else {
            // Keep mouse input and group depth during the gesture. A member's
            // detached preference may be behind Finder and cannot receive a drag.
            return nil
        }
        let siblings = collageLayoutMembers(target.id).filter { $0.id != id }.map(collageFootprint)
        let snapped = bypassSnap ? footprint : CollageGeometry.snapped(footprint, siblings: siblings, gap: settings.effectiveGap)
        if let surface = windows[target.id] as? CollageDesktopWindow {
            surface.isEmpty = false
            // Rearranging an existing member is not another add operation.
            surface.isCandidate = drag.parentID != target.id
            surface.preview(to: CollageGeometry.enclosing(siblings + [snapped], fallback: NSRectFromString(target.frameString), settings: settings), restart: targetChanged)
        }
        if let window = windows[id], let parent = windows[target.id], window.level != parent.level { window.level = parent.level }
        if targetChanged { enforceCollageOrdering(target.id) }
        if let window = windows[id], let screen = window.screen ?? NSScreen.main {
            SnapGuideOverlay.shared.show(bypassSnap ? [] : CollageGeometry.alignmentGuides(snapped, siblings: siblings, gap: settings.effectiveGap), on: screen, above: window)
        }
        return frame.offsetBy(dx: snapped.minX - footprint.minX, dy: snapped.minY - footprint.minY)
    }

    /// Membership, photo position, and the fitted material bounds commit together.
    /// Hover bounds are already visible; release confirms them. Failed writes
    /// restore both the pickup and the previous material bounds.
    @discardableResult
    func finishCollageDrag(_ id: UUID) -> Bool {
        guard let drag = collageDrags.removeValue(forKey: id), let i = photos.firstIndex(where: { $0.id == id }), let window = windows[id] else { return false }
        defer { if let parent = drag.parentID { resumeCollageAppearancePreview(parent) } }
        if !drag.hasProposed && window.photoFrame == drag.pickup {
            if let destination = drag.interruptedDestination {
                animateCollagePhoto(id, to: destination, duration: drag.remainingDuration)
            }
            if let parent = drag.parentID { enforceCollageOrdering(parent) }
            return true
        }
        if let target = drag.targetID { (windows[target] as? CollageDesktopWindow)?.isCandidate = false }
        let before = photos
        let target = drag.resized ? drag.parentID : drag.targetID
        let historyIDs = Set([id, drag.parentID, target].compactMap { $0 })
        var historyBefore = storedArrangementSnapshot(before.filter { historyIDs.contains($0.id) })
        historyBefore.stacking = [id: photos[i].stackOrder]
        photos[i].collageParentID = target
        if target != nil { photos[i].stackOrder = (photos.map(\.stackOrder).max() ?? 0) + 1 }
        storeCollageFrame(id, window.photoFrame)
        if !drag.resized {
            let origin = drag.interruptedDestination ?? drag.pickup
            translateSpaceConfigurations(id, dx: window.photoFrame.minX - origin.minX, dy: window.photoFrame.minY - origin.minY)
        }
        if !photos[i].spaceImageFilenames.isEmpty {
            let names = photos[i].spaceImageFilenames
            let active = names[min(max(0, photos[i].folderImageIndex), names.count - 1)]
            photos[i].folderImageConfigs[active] = FolderImageConfig(frameString: NSStringFromRect(window.photoFrame), widgetWidth: window.photoFrame.width)
        }
        let affected = Set([drag.parentID, target].compactMap { $0 })
        for parent in affected { fitCollageModel(parent) }
        guard persist() else {
            photos = before
            restoreCollagePhoto(id, to: drag.interruptedDestination ?? drag.pickup)
            for parent in affected { fitCollageWindow(parent) }
            window.setDepth(photos[i].depth)
            window.setSpaceBound(photos[i].isSpaceBound)
            syncCollages()
            return true
        }
        var historyAfter = storedArrangementSnapshot(photos.filter { historyIDs.contains($0.id) })
        historyAfter.stacking = [id: photos[i].stackOrder]
        let name = target != drag.parentID ? (target == nil ? "Remove from Collage" : "Add to Collage")
            : (drag.resized ? "Resize Photo" : "Move Photo")
        recordArrangement(name: name, before: historyBefore, after: historyAfter)
        for parent in affected { fitCollageWindow(parent) }
        if target == nil {
            (window.contentView as? DraggablePhotoView)?.isLockedByCollage = false
            window.setDepth(photos[i].depth)
            window.setSpaceBound(photos[i].isSpaceBound)
            window.setLocked(photos[i].isLocked)
        }
        syncCollages()
        return true
    }

    func cancelCollageDrag(_ id: UUID) {
        guard let drag = collageDrags.removeValue(forKey: id) else { return }
        (windows[id]?.contentView as? DraggablePhotoView)?.cancelOperation(nil)
        for parent in Set([drag.parentID, drag.targetID].compactMap { $0 }) {
            (windows[parent] as? CollageDesktopWindow)?.isCandidate = false
            fitCollageWindow(parent)
        }
        restoreCollagePhoto(id, to: drag.interruptedDestination ?? drag.pickup)
        if drag.parentID == nil, let item = photos.first(where: { $0.id == id }) {
            windows[id]?.setDepth(item.depth)
            windows[id]?.setSpaceBound(item.isSpaceBound)
        }
        syncCollages()
        if let parent = drag.parentID { resumeCollageAppearancePreview(parent) }
    }

    private func restoreCollagePhoto(_ id: UUID, to pickup: CGRect) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.3
        animateCollagePhoto(id, to: pickup, duration: duration)
    }

    func storeCollageFrame(_ id: UUID, _ frame: CGRect) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i].frameString = NSStringFromRect(frame)
        photos[i].widgetWidth = frame.width
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
            let display = DisplayManager.identifier(for: screen)
            photos[i].displayIdentifier = display
            photos[i].savedDisplayFrames[display] = NSStringFromRect(frame)
        }
    }

    func fitCollageModel(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }), let settings = photos[i].desktopCollage else { return }
        // Saved bounds describe destinations, including any in-flight spacing
        // change. Fitting to intermediate windows can strand photos outside the
        // material once their animation finishes.
        let footprints = collageLayoutMembers(id).map { CollageGeometry.footprint($0, frame: NSRectFromString($0.frameString)) }
        let frame = CollageGeometry.enclosing(footprints, fallback: NSRectFromString(photos[i].frameString), settings: settings)
        storeCollageFrame(id, frame)
    }
    func fitCollageWindow(_ id: UUID, animated: Bool = true) {
        guard let item = photos.first(where: { $0.id == id }), let window = windows[id] as? CollageDesktopWindow else { return }
        window.settings = item.desktopCollage!
        window.isEmpty = collageLayoutMembers(id).isEmpty
        window.fit(to: NSRectFromString(item.frameString), animated: animated)
    }

    @discardableResult
    func applyCollageSettings(_ id: UUID, settings: DesktopCollageSettings, depth: WidgetDepth? = nil, isSpaceBound: Bool? = nil) -> Bool {
        if !collageMoveSnapshots.isEmpty { cancelCollageInteractions() }
        guard let i = photos.firstIndex(where: { $0.id == id }),
              let layout = collageAppearanceLayout(id, settings: settings) else { return false }
        let normalized = layout.settings
        let before = photos
        let targets = layout.frames
        for member in layout.members {
            guard let target = targets[member.id] else { continue }
            let previous = NSRectFromString(member.frameString)
            storeCollageFrame(member.id, target)
            translateSpaceConfigurations(member.id, dx: target.minX - previous.minX, dy: target.minY - previous.minY)
        }
        photos[i].desktopCollage = normalized
        if let depth {
            photos[i].depth = depth
            photos[i].isFloating = depth == .floating
            if !depth.isInteractive { photos[i].isLocked = true }
        }
        if let isSpaceBound { photos[i].isSpaceBound = isSpaceBound }
        storeCollageFrame(id, layout.bounds)
        guard persist() else { photos = before; return false }
        endCollageAppearancePreview(id, restore: false)
        for (member, target) in targets where windows[member]?.photoFrame != target { animateCollagePhoto(member, to: target, duration: normalized.duration) }
        fitCollageWindow(id)
        windows[id]?.setDepth(photos[i].depth)
        windows[id]?.setSpaceBound(photos[i].isSpaceBound)
        windows[id]?.setLocked(photos[i].isLocked)
        syncCollages()
        return true
    }

    func animateCollagePhoto(_ id: UUID, to target: CGRect, duration: TimeInterval) {
        guard let window = windows[id] else { return }
        let from = window.photoFrame
        collageFlights.removeValue(forKey: id)?.stop()
        guard duration > 0 else { window.setPhotoFrame(target); return }
        let animation = CollageTransition(duration: duration, animationCurve: .linear)
        animation.animationBlockingMode = .nonblocking
        animation.frameRate = 60
        collageFlights[id] = animation
        animation.step = { [weak self, weak window, weak animation] progress in
            guard let self, let animation, self.collageFlights[id] === animation, let window else { return }
            window.setPhotoFrame(CollageGeometry.interpolated(from, target, progress: progress).offsetBy(dx: animation.translation.x, dy: animation.translation.y))
            if progress >= 1 {
                self.collageFlights.removeValue(forKey: id)
                // History is unavailable during photo motion; refresh controls when it settles.
                self.objectWillChange.send()
            }
        }
        animation.start()
    }

    func moveCollage(_ id: UUID, to frame: CGRect, finished: Bool) {
        guard let item = photos.first(where: { $0.id == id }), !item.isLocked, let window = windows[id] as? CollageDesktopWindow else { return }
        if collageMoveSnapshots[id] == nil {
            collageMoveSnapshots[id] = CollageMoveSnapshot(originals: [item] + collageMembers(id))
        }
        let previous = window.photoFrame
        let dx = frame.minX - previous.minX, dy = frame.minY - previous.minY
        collageMoveSnapshots[id]?.translation.x += dx
        collageMoveSnapshots[id]?.translation.y += dy
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for member in collageMembers(id) {
                let moved = collageFrame(member).offsetBy(dx: dx, dy: dy)
                if let follower = windows[member.id], follower.parent === window {
                    follower.setPhotoOriginFollowingParent(moved.origin)
                } else { windows[member.id]?.setPhotoOrigin(moved.origin) }
                if let flight = collageFlights[member.id] {
                    flight.translation.x += dx
                    flight.translation.y += dy
                }
            }
            window.moveKeepingTransition(to: frame)
        }
        // The desktop windows are the live preview. Publish and save their
        // durable destinations only once, instead of rebuilding Photos per event.
        guard finished, let snapshot = collageMoveSnapshots[id] else { return }
        snapshot.detachFollowers()
        for original in snapshot.originals {
            storeCollageFrame(original.id, NSRectFromString(original.frameString).offsetBy(dx: snapshot.translation.x, dy: snapshot.translation.y))
            if original.id != id { translateSpaceConfigurations(original.id, dx: snapshot.translation.x, dy: snapshot.translation.y) }
        }
        if persist() {
            let ids = Set(snapshot.originals.map(\.id))
            recordArrangement(name: "Move Collage", before: storedArrangementSnapshot(snapshot.originals),
                              after: storedArrangementSnapshot(photos.filter { ids.contains($0.id) }))
        } else {
            for original in snapshot.originals {
                if let index = photos.firstIndex(where: { $0.id == original.id }) { photos[index] = original }
                if let flight = collageFlights.removeValue(forKey: original.id) { flight.step = nil; flight.stop() }
                windows[original.id]?.setPhotoFrame(NSRectFromString(original.frameString))
            }
        }
        collageMoveSnapshots.removeValue(forKey: id)
        resumeCollageAppearancePreview(id)
        syncCollages()
    }

    func cancelCollageInteractions(endAppearancePreviews: Bool = false) {
        let wasMoving = !collageMoveSnapshots.isEmpty
        for snapshot in collageMoveSnapshots.values { snapshot.detachFollowers() }
        for id in Array(collageResizeSnapshots.keys) { cancelCollageResize(id) }
        SnapGuideOverlay.shared.hide()
        SnapEngine.shared.endDrag()
        for (id, drag) in collageDrags {
            windows[id]?.setPhotoFrame(drag.interruptedDestination ?? drag.pickup)
            if let target = drag.targetID { (windows[target] as? CollageDesktopWindow)?.isCandidate = false }
        }
        collageDrags.removeAll()
        for (id, flight) in collageFlights {
            flight.step = nil
            flight.stop()
            if let item = photos.first(where: { $0.id == id }) { windows[id]?.setPhotoFrame(NSRectFromString(item.frameString)) }
        }
        collageFlights.removeAll()
        for snapshot in collageMoveSnapshots.values {
            for original in snapshot.originals {
                windows[original.id]?.setPhotoFrame(NSRectFromString(original.frameString))
            }
        }
        collageMoveSnapshots.removeAll()
        if endAppearancePreviews {
            for id in Array(collageAppearanceDrafts.keys) { endCollageAppearancePreview(id, animated: false, invalidateEditor: true) }
        }
        for item in photos where item.desktopCollage != nil {
            if let window = windows[item.id] as? CollageDesktopWindow {
                window.resetManipulation()
                window.isCandidate = false
                window.isEmpty = collageLayoutMembers(item.id).isEmpty
                window.setPhotoFrame(NSRectFromString(item.frameString))
            }
        }
        for id in Array(collageAppearanceDrafts.keys) { resumeCollageAppearancePreview(id) }
        if wasMoving { objectWillChange.send() }
    }

    @discardableResult
    func removeFromCollage(_ id: UUID) -> Bool {
        guard let i = photos.firstIndex(where: { $0.id == id }), let parent = photos[i].collageParentID else { return false }
        let before = photos
        let historyIDs: Set<UUID> = [id, parent]
        let historyBefore = storedArrangementSnapshot(before.filter { historyIDs.contains($0.id) })
        let saved = NSRectFromString(photos[i].frameString)
        let frame = collageFrame(photos[i])
        photos[i].collageParentID = nil
        storeCollageFrame(id, frame)
        translateSpaceConfigurations(id, dx: frame.minX - saved.minX, dy: frame.minY - saved.minY)
        fitCollageModel(parent)
        guard persist() else { photos = before; return false }
        recordArrangement(name: "Remove from Collage", before: historyBefore,
                          after: storedArrangementSnapshot(photos.filter { historyIDs.contains($0.id) }))
        if let flight = collageFlights.removeValue(forKey: id) { flight.step = nil; flight.stop() }
        if let window = windows[id] {
            (window.contentView as? DraggablePhotoView)?.isLockedByCollage = false
            window.setDepth(photos[i].depth)
            window.setSpaceBound(photos[i].isSpaceBound)
            window.setLocked(photos[i].isLocked)
        } else if photos[i].isVisible, !photos[i].isHiddenForDisplay, !photos[i].isHiddenForPresence,
                  let content = loadDisplayContent(for: photos[i]) {
            createWindow(for: photos[i], content: content)
            if !photos[i].spaceImageFilenames.isEmpty { setupRotationTimer(for: photos[i]) }
        }
        fitCollageWindow(parent)
        syncCollages()
        return true
    }

    private func translateSpaceConfigurations(_ id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        for key in Array(photos[i].folderImageConfigs.keys) {
            let config = photos[i].folderImageConfigs[key]!
            photos[i].folderImageConfigs[key] = FolderImageConfig(frameString: NSStringFromRect(NSRectFromString(config.frameString).offsetBy(dx: dx, dy: dy)), widgetWidth: config.widgetWidth)
        }
    }

    func refitCollageAfterPhotoChange(_ id: UUID) {
        guard collageDrags[id] == nil, let item = photos.first(where: { $0.id == id }), let parent = item.collageParentID, let window = windows[id] else { return }
        guard collageResizeSnapshots[parent] == nil else { return }
        storeCollageFrame(id, window.photoFrame)
        fitCollageModel(parent)
        if persist() { fitCollageWindow(parent) }
    }

    func collageAllowsWindow(_ item: PhotoItem) -> Bool {
        guard let parentID = item.collageParentID, let parent = photos.first(where: { $0.id == parentID && $0.desktopCollage != nil }) else { return true }
        return parent.isVisible && !parent.isHiddenForDisplay && !parent.isHiddenForPresence
    }

    /// Glass is a backdrop, even when AppKit orders a clicked panel forward.
    /// Keep every visible photo at this depth crisp and keep the active drag on top.
    func enforceCollageOrdering(_ id: UUID) {
        guard let parent = windows[id] as? CollageDesktopWindow, parent.isVisible, parent.isOnActiveSpace else { return }
        let visible = photos.filter { $0.desktopCollage == nil && windows[$0.id]?.isVisible == true && windows[$0.id]?.isOnActiveSpace == true && windows[$0.id]?.level == parent.level }
            .sorted { $0.stackOrder > $1.stackOrder }
        let active = Set(collageDrags.filter { $0.value.targetID == id || $0.value.parentID == id }.map(\.key))
        let resting = visible.filter { !active.contains($0.id) }
        for item in resting { windows[item.id]?.order(.above, relativeTo: parent.windowNumber) }
        let top = resting.first.flatMap { windows[$0.id] } ?? parent
        for item in visible where active.contains(item.id) { windows[item.id]?.order(.above, relativeTo: top.windowNumber) }
        orderCollageLabels(id)
    }

    func restoreCollageOrdering() {
        for item in photos where item.desktopCollage != nil { enforceCollageOrdering(item.id) }
    }

    /// Parents are always below their photos. Rebuilding or opening Settings must
    /// never place a wide transparent container window over a photo's drag target.
    func syncCollages(only parentIDs: Set<UUID>? = nil) {
        let parents = Dictionary(uniqueKeysWithValues: photos.filter { $0.desktopCollage != nil }.map { ($0.id, $0) })
        for i in photos.indices where photos[i].collageParentID != nil && parentIDs?.contains(photos[i].collageParentID!) != false {
            if parents[photos[i].collageParentID!] == nil || photos[i].collageParentID == photos[i].id || photos[i].desktopCollage != nil { photos[i].collageParentID = nil }
        }
        for parent in parents.values where parentIDs?.contains(parent.id) != false {
            let members = collageMembers(parent.id)
            (windows[parent.id] as? CollageDesktopWindow)?.isEmpty = collageLayoutMembers(parent.id).isEmpty
            for child in members.sorted(by: { $0.stackOrder > $1.stackOrder }) {
                let visible = collageAllowsWindow(child) && child.isVisible && !child.isHiddenForDisplay && !child.isHiddenForPresence
                if !visible {
                    windows[child.id]?.hidePhoto()
                    windows.removeValue(forKey: child.id)
                    rotationTimers.removeValue(forKey: child.id)?.cancel()
                    continue
                }
                if windows[child.id] == nil, windows[parent.id] != nil, let content = loadDisplayContent(for: child) {
                    createWindow(for: child, content: content)
                    if !child.spaceImageFilenames.isEmpty { setupRotationTimer(for: child) }
                }
                guard let childWindow = windows[child.id], windows[parent.id] != nil else { continue }
                childWindow.setDepth(parent.depth)
                childWindow.setSpaceBound(parent.isSpaceBound)
                (childWindow.contentView as? DraggablePhotoView)?.isLockedByCollage = parent.isLocked
                childWindow.setLocked(parent.isLocked || child.isLocked)
            }
            enforceCollageOrdering(parent.id)
        }
        for id in Array(collageAppearanceDrafts.keys) where parentIDs?.contains(id) != false { refreshCollageAppearancePreview(id) }
    }
}

extension Notification.Name {
    static let openDesktopCollageSettings = Notification.Name("openDesktopCollageSettings")
}
