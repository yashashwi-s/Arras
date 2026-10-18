import AppKit

@MainActor
final class CollageDesktopWindow: DesktopPhotoWindow {
    var settings: DesktopCollageSettings
    var onEdit: (() -> Void)?
    var onMove: ((CGRect, Bool) -> Void)?
    var onMoveBegan: (() -> Void)?
    var onMoveFinishedWithoutChange: (() -> Void)?
    var onResizeBegan: (() -> CollageResizeSnapshot?)?
    var onCompositionResize: ((CGFloat, CollageResizeCorner, Bool) -> Void)?
    var onSnapExclusions: (() -> Set<UUID>)?
    var onMoveCancelled: (() -> Void)?
    var onRendered: (() -> Void)?
    var onHidden: (() -> Void)?
    var isEmpty = true { didSet { if isEmpty != oldValue { render() } } }
    var isCandidate = false { didSet { if isCandidate != oldValue { render() } } }
    private(set) var displayedBounds: CGRect = .zero
    private(set) var transition: CollageTransition?
    private var transitionTarget: CGRect?
    private var transitionStart: CGRect?
    private(set) var isPreviewing = false
    // contentView owns the material tree so hiding releases it even if a caller
    // still holds the closed panel. Late rendering/input must leave it detached.
    private var surface: CollageSurfaceView? { contentView as? CollageSurfaceView }

    init(settings: DesktopCollageSettings) {
        self.settings = settings
        super.init()
        isReleasedWhenClosed = false
        setCollageCanvasInset(14)
        let surface = CollageSurfaceView(frame: .zero)
        contentView = surface
        surface.owner = self
    }

    override func setPhotoFrame(_ rect: NSRect, display: Bool = true) {
        cancelTransition()
        isPreviewing = false
        setCollageCanvasInset(requiredCanvasInset)
        super.setPhotoFrame(rect, display: display)
        displayedBounds = rect
        render()
    }

    override func setPhotoOrigin(_ origin: NSPoint) {
        let dx = origin.x - photoFrame.minX, dy = origin.y - photoFrame.minY
        // A translation changes no local material, text or grip geometry.
        // Keep an in-flight boundary animation's larger host intact too.
        transition?.translation.x += dx
        transition?.translation.y += dy
        transitionStart = transitionStart?.offsetBy(dx: dx, dy: dy)
        transitionTarget = transitionTarget?.offsetBy(dx: dx, dy: dy)
        displayedBounds = displayedBounds.offsetBy(dx: dx, dy: dy)
        var host = photoFrame
        host.origin = origin
        if transition != nil { host = (transitionStart ?? displayedBounds).union(displayedBounds).union(transitionTarget ?? displayedBounds) }
        setPhotoOrigin(origin, nativeOrigin: windowFrame(forPhoto: host).origin)
        onRendered?()
    }

    /// A larger host holds both endpoints. The material moves within it while the
    /// photos stay in their own windows; growing the host never clips or shifts a photo.
    func fit(to target: CGRect, animated: Bool = true) {
        isPreviewing = false
        // Release confirms the hover target; it must not restart the entry motion.
        if animated, transition != nil, transitionTarget == target { return }
        let start = displayedBounds.isEmpty ? photoFrame : displayedBounds
        cancelTransition()
        guard animated && settings.duration > 0 && start != target else { setPhotoFrame(target); return }
        displayedBounds = start
        transitionStart = start
        updateTransitionTarget(target)
        let animation = CollageTransition(duration: settings.duration, animationCurve: .linear)
        animation.animationBlockingMode = .nonblocking
        animation.frameRate = 60
        transition = animation
        animation.step = { [weak self, weak animation] progress in
            guard let self, self.transition === animation, let target = self.transitionTarget else { return }
            let origin = start.offsetBy(dx: animation?.translation.x ?? 0, dy: animation?.translation.y ?? 0)
            self.displayedBounds = CollageGeometry.interpolated(origin, target, progress: progress)
            self.render()
            if progress >= 1 {
                let previewing = self.isPreviewing
                self.setPhotoFrame(target)
                self.isPreviewing = previewing
            }
        }
        animation.start()
    }

