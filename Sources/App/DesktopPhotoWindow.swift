import AppKit
import SwiftUI
import QuartzCore

/// A borderless, always-on-desktop window that displays a photo.
class DesktopPhotoWindow: NSWindow {
    var photoId: UUID?
    var onLockToggle: (() -> Void)?
    var onRemove: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onClickAdvance: (() -> Void)?

    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    private static let floatingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

    init() {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        level = Self.desktopLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func showPhoto(_ content: PhotoContent, baseWidth: CGFloat = 300, locked: Bool = false, settings: PhotoItem? = nil) {
        let imageSize = content.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let aspectRatio = imageSize.width / imageSize.height
        let w = baseWidth
        let h = w / aspectRatio

        let container = DraggablePhotoView(
            frame: NSRect(x: 0, y: 0, width: w, height: h),
            content: content,
            locked: locked,
            settings: settings
        )
        container.onLockToggle = { [weak self] in self?.onLockToggle?() }
        container.onRemove = { [weak self] in self?.onRemove?() }
        container.onResizeFinished = { [weak self] newWidth in self?.onResize?(newWidth) }
        container.onOpacityChanged = { [weak self] newOpacity in self?.onOpacityChanged?(newOpacity) }

        contentView = container
        setContentSize(NSSize(width: w, height: h))

        // Force layout synchronously before display to prevent snap flicker
        self.disableScreenUpdatesUntilFlush()
        container.updateLayout(NSSize(width: w, height: h))

        // Apply settings
        if let s = settings {
            setFloating(s.isFloating)
            setPhotoOpacity(s.opacity)
            applyShadowSettings(enabled: s.shadowEnabled, blur: s.shadowBlur, opacity: s.shadowOpacity)
        }

        makeKeyAndOrderFront(nil)
    }

    func hidePhoto() {

        // Strip any in-flight CATransition animations to prevent stale callbacks
        if let container = contentView as? DraggablePhotoView {
            container.layer?.removeAllAnimations()
            container.imageView.layer?.removeAllAnimations()
            // Also tear down GIF playback explicitly rather than relying on
            // removeAllAnimations() alone -- it clears the render-server
            // side, but stopAnimating() also drops our tracked frame data
            // so a stray delayed "start playback" block (see swapImage)
            // can't resurrect it on a view that's going away.
            container.imageView.stopAnimating()
        }
        close()
    }

    func setLocked(_ locked: Bool) {
        (contentView as? DraggablePhotoView)?.isLocked = locked
    }

    func resizeTo(width: CGFloat) {
        guard let container = contentView as? DraggablePhotoView,
              let image = container.photoImage else { return }
        // photoImage is always a representative still (even for animated
        // content -- see AspectFillImageView.image), so aspect-ratio math
        // here needs no animated-specific branch.
        let ar = image.size.width / image.size.height
        let h = width / ar
        let newFrame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: h)
        setFrame(newFrame, display: true, animate: true)
        container.updateLayout(NSSize(width: width, height: h))
    }

    // MARK: - v1.1 Floating Mode

    func setFloating(_ floating: Bool) {
        level = floating ? Self.floatingLevel : Self.desktopLevel
        // Floating windows shouldn't hide on deactivate
        hidesOnDeactivate = false
    }

    func setPhotoOpacity(_ value: CGFloat) {
        contentView?.alphaValue = max(0.1, min(1.0, value))
    }

    // MARK: - v1.3 Shadow

    func applyShadowSettings(enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        hasShadow = enabled
        if enabled, let container = contentView as? DraggablePhotoView {
            container.shadow = NSShadow()
            container.shadow?.shadowColor = NSColor.black.withAlphaComponent(opacity)
            container.shadow?.shadowOffset = NSSize(width: 0, height: -2)
            container.shadow?.shadowBlurRadius = blur
        } else {
            (contentView as? DraggablePhotoView)?.shadow = nil
        }
    }

    // MARK: - Modifier Key Monitor (Option key overrides click-through)

    // MARK: - Smooth image swap (CATransition crossfade + dynamic frame)

    private static let crossfadeDuration: TimeInterval = 0.35