    /// Keep one finite entry animation while the pointer moves. Restarting an
    /// ease-in on every mouse event would postpone almost all growth until release.
    func preview(to target: CGRect, restart: Bool = false) {
        if isPreviewing && !restart {
            guard target != photoFrame else { return }
            if transition != nil {
                updateTransitionTarget(target)
            } else {
                setPhotoFrame(target)
                isPreviewing = true
            }
        } else {
            fit(to: target)
            isPreviewing = true
        }
    }

    private func updateTransitionTarget(_ target: CGRect) {
        transitionTarget = target
        let host = (transitionStart ?? displayedBounds).union(displayedBounds).union(target)
        setCollageCanvasInset(requiredCanvasInset)
        super.setPhotoFrame(target)
        setFrame(windowFrame(forPhoto: host), display: true)
        render()
    }

    func cancelTransition() {
        transition?.step = nil
        transition?.stop()
        transition = nil
        transitionTarget = nil
        transitionStart = nil
    }

    func moveKeepingTransition(to frame: CGRect) {
        if frame.size == photoFrame.size { setPhotoOrigin(frame.origin) }
        else { setPhotoFrame(frame) }
    }

    private var requiredCanvasInset: CGFloat { max(14, settings.effectiveBorderWidth + 2) }

    override var visualFrame: NSRect {
        photoFrame.insetBy(dx: -settings.effectiveBorderWidth, dy: -settings.effectiveBorderWidth)
    }

    func render() {
        guard let surface else { return }
        // Appearance can change without changing the group's bounds. Reserve
        // the entire outside stroke, including during a growing hover preview.
        if canvasInset != requiredCanvasInset {
            setCollageCanvasInset(requiredCanvasInset)
            if !displayedBounds.isEmpty {
                let host = (transitionStart ?? displayedBounds).union(displayedBounds).union(transitionTarget ?? displayedBounds)
                setFrame(windowFrame(forPhoto: host), display: true)
            }
        }
        surface.frame = CGRect(origin: .zero, size: frame.size)
        surface.update(body: displayedBounds.offsetBy(dx: -frame.minX, dy: -frame.minY),
                       settings: settings, empty: isEmpty, candidate: isCandidate)
        onRendered?()
    }

    override func setLocked(_ locked: Bool) { surface?.locked = locked }
    override func hidePhoto() {
        surface?.cancelOperation(nil)
        surface?.owner = nil
        cancelTransition()
        super.hidePhoto()
        onHidden?()
    }
    override func orderFront(_ sender: Any?) { super.orderFront(sender); onWindowInteraction?() }

    func containsBackgroundPoint(_ screenPoint: CGPoint) -> Bool {
        guard let surface else { return false }
        return surface.containsBackgroundPoint(surface.convert(convertPoint(fromScreen: screenPoint), from: nil))
    }

    func resetManipulation() { surface?.resetManipulation() }
}

@MainActor
final class CollageTransition: NSAnimation {
    var step: ((Double) -> Void)?
    var translation = CGPoint.zero
    override var currentProgress: NSAnimation.Progress { didSet { step?(Double(currentProgress)) } }
}