    func swapImage(_ content: PhotoContent, targetFrame: NSRect? = nil, mode: String = "dynamic", animate: Bool = true) {
        guard let container = contentView as? DraggablePhotoView else { return }
        let newSize = content.size
        let newAR = newSize.width / newSize.height

        if mode == "dynamic" {
            container.aspectRatio = newAR
        }

        // Determine target frame
        let newFrame: NSRect
        if mode == "fixed" {
            newFrame = frame // don't change frame
        } else {
            if let target = targetFrame, target.width > 0 {
                newFrame = target
            } else {
                // Keep current width, adjust height for new aspect ratio. Pin top-left.
                let newH = frame.width / newAR
                let newOriginY = frame.origin.y + frame.height - newH
                newFrame = NSRect(x: frame.origin.x, y: newOriginY, width: frame.width, height: newH)
            }
        }

        if animate {
            self.disableScreenUpdatesUntilFlush()
            // GPU-accelerated crossfade via Core Animation
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Self.crossfadeDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            container.imageView.layer?.add(transition, forKey: kCATransition)
        }

        // Hand off the new content (the CATransition above handles the
        // crossfade of whatever `contents` ends up being). For animated
        // content, GIF playback is deliberately deferred until the
        // crossfade finishes rather than started immediately: a
        // CAKeyframeAnimation on "contents" installed in the same
        // transaction as the CATransition would fight the transition for
        // that same property, since the transition crosses-fades toward
        // whatever `contents` is at each instant rather than a single fixed
        // end state. Landing on frame 0 first keeps the crossfade correct
        // and simple; playback then picks up smoothly right after.
        container.imageView.apply(content, animationStartDelay: animate ? Self.crossfadeDuration : 0)

        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.crossfadeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                self.animator().setFrame(newFrame, display: true)
                container.updateLayout(newFrame.size)
            }
        } else {
            setFrame(newFrame, display: true)
            container.updateLayout(newFrame.size)
        }
    }

    // MARK: - v1.5 Space Binding

    /// AppKit has no public API to enumerate or target a specific Space by identity (that's
    /// private CGS/SkyLight territory), so "bind to a Space" here means "stay on whichever
    /// Space this window is already on" rather than "always Space #3" — the achievable subset
    /// of the feature. Dropping `.canJoinAllSpaces` stops the window from following Mission
    /// Control switches; `.moveToActiveSpace` (instead of no behavior flags) keeps it visible
    /// immediately when the binding is turned on from whatever Space the user is currently on,
    /// rather than requiring a manual switch away and back.
    func setSpaceBound(_ bound: Bool) {
        collectionBehavior = bound ? [.moveToActiveSpace, .ignoresCycle] : [.canJoinAllSpaces, .ignoresCycle]
    }
}

// MARK: - Resize Handle

private enum DragMode {
    case none
    case move
    case resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight
}

// MARK: - Aspect Fill Image View

class AspectFillImageView: NSView {
    private static let gifAnimationKey = "gifPlayback"

    /// A representative still (first frame, for animated content) kept in
    /// sync at all times so aspect-ratio/size math elsewhere (resizeTo,
    /// DraggablePhotoView.photoImage) doesn't need to know or care whether
    /// playback is currently animated.
    private(set) var image: NSImage?

    /// Non-nil while a GIF-style animation is actively driving
    /// `layer.contents`.
    private(set) var animatedFrames: AnimatedImageFrames?

    /// Bumped on every `apply(_:)` call. A deferred playback-start closure
    /// captures the generation it was scheduled under and checks it before
    /// installing the CAKeyframeAnimation, so a rapid-fire Space rotation
    /// (swap A, then swap B before A's crossfade finishes) can't let A's
    /// delayed animation clobber B's content after the fact.
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Displays `content`, stopping any in-progress animation first.
    /// `animationStartDelay` lets callers (the crossfade in
    /// DesktopPhotoWindow.swapImage) land on the first frame immediately
    /// while deferring the start of looped playback until after a
    /// transition finishes, so the two animations never compete for the
    /// same `contents` property at once.
    func apply(_ content: PhotoContent, animationStartDelay: TimeInterval = 0) {
        switch content {
        case .still(let stillImage):
            setStill(stillImage)
        case .animated(let frames, let representative):
            setAnimated(frames, representativeImage: representative, startDelay: animationStartDelay)
        }
    }

    private func setStill(_ newImage: NSImage?) {
        stopAnimating()
        image = newImage
        layer?.contents = newImage
    }

    private func setAnimated(_ frames: AnimatedImageFrames, representativeImage: NSImage, startDelay: TimeInterval) {
        stopAnimating()
        image = representativeImage
        // Show frame 0 right away so there's always something on screen,
        // even before (or if) the keyframe animation below installs.
        layer?.contents = frames.images.first
        guard frames.images.count > 1 else { return }
        animatedFrames = frames

        generation += 1
        let expectedGeneration = generation
        let install: () -> Void = { [weak self] in
            // Bail if a newer `apply(_:)` call superseded us while this was
            // pending -- see the stale-callback discipline documented on
            // hidePhoto().
            guard let self, self.generation == expectedGeneration else { return }
            self.layer?.add(frames.makeContentsAnimation(), forKey: Self.gifAnimationKey)
        }
        if startDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: install)
        } else {
            install()
        }
    }

    /// Stops GIF playback and drops the tracked frame data. Cheap and safe
    /// to call even when nothing is animating.
    func stopAnimating() {
        generation += 1
        guard animatedFrames != nil else { return }
        layer?.removeAnimation(forKey: Self.gifAnimationKey)
        animatedFrames = nil
    }
}

// MARK: - Draggable Photo View

class DraggablePhotoView: NSView {
    let imageView: AspectFillImageView
    var photoImage: NSImage? { imageView.image }
    var isLocked = false

    var onLockToggle: (() -> Void)?
    var onRemove: (() -> Void)?
    var onResizeFinished: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onClickAdvance: (() -> Void)?
    private var lastAdvanceTime: TimeInterval = 0

    private var dragMode: DragMode = .none
    private var initialMouse: NSPoint = .zero
    private var anchorPoint: NSPoint = .zero   // the fixed corner (screen coords)
    // The drag's true origin, accumulated straight from mouse deltas. Never read the window's
    // on-screen frame back into this — once snapping displays an adjusted origin, the frame and
    // the true drag position diverge on purpose, and re-deriving one from the other is what
    // causes the widget to lag behind or run away from the cursor. See SnapEngine.
    private var unsnappedOrigin: NSPoint = .zero
    var aspectRatio: CGFloat = 1.0
    var baseCornerRadius: CGFloat = 16
    private let handleZone: CGFloat = 12
    private let minSize: CGFloat = 80

    // v1.3 — Aesthetic layers
    private var borderLayer: CAShapeLayer?
    private var vignetteLayer: CAGradientLayer?

    init(frame: NSRect, content: PhotoContent, locked: Bool, settings: PhotoItem? = nil) {
        imageView = AspectFillImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.apply(content)
        imageView.wantsLayer = true

        let cr = settings?.cornerRadius ?? 16
        self.baseCornerRadius = cr
        imageView.layer?.cornerRadius = min(cr, min(frame.width, frame.height) * 0.3)
        imageView.layer?.masksToBounds = true
        imageView.layer?.cornerCurve = .continuous

        self.isLocked = locked
        self.aspectRatio = content.size.width / content.size.height

        super.init(frame: frame)

        wantsLayer = true
        let shadowEnabled = settings?.shadowEnabled ?? true
        if shadowEnabled {
            shadow = NSShadow()
            shadow?.shadowColor = NSColor.black.withAlphaComponent(settings?.shadowOpacity ?? 0.3)
            shadow?.shadowOffset = NSSize(width: 0, height: -2)
            shadow?.shadowBlurRadius = settings?.shadowBlur ?? 10
        }

        addSubview(imageView)

        // Apply border
        if let s = settings, s.borderWidth > 0 {
            applyBorder(width: s.borderWidth, color: s.borderColor)
        }

        // Apply vignette
        if settings?.vignetteEnabled == true {
            applyVignette()
        }

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateLayout(_ size: NSSize) {
        frame = NSRect(origin: .zero, size: size)
        imageView.frame = bounds

        // Recalculate corner radius relative to size
        let maxRadius = min(size.width, size.height) * 0.3
        imageView.layer?.cornerRadius = min(baseCornerRadius, maxRadius)

        // Update border path
        if let bl = borderLayer {
            bl.frame = bounds
            bl.path = CGPath(
                roundedRect: bounds.insetBy(dx: bl.lineWidth / 2, dy: bl.lineWidth / 2),
                cornerWidth: imageView.layer?.cornerRadius ?? 16,
                cornerHeight: imageView.layer?.cornerRadius ?? 16,
                transform: nil
            )
        }

        // Update vignette
        vignetteLayer?.frame = bounds
    }

    // MARK: - v1.3 Aesthetic Controls

    func setCornerRadius(_ radius: CGFloat) {
        baseCornerRadius = radius
        let maxRadius = min(bounds.width, bounds.height) * 0.3
        let clamped = min(baseCornerRadius, maxRadius)
        imageView.layer?.cornerRadius = clamped

        // Update border path if present
        if let bl = borderLayer {
            bl.path = CGPath(
                roundedRect: bounds.insetBy(dx: bl.lineWidth / 2, dy: bl.lineWidth / 2),
                cornerWidth: clamped,
                cornerHeight: clamped,
                transform: nil
            )
        }
    }

    func applyBorder(width: CGFloat, color: NSColor) {
        borderLayer?.removeFromSuperlayer()

        guard width > 0 else {
            borderLayer = nil
            return
        }

        let cr = imageView.layer?.cornerRadius ?? 16
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.path = CGPath(
            roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
            cornerWidth: cr,
            cornerHeight: cr,
            transform: nil
        )
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        layer?.addSublayer(shape)
        borderLayer = shape
    }

    func applyVignette() {
        vignetteLayer?.removeFromSuperlayer()

        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.type = .radial
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.4).cgColor
        ]
        gradient.locations = [0.5, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        gradient.cornerRadius = imageView.layer?.cornerRadius ?? 16

        // Insert above image but below border
        if let bl = borderLayer {
            layer?.insertSublayer(gradient, below: bl)
        } else {
            layer?.addSublayer(gradient)
        }
        vignetteLayer = gradient
    }