@MainActor
final class CollageSurfaceView: NSView, NSMenuDelegate {
    weak var owner: CollageDesktopWindow?
    var locked = false { didSet { if locked != oldValue { if locked { cancelOperation(nil) }; updateChrome() } } }
    private let materialHost = NSView()
    private let chrome = NSView()
    private let fallback = NSVisualEffectView()
    private var glass: NSView?
    private let paper = NSView()
    private let glassContent = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Drop a widget here")
    private let outline = CAShapeLayer()
    private(set) var outerBorder = CAShapeLayer()
    private var borderHitMargin: CGFloat = 2
    private var body: CGRect = .zero
    private var initialPointer = CGPoint.zero
    private var pickup = CGRect.zero
    private var dragging = false
    private var cornerRadius: CGFloat = 0
    private var hovering = false
    private var candidate = false
    private var resizeCorner: CollageResizeCorner?
    private var resizeLimits: ClosedRange<CGFloat> = 1...1
    private var resizeScale: CGFloat = 1
    private var moveChanged = false
    private var gripLayers: [CAShapeLayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        materialHost.wantsLayer = true
        materialHost.layer?.shadowColor = NSColor.black.cgColor
        materialHost.layer?.shadowOpacity = 0.14
        materialHost.layer?.shadowRadius = 10
        materialHost.layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(materialHost)
        fallback.material = .underWindowBackground
        fallback.blendingMode = .behindWindow
        fallback.state = .active
        fallback.wantsLayer = true
        materialHost.addSubview(fallback)
        if #available(macOS 26.0, *) {
            let native = NSGlassEffectView()
            native.contentView = glassContent
            materialHost.addSubview(native)
            glass = native
        }
        paper.wantsLayer = true
        materialHost.addSubview(paper)
        for label in [caption, hint] {
            label.alignment = .center
            label.isEditable = false
            label.isSelectable = false
            (glass == nil ? materialHost : glassContent).addSubview(label)
        }
        caption.font = .systemFont(ofSize: 16, weight: .medium)
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .secondaryLabelColor
        outline.fillColor = nil
        outline.lineWidth = 2
        outerBorder.fillColor = nil
        // AppKit composites backing layers of subviews above manual layers on
        // their parent. Keep resize controls in a foreground sibling so opaque
        // paper and native glass cannot cover them.
        chrome.wantsLayer = true
        addSubview(chrome)
        chrome.layer?.addSublayer(outerBorder)
        chrome.layer?.addSublayer(outline)
        for _ in CollageResizeCorner.allCases {
            let grip = CAShapeLayer()
            grip.shadowColor = NSColor.black.cgColor
            grip.shadowOpacity = 0.18
            grip.shadowRadius = 2
            grip.shadowOffset = CGSize(width: 0, height: -1)
            grip.lineWidth = 1
            chrome.layer?.addSublayer(grip)
            gripLayers.append(grip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(body: CGRect, settings: DesktopCollageSettings, empty: Bool, candidate: Bool, scale: CGFloat = 1) {
        let padding = settings.effectivePadding * scale
        let radius = settings.effectiveCornerRadius * scale
        cornerRadius = radius
        self.candidate = candidate
        self.body = body
        let tint = NSColor.fromHex(settings.tintHex) ?? .windowBackgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chrome.frame = bounds
        materialHost.frame = body
        materialHost.layer?.shadowOpacity = settings.skin == .glass || settings.skin == .transparent ? 0 : 0.12
        materialHost.layer?.shadowRadius = (settings.skin == .polaroid ? 6 : 10) * settings.compositionScale * scale
        materialHost.layer?.shadowOffset = CGSize(width: 0, height: -3 * settings.compositionScale * scale)
        let local = CGRect(origin: .zero, size: body.size)
        materialHost.layer?.shadowPath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
        fallback.frame = local
        fallback.layer?.cornerRadius = radius
        fallback.layer?.masksToBounds = true
        fallback.isHidden = settings.skin != .glass || glass != nil
        glass?.frame = local
        glass?.isHidden = settings.skin != .glass
        if #available(macOS 26.0, *), let native = glass as? NSGlassEffectView {
            native.style = settings.glassStyle == .system ? .regular : .clear
            native.cornerRadius = radius
            native.tintColor = settings.usesCustomTint ? tint.withAlphaComponent(settings.tintStrength) : nil
        }
        // The native contentView is the documented glass-content composition
        // point. Paper labels return to the ordinary surface above its fill.
        let labelHost = settings.skin == .glass && glass != nil ? glassContent : materialHost
        for label in [caption, hint] where label.superview !== labelHost { labelHost.addSubview(label) }
        glassContent.frame = local
        paper.frame = local
        paper.isHidden = settings.skin == .glass || settings.skin == .transparent
        paper.layer?.backgroundColor = tint.cgColor
        paper.layer?.cornerRadius = radius
        paper.layer?.borderWidth = settings.skin == .glass ? 0 : 0.5 * settings.compositionScale * scale
        paper.layer?.borderColor = (tint.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.55
            ? NSColor.black.withAlphaComponent(0.08).cgColor : NSColor.white.withAlphaComponent(0.1).cgColor
        paper.layer?.shadowColor = NSColor.black.cgColor
        paper.layer?.shadowOpacity = settings.skin == .polaroid ? 0.12 : 0
        paper.layer?.shadowRadius = 1.2 * settings.compositionScale * scale
        paper.layer?.shadowOffset = CGSize(width: 0, height: -settings.compositionScale * scale)
        paper.layer?.shadowPath = materialHost.layer?.shadowPath
        caption.stringValue = settings.caption
        caption.font = .systemFont(ofSize: max(7, 16 * settings.compositionScale * scale), weight: .medium)
        caption.textColor = settings.skin == .glass || settings.skin == .transparent ? .labelColor : ((tint.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.55 ? NSColor.black.withAlphaComponent(0.8) : .white)
        caption.isHidden = settings.captionHeight == 0 || owner?.onRendered != nil
        caption.frame = CGRect(x: padding, y: padding / 2, width: max(0, local.width - padding * 2), height: settings.captionHeight * scale)
        hint.isHidden = !empty && !candidate
        hint.stringValue = candidate ? "Release to add" : "Drop a widget here"
        hint.textColor = candidate ? .controlAccentColor : (settings.skin == .glass || settings.skin == .transparent ? .secondaryLabelColor :
            ((tint.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.55 ? NSColor.black : .white).withAlphaComponent(0.55))
        hint.frame = CGRect(x: 8, y: candidate && !empty ? 4 : local.midY - 8, width: max(0, local.width - 16), height: 20)
        let borderWidth = settings.effectiveBorderWidth * scale
        borderHitMargin = max(2, borderWidth)
        outerBorder.isHidden = borderWidth == 0
        outerBorder.lineWidth = borderWidth
        outerBorder.strokeColor = (NSColor.fromHex(settings.borderColorHex) ?? .white).cgColor
        outerBorder.path = CGPath(roundedRect: body.insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2),
                                 cornerWidth: radius + borderWidth / 2, cornerHeight: radius + borderWidth / 2, transform: nil)
        outline.path = CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        updateChrome()
        CATransaction.commit()
        setAccessibilityLabel(empty ? "Empty collage, drop a widget here" : "Desktop collage")
        setAccessibilityIdentifier("desktop-collage-" + (owner?.photoId?.uuidString ?? ""))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        // The material moves inside a fixed animation host. Track that host,
        // then resolve the current body/grips instead of keeping a stale rect.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate, .mouseEnteredAndExited], owner: self))
        super.updateTrackingAreas()
    }
    func containsBackgroundPoint(_ point: CGPoint) -> Bool {
        // Include the visible outline at the outer edge, excluding transparent
        // rounded corners and the much larger shadow canvas.
        if resizeCorner(at: point) != nil { return true }
        return CGPath(roundedRect: body.insetBy(dx: -borderHitMargin, dy: -borderHitMargin), cornerWidth: cornerRadius + borderHitMargin,
               cornerHeight: cornerRadius + borderHitMargin, transform: nil).contains(point)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { containsBackgroundPoint(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovering = false; updateChrome() }

    func updatePointer(at point: CGPoint) {
        let inside = containsBackgroundPoint(point)
        if hovering != inside { hovering = inside; updateChrome() }
        if !inside && !dragging { NSCursor.arrow.set() }
        else { applyCursor(at: point) }
    }

    private func resizeCorner(at point: CGPoint) -> CollageResizeCorner? {
        guard owner != nil, !locked else { return nil }
        return CollageResizeCorner.allCases.first { corner in
            let center = corner.gripCenter(in: body, radius: cornerRadius)
            return CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20).contains(point)
        }
    }

    private func updateChrome() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.strokeColor = NSColor.controlAccentColor.withAlphaComponent(candidate ? 0.9 : ((hovering || dragging) && !locked ? 0.28 : 0)).cgColor
        for (index, corner) in CollageResizeCorner.allCases.enumerated() {
            let center = corner.gripCenter(in: body, radius: cornerRadius)
            let grip = gripLayers[index]
            grip.path = CGPath(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7), transform: nil)
            grip.fillColor = NSColor.windowBackgroundColor.cgColor
            grip.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            grip.isHidden = owner == nil || locked || !(hovering || dragging)
        }
        CATransaction.commit()
    }

    private func applyCursor(at point: CGPoint) {
        if locked { NSCursor.arrow.set() }
        else if let corner = resizeCorner ?? resizeCorner(at: point) {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch corner {
                case .bottomLeft: position = .bottomLeft
                case .bottomRight: position = .bottomRight
                case .topLeft: position = .topLeft
                case .topRight: position = .topRight
                }
                NSCursor.frameResize(position: position, directions: .all).set()
            } else { NSCursor.crosshair.set() }
        }
        else { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        // A background must not be raised over its images, even when locked or
        // when a double click opens its editor instead of starting a drag.
        NSApp.preventWindowOrdering()
        if dragging { cancelOperation(nil) }
        defer { owner?.onWindowInteraction?() }
        if event.clickCount == 2 {
            dragging = false
            // Finish the desktop click and restore its stack before constructing
            // or activating the editor. Repair again after presentation.
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self, let owner, owner.isVisible, owner.contentView === self else { return }
                owner.onEdit?()
                owner.onWindowInteraction?()
            }
            return
        }
        guard !locked, let owner else { return }
        initialPointer = owner.pointerLocation()
        moveChanged = false
        resizeCorner = resizeCorner(at: convert(event.locationInWindow, from: nil))
        if resizeCorner != nil {
            guard let snapshot = owner.onResizeBegan?() else { resizeCorner = nil; return }
            pickup = snapshot.bounds
            resizeLimits = snapshot.limits
            resizeScale = 1
        } else {
            pickup = owner.photoFrame
            owner.onMoveBegan?()
        }
        SnapEngine.shared.beginDrag(for: owner, excluding: owner.onSnapExclusions?() ?? [], includeCollages: true)
        dragging = true
        updateChrome()
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let owner else { return }
        let pointer = owner.pointerLocation()
        var guides: [SnapGuide]
        if let corner = resizeCorner {
            let proposed = corner.proposedScale(in: pickup, delta: CGPoint(x: pointer.x - initialPointer.x, y: pointer.y - initialPointer.y))
            resizeScale = min(resizeLimits.upperBound, max(resizeLimits.lowerBound, proposed))
            guides = SnapEngine.shared.resizeGuides(for: corner.frame(from: pickup, scale: resizeScale), corner: corner, modifiers: event.modifierFlags)
            owner.onCompositionResize?(resizeScale, corner, false)
        } else {
            let proposed = CGPoint(x: pickup.minX + pointer.x - initialPointer.x, y: pickup.minY + pointer.y - initialPointer.y)
            let snapped = SnapEngine.shared.snappedOrigin(for: owner, proposedOrigin: proposed, size: pickup.size, matInset: 0,
                                                         modifiers: event.modifierFlags, dragStart: pickup.origin)
            guides = snapped.guides
            moveChanged = moveChanged || snapped.origin != pickup.origin
            owner.onMove?(CGRect(origin: snapped.origin, size: pickup.size), false)
        }
        if let screen = owner.screen ?? NSScreen.main { SnapGuideOverlay.shared.show(guides, on: screen, above: owner) }
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging, let owner else { return }
        dragging = false
        SnapGuideOverlay.shared.hide()
        SnapEngine.shared.endDrag()
        if let corner = resizeCorner { owner.onCompositionResize?(resizeScale, corner, true) }
        else if moveChanged { owner.onMove?(owner.photoFrame, true) }
        else { owner.onMoveFinishedWithoutChange?() }
        resizeCorner = nil
        moveChanged = false
        updateChrome()
        NSCursor.arrow.set()
    }
    override func cancelOperation(_ sender: Any?) {
        guard dragging else { return }
        resetManipulation()
        owner?.onMoveCancelled?()
        NSCursor.arrow.set()
    }

    func resetManipulation() {
        dragging = false
        resizeCorner = nil
        SnapGuideOverlay.shared.hide()
        SnapEngine.shared.endDrag()
        updateChrome()
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        var point = window.convertPoint(toScreen: event.locationInWindow)
        if dragging { cancelOperation(nil) }
        NSApp.preventWindowOrdering()
        defer { owner?.onWindowInteraction?() }
        owner?.onWindowInteraction?()
        let menu = makeContextMenu()
        // A view-owned context menu can raise its backdrop panel after the
        // ordering callback, briefly covering every photo after a Space change.
        // A screen-positioned menu has no owning window for AppKit to raise.
        // Match contextual-menu placement: leave the opening point outside the
        // leading edge so another click dismisses instead of selecting Edit.
        point.x += NSApp.userInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        point.y += 1
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for (title, action) in [("Edit Collage…", #selector(edit)), (locked ? "Unlock Position" : "Lock Position", #selector(toggleLock)), ("Remove Collage, Keep Photos", #selector(remove))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        owner?.onWindowInteraction?()
    }

    func menuDidClose(_ menu: NSMenu) {
        owner?.onWindowInteraction?()
    }
    @objc private func edit() { owner?.onEdit?() }
    @objc private func toggleLock() { owner?.onLockToggle?() }
    @objc private func remove() { owner?.onRemove?() }

}