    func removeVignette() {
        vignetteLayer?.removeFromSuperlayer()
        vignetteLayer = nil
    }

    // MARK: - Hit zones

    private func modeAt(_ localPoint: NSPoint) -> DragMode {
        let h = handleZone
        let w = bounds.width
        let ht = bounds.height

        let nearLeft = localPoint.x < h
        let nearRight = localPoint.x > w - h
        let nearBottom = localPoint.y < h
        let nearTop = localPoint.y > ht - h

        if nearBottom && nearLeft { return .resizeBottomLeft }
        if nearBottom && nearRight { return .resizeBottomRight }
        if nearTop && nearLeft { return .resizeTopLeft }
        if nearTop && nearRight { return .resizeTopRight }
        return .move
    }

    // MARK: - Cursor

    override func mouseMoved(with event: NSEvent) {
        if isLocked { NSCursor.arrow.set(); return }
        let p = convert(event.locationInWindow, from: nil)
        switch modeAt(p) {
        case .resizeTopLeft, .resizeBottomRight:
            NSCursor.crosshair.set()
        case .resizeTopRight, .resizeBottomLeft:
            NSCursor.crosshair.set()
        case .move:
            NSCursor.openHand.set()
        case .none:
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let now = Date().timeIntervalSince1970
            if now - lastAdvanceTime > 0.3 {
                lastAdvanceTime = now
                onClickAdvance?()
            }
            return
        }

        if isLocked { return }

        guard let win = window else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragMode = modeAt(p)
        initialMouse = NSEvent.mouseLocation
        unsnappedOrigin = win.frame.origin

        let f = win.frame
        // Set anchor = the corner OPPOSITE to the one being dragged
        switch dragMode {
        case .resizeBottomRight: anchorPoint = NSPoint(x: f.minX, y: f.maxY) // top-left fixed
        case .resizeBottomLeft:  anchorPoint = NSPoint(x: f.maxX, y: f.maxY) // top-right fixed
        case .resizeTopRight:    anchorPoint = NSPoint(x: f.minX, y: f.minY) // bottom-left fixed
        case .resizeTopLeft:     anchorPoint = NSPoint(x: f.maxX, y: f.minY) // bottom-right fixed
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isLocked { return }
        guard let win = window else { return }

        let mouse = NSEvent.mouseLocation

        switch dragMode {
        case .move:
            let dx = mouse.x - initialMouse.x
            let dy = mouse.y - initialMouse.y
            // Accumulate onto the true drag position, not the (possibly snapped) displayed
            // frame — see the comment on `unsnappedOrigin`.
            unsnappedOrigin.x += dx
            unsnappedOrigin.y += dy
            initialMouse = mouse

            let (snapped, guides) = SnapEngine.shared.snappedOrigin(
                for: win,
                proposedOrigin: unsnappedOrigin,
                size: win.frame.size
            )
            win.setFrameOrigin(snapped)

            if let screen = win.screen ?? NSScreen.main {
                SnapGuideOverlay.shared.show(guides, on: screen)
            }

        case .resizeBottomRight:
            let desiredW = max(minSize, mouse.x - anchorPoint.x)
            let newW = desiredW
            let newH = newW / aspectRatio
            let newX = anchorPoint.x
            let newY = anchorPoint.y - newH
            applyFrame(NSRect(x: newX, y: newY, width: newW, height: newH), to: win)

        case .resizeBottomLeft:
            let desiredW = max(minSize, anchorPoint.x - mouse.x)
            let newW = desiredW
            let newH = newW / aspectRatio
            let newX = anchorPoint.x - newW
            let newY = anchorPoint.y - newH
            applyFrame(NSRect(x: newX, y: newY, width: newW, height: newH), to: win)

        case .resizeTopRight:
            let desiredW = max(minSize, mouse.x - anchorPoint.x)
            let newW = desiredW
            let newH = newW / aspectRatio
            let newX = anchorPoint.x
            let newY = anchorPoint.y
            applyFrame(NSRect(x: newX, y: newY, width: newW, height: newH), to: win)

        case .resizeTopLeft:
            let desiredW = max(minSize, anchorPoint.x - mouse.x)
            let newW = desiredW
            let newH = newW / aspectRatio
            let newX = anchorPoint.x - newW
            let newY = anchorPoint.y
            applyFrame(NSRect(x: newX, y: newY, width: newW, height: newH), to: win)

        case .none:
            break
        }
    }

    private func applyFrame(_ rect: NSRect, to win: NSWindow) {
        win.setFrame(rect, display: true)
        updateLayout(rect.size)
    }

    override func mouseUp(with event: NSEvent) {
        SnapGuideOverlay.shared.hide()

        if isLocked { return }
        guard let win = window else { return }

        // Save position
        NotificationCenter.default.post(name: .desktopPhotoMoved, object: win)

        // If we were resizing, report the new width
        if dragMode != .move && dragMode != .none {
            onResizeFinished?(win.frame.width)
        }
        dragMode = .none
    }

    // MARK: - Scroll wheel → opacity

    override func scrollWheel(with event: NSEvent) {
        guard !isLocked else { return }
        let delta = event.deltaY * 0.02
        guard let currentAlpha = window?.contentView?.alphaValue else { return }
        let newAlpha = max(0.1, min(1.0, currentAlpha + delta))
        window?.contentView?.alphaValue = newAlpha
        onOpacityChanged?(newAlpha)
    }

    // MARK: - Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let lockItem = NSMenuItem(
            title: isLocked ? "Unlock Position" : "Lock Position",
            action: #selector(handleLockToggle),
            keyEquivalent: ""
        )
        lockItem.target = self
        menu.addItem(lockItem)

        menu.addItem(.separator())

        let removeItem = NSMenuItem(
            title: "Remove from Desktop",
            action: #selector(handleRemove),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func handleLockToggle() { onLockToggle?() }
    @objc private func handleRemove() { onRemove?() }

    // MARK: - Lock flash

    func flashLockState(_ locked: Bool) {
        let size: CGFloat = 48
        let indicator = NSView(frame: NSRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size, height: size
        ))
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        indicator.layer?.cornerRadius = 12

        let sym = NSImageView(frame: NSRect(x: 8, y: 8, width: 32, height: 32))
        sym.image = NSImage(
            systemSymbolName: locked ? "lock.fill" : "lock.open.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
        sym.contentTintColor = .white
        indicator.addSubview(sym)
        addSubview(indicator)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                indicator.animator().alphaValue = 0
            } completionHandler: { indicator.removeFromSuperview() }
        }
    }

    // MARK: - Standard overrides

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

// MARK: - Notification

extension Notification.Name {
    static let desktopPhotoMoved = Notification.Name("desktopPhotoMoved")
}
