import AppKit
import SwiftUI
import QuartzCore

// MARK: - Canvas geometry

/// How much room a widget's window reserves *around* the photo.
///
/// Shadows spill outside the photo's silhouette and a tilted photo sweeps a larger bounding
/// box; anything drawn outside the window is clipped by the WindowServer along the window's
/// straight edges. This used to be handled by shrinking the content inside a window sized to
/// the photo, which had two bugs: `insetBy(dx:dy:)` takes the same amount off both axes, so a
/// non-square photo came out with a different aspect ratio and the `resizeAspectFill` image
/// layer silently cropped it (7% of a 300x517 widget at default settings, 37% of a panorama
/// at max blur); and the reserved room was capped at 22% of the short side, which is less
/// than a 12-degree tilt needs, so corners were cut off by the window edge anyway.
///
/// Reserving the room outside the photo instead keeps the photo's aspect ratio exact and has
/// no upper bound to hit. The window is no longer the photo — see `DesktopPhotoWindow.photoFrame`.
enum PhotoCanvas {
    /// Padding on each side of the window, outside the photo's own rect.
    static func inset(
        photoSize: CGSize,
        shadowEnabled: Bool,
        shadowBlur: CGFloat,
        matWidth: CGFloat,
        tiltDegrees: CGFloat
    ) -> CGFloat {
        // The mat is drawn outward from the photo — a passe-partout physically enlarges a
        // framed print — so it is the first thing the window has to make room for. Drawing it
        // inward is what forced the old equal-inset aspect-ratio bug.
        var width = photoSize.width + matWidth * 2
        var height = photoSize.height + matWidth * 2

        // The furthest a shadow pixel lands from the silhouette: the ambient layer's blur
        // radius plus the offset it is pushed down by. See applyShadowLayers.
        let shadowSpill = shadowEnabled ? shadowBlur * 1.4 + min(10, shadowBlur * 0.5) : 0
        width += shadowSpill * 2
        height += shadowSpill * 2

        // Summed, not maxed: whenever tilt needed more room than the shadow, taking the larger
        // of the two left the rotated content exactly touching the window edge, so the entire
        // shadow then fell outside it and was clipped.
        return matWidth + shadowSpill + halfBoundingGrowth(width: width, height: height, degrees: tiltDegrees)
    }

    /// Half the growth of a rect's axis-aligned bounding box once rotated — i.e. the room each
    /// side needs, given the content is rotated about its centre.
    private static func halfBoundingGrowth(width: CGFloat, height: CGFloat, degrees: CGFloat) -> CGFloat {
        guard degrees != 0 else { return 0 }
        let rad = abs(degrees) * .pi / 180
        let rotatedW = width * cos(rad) + height * sin(rad)
        let rotatedH = width * sin(rad) + height * cos(rad)
        return max(rotatedW - width, rotatedH - height) / 2
    }
}

// MARK: - Depth

/// Where a widget sits in the desktop's window stack.
///
/// The stack, measured on macOS 27: wallpaper at −2147483624, Finder's desktop icons at
/// −2147483603 (all of them, in one screen-sized window), Tableau at −2147483602, and the
/// system's own desktop widgets at −2147483601. That last one is why an overlapping Sonoma
/// widget always drew on top of a photo — Tableau was one level short.
enum WidgetDepth: String, Codable, CaseIterable {
    /// Below Finder's desktop icons. Icons stay readable over the photo — but Finder's desktop
    /// window spans the whole screen and is not click-through, so it swallows every event
    /// before it can reach us. A widget here cannot be dragged, resized or right-clicked at
    /// all, which is why selecting it also locks the widget (see PhotoManager.setDepth).
    case behindIcons
    /// Above desktop icons, below the system's desktop widgets. The historical default.
    case onDesktop
    /// Above the system's desktop widgets too, but still behind every ordinary app window.
    case aboveWidgets
    /// Above ordinary app windows.
    case floating

    var displayName: String {
        switch self {
        case .behindIcons: return "Behind Icons"
        case .onDesktop: return "On Desktop"
        case .aboveWidgets: return "Above Widgets"
        case .floating: return "Floating"
        }
    }

    /// A one-line caveat, or nil when the mode does what its name says without qualification.
    var caveat: String? {
        switch self {
        case .behindIcons:
            return "Desktop icons draw over the photo. It can't be dragged or clicked here, so it stays locked."
        case .onDesktop, .aboveWidgets, .floating:
            return nil
        }
    }

    var windowLevel: NSWindow.Level {
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        switch self {
        case .behindIcons: return NSWindow.Level(rawValue: icons - 1)
        case .onDesktop: return NSWindow.Level(rawValue: icons + 1)
        case .aboveWidgets: return NSWindow.Level(rawValue: icons + 3)
        case .floating: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        }
    }

    /// Whether the widget can receive mouse events at this depth at all.
    var isInteractive: Bool { self != .behindIcons }
}

/// A borderless, always-on-desktop panel that displays a photo.
///
/// The window frame is a *canvas*: the photo's own rect inset outward by `canvasInset` (see
/// `PhotoCanvas`). Everything user-facing — the persisted frame, snapping, resize handles —
/// works in photo coordinates, never window coordinates.
///
/// An `NSPanel` with `.nonactivatingPanel`, not a plain `NSWindow`. Clicking an ordinary
/// window activates its application, whatever `canBecomeKey` says — so dragging a widget used
/// to pull Tableau to the front, hand it the menu bar, and leave it there. A non-activating
/// panel takes mouse events without ever making the app active, which is the only way a
/// desktop ornament can be interactive without being intrusive.
class DesktopPhotoWindow: NSPanel {
    var photoId: UUID?
    var onLockToggle: (() -> Void)?
    var onRemove: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onClickAdvance: (() -> Void)?
    var onBringToFront: (() -> Void)?
    var onSendToBack: (() -> Void)?

    /// Padding between the window frame and the photo rect, on every side.
    private(set) var canvasInset: CGFloat = 0

    init() {
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = WidgetDepth.onDesktop.windowLevel
        isOpaque = false
        backgroundColor = .clear
        // Shadows are two custom CALayers on the container now (contact + ambient), not the
        // system window shadow -- see applyShadowSettings.
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false

        // Without this the window receives no mouseMoved events at all, even with a tracking
        // area that asks for them — installing the tracking area does not set this for you.
        // That is why the resize crosshair never appeared: mouseEntered fired, mouseMoved
        // never did, so the cursor was never changed.
        acceptsMouseMovedEvents = true
    }

    /// A widget never needs keyboard focus — it has no text field and no key equivalents of
    /// its own — and taking key status is what put Tableau's menu bar on screen in place of
    /// whatever the user was actually working in. Mouse events do not require it.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Photo rect vs window frame

    /// The photo's own rect in screen coordinates. This is what gets persisted, snapped and
    /// resized; the window frame is this outset by `canvasInset`.
    ///
    /// Stored rather than derived from `frame`. Deriving it round-trips through the window
    /// server, which rounds window frames to device pixels — so every save/restore cycle put
    /// back a slightly different size than the one that went in, and the widget grew by a
    /// fraction of a point on each launch (measured: 300 -> 300.06 -> 301.01).
    private(set) var photoFrame: NSRect = .zero

    /// The outermost opaque edge — the mat if there is one, otherwise the photo. What the user
    /// actually sees the boundary of, and therefore what alignment guides must land on.
    var visualFrame: NSRect {
        let mat = (contentView as? DraggablePhotoView)?.matInset ?? 0
        return photoFrame.insetBy(dx: -mat, dy: -mat)
    }

    func windowFrame(forPhoto rect: NSRect) -> NSRect {
        rect.insetBy(dx: -canvasInset, dy: -canvasInset)
    }

    /// Positions and sizes the *photo*, growing the window around it.
    ///
    /// The padding is re-derived from the rect being set rather than reused, since the amount
    /// of room a tilt needs depends on the photo's dimensions — restoring a saved frame at a
    /// different size than the window was built with would otherwise keep a stale inset and
    /// put the photo slightly off where it was saved.
    func setPhotoFrame(_ rect: NSRect, display: Bool = true) {
        if let container = contentView as? DraggablePhotoView {
            canvasInset = container.requiredCanvasInset(photoSize: rect.size)
            container.canvasInset = canvasInset
        }
        photoFrame = rect
        let target = windowFrame(forPhoto: rect)
        setFrame(target, display: display)
        (contentView as? DraggablePhotoView)?.updateLayout(target.size)
    }

    /// Moves the photo without touching its size — the drag path, where re-deriving the size
    /// from the window frame on every event is exactly what accumulates rounding error.
    func setPhotoOrigin(_ origin: NSPoint) {
        photoFrame.origin = origin
        setFrameOrigin(windowFrame(forPhoto: photoFrame).origin)
    }

    /// Re-derives the padding after an appearance change, holding the photo rect fixed so the
    /// photo does not appear to move when a shadow, mat or tilt is adjusted.
    func refreshCanvasInset() {
        setPhotoFrame(photoFrame)
    }

    func showPhoto(_ content: PhotoContent, baseWidth: CGFloat = 300, locked: Bool = false, settings: PhotoItem? = nil) {
        let imageSize = content.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let aspectRatio = imageSize.width / imageSize.height
        let photoSize = NSSize(width: baseWidth, height: baseWidth / aspectRatio)

        canvasInset = PhotoCanvas.inset(
            photoSize: photoSize,
            shadowEnabled: settings?.shadowEnabled ?? true,
            shadowBlur: settings?.shadowBlur ?? 10,
            matWidth: settings?.matWidth ?? 0,
            tiltDegrees: CGFloat(settings?.tiltDegrees ?? 0)
        )

        let canvasSize = NSSize(
            width: photoSize.width + canvasInset * 2,
            height: photoSize.height + canvasInset * 2
        )

        let container = DraggablePhotoView(
            frame: NSRect(origin: .zero, size: canvasSize),
            content: content,
            locked: locked,
            canvasInset: canvasInset,
            settings: settings
        )
        container.onLockToggle = { [weak self] in self?.onLockToggle?() }
        container.onRemove = { [weak self] in self?.onRemove?() }
        container.onResizeFinished = { [weak self] newWidth in self?.onResize?(newWidth) }
        container.onOpacityChanged = { [weak self] newOpacity in self?.onOpacityChanged?(newOpacity) }
        container.onBringToFront = { [weak self] in self?.onBringToFront?() }
        container.onSendToBack = { [weak self] in self?.onSendToBack?() }

        contentView = container
        setContentSize(canvasSize)
        photoFrame = frame.insetBy(dx: canvasInset, dy: canvasInset)

        // Lay out synchronously before the window is ordered in, so the first frame
        // drawn is already the right size rather than snapping into place.
        //
        // This used to also call disableScreenUpdatesUntilFlush(), which Apple
        // deprecated in macOS 15 and documents as doing nothing at all. Keeping it
        // implied a guarantee that has not held for two releases; the synchronous
        // layout below is what actually prevents the flicker.
        container.updateLayout(canvasSize)

        // Apply settings
        if let s = settings {
            setDepth(s.depth)
            setPhotoOpacity(s.opacity)
        }

        // orderFront, never makeKeyAndOrderFront: showing a widget must not pull the app to
        // the front. Every launch used to activate Tableau once per visible widget.
        orderFront(nil)
    }

    func hidePhoto() {
        // Strip any in-flight CATransition animations to prevent stale callbacks
        if let container = contentView as? DraggablePhotoView {
            container.layer?.removeAllAnimations()
            container.imageLayer.removeAllAnimations()
            // Also tear down GIF playback explicitly rather than relying on
            // removeAllAnimations() alone -- it clears the render-server
            // side, but stopAnimating() also drops our tracked frame data
            // so a stray delayed "start playback" block (see swapImage)
            // can't resurrect it on a view that's going away.
            container.photoLayer.stopAnimating()
        }

        // A closed widget window stays in NSApp.windows for the life of the process
        // (isReleasedWhenClosed is false on purpose, to prevent a use-after-free on re-show).
        // Clearing the id stops any lookup that scans NSApp.windows from resolving to this
        // corpse instead of the replacement window a later show() creates.
        photoId = nil
        close()
    }

    func setLocked(_ locked: Bool) {
        (contentView as? DraggablePhotoView)?.isLocked = locked
    }

    func resizeTo(width: CGFloat) {
        guard let container = contentView as? DraggablePhotoView,
              let image = container.photoImage else { return }
        // photoImage is always a representative still (even for animated
        // content -- see PhotoImageLayer.image), so aspect-ratio math
        // here needs no animated-specific branch.
        let ar = image.size.width / image.size.height
        let photo = photoFrame
        let newPhoto = NSRect(x: photo.origin.x, y: photo.origin.y, width: width, height: width / ar)
        canvasInset = container.requiredCanvasInset(photoSize: newPhoto.size)
        container.canvasInset = canvasInset
        photoFrame = newPhoto
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(self.windowFrame(forPhoto: newPhoto), display: true)
        }
        container.updateLayout(windowFrame(forPhoto: newPhoto).size)
    }

    // MARK: - Depth

    func setDepth(_ depth: WidgetDepth) {
        level = depth.windowLevel
        // A widget behind Finder's desktop window can never be clicked, so there is no reason
        // to keep hit-testing it — and letting go of the events means the desktop underneath
        // behaves exactly as it would with no widget there.
        ignoresMouseEvents = !depth.isInteractive
        hidesOnDeactivate = false
    }

    func setPhotoOpacity(_ value: CGFloat) {
        contentView?.alphaValue = max(0.1, min(1.0, value))
    }

    // MARK: - v1.3 / v2.1 Shadow

    /// The system window shadow (`hasShadow`) is a single, fixed-look shadow that AppKit
    /// draws outside the window's own frame -- convenient in that it's never clipped, but it
    /// can't be split into a tight contact shadow plus a wide ambient one, which is what
    /// actually reads as elevation. So it stays off permanently, and both shadows are
    /// rendered as CALayers on the container instead (see DraggablePhotoView.relayout).
    func applyShadowSettings(enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        hasShadow = false
        (contentView as? DraggablePhotoView)?.setShadowLayers(enabled: enabled, blur: blur, opacity: opacity)
        refreshCanvasInset()
    }

    // MARK: - Smooth image swap (CATransition crossfade + dynamic frame)

    private static let crossfadeDuration: TimeInterval = 0.35

    func swapImage(_ content: PhotoContent, targetFrame: NSRect? = nil, mode: String = "dynamic", animate: Bool = true) {
        guard let container = contentView as? DraggablePhotoView else { return }
        let newSize = content.size
        let newAR = newSize.width / newSize.height

        if mode == "dynamic" {
            container.aspectRatio = newAR
        }

        // Determine the target *photo* rect. Callers persist and pass photo rects, never
        // window frames — the padding is re-derived here.
        let photo = photoFrame
        let newPhoto: NSRect
        if mode == "fixed" {
            newPhoto = photo // don't change size
        } else if let target = targetFrame, target.width > 0 {
            newPhoto = target
        } else {
            // Keep current width, adjust height for new aspect ratio. Pin top-left.
            let newH = photo.width / newAR
            newPhoto = NSRect(x: photo.origin.x, y: photo.maxY - newH, width: photo.width, height: newH)
        }

        canvasInset = container.requiredCanvasInset(photoSize: newPhoto.size)
        container.canvasInset = canvasInset
        photoFrame = newPhoto
        let newFrame = windowFrame(forPhoto: newPhoto)

        if animate {
            // GPU-accelerated crossfade via Core Animation
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Self.crossfadeDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            container.imageLayer.add(transition, forKey: kCATransition)
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
        container.photoLayer.apply(content, animationStartDelay: animate ? Self.crossfadeDuration : 0)

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

// MARK: - Photo image layer

/// Owns the CALayer that shows the photo, including GIF/APNG playback.
///
/// This used to be an NSView. It never handled an event — the container's `hitTest` always
/// returned the container — and being a view forced an awkward second overlay *view* to get
/// the border and vignette above it, because a subview's backing layer always composites over
/// its superview's own manual sublayers regardless of insertion order. As a plain layer it
/// takes its place in one sublayer array, so z-order is just array order, and it can live
/// inside a layer we rotate ourselves.
final class PhotoImageLayer {
    private static let gifAnimationKey = "gifPlayback"

    let layer = CALayer()

    /// A representative still (first frame, for animated content) kept in
    /// sync at all times so aspect-ratio/size math elsewhere (resizeTo,
    /// DraggablePhotoView.photoImage) doesn't need to know or care whether
    /// playback is currently animated.
    private(set) var image: NSImage?

    /// Non-nil while a GIF-style animation is actively driving `layer.contents`.
    private(set) var animatedFrames: AnimatedImageFrames?

    /// Bumped on every `apply(_:)` call. A deferred playback-start closure
    /// captures the generation it was scheduled under and checks it before
    /// installing the CAKeyframeAnimation, so a rapid-fire Space rotation
    /// (swap A, then swap B before A's crossfade finishes) can't let A's
    /// delayed animation clobber B's content after the fact.
    private var generation = 0

    init() {
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
    }

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
        layer.contents = newImage
    }

    private func setAnimated(_ frames: AnimatedImageFrames, representativeImage: NSImage, startDelay: TimeInterval) {
        stopAnimating()
        image = representativeImage
        // Show frame 0 right away so there's always something on screen,
        // even before (or if) the keyframe animation below installs.
        layer.contents = frames.images.first
        guard frames.images.count > 1 else { return }
        animatedFrames = frames

        generation += 1
        let expectedGeneration = generation
        let install: () -> Void = { [weak self] in
            // Bail if a newer `apply(_:)` call superseded us while this was
            // pending -- see the stale-callback discipline documented on
            // hidePhoto().
            guard let self, self.generation == expectedGeneration else { return }
            self.layer.add(frames.makeContentsAnimation(), forKey: Self.gifAnimationKey)
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
        layer.removeAnimation(forKey: Self.gifAnimationKey)
        animatedFrames = nil
    }
}

// MARK: - Draggable Photo View

class DraggablePhotoView: NSView {
    let photoLayer = PhotoImageLayer()

    /// Everything the user sees, parented under one layer we own outright.
    ///
    /// Tilt lives here rather than on `self.layer`. An NSView's backing layer is AppKit's:
    /// writing `transform` on it is silently reset to identity on the first display pass and
    /// again on every resize (measured), which is why a saved tilt vanished on relaunch. It
    /// also has `anchorPoint = (0, 0)`, so a rotation about "the centre" actually pivoted
    /// about the bottom-left corner and threw the photo out of the window. A layer we create
    /// ourselves keeps its transform and lets us set the anchor point.
    private let contentLayer = CALayer()

    var imageLayer: CALayer { photoLayer.layer }
    var photoImage: NSImage? { photoLayer.image }
    var isLocked = false {
        didSet { if isLocked != oldValue { updateHandles() } }
    }

    var onLockToggle: (() -> Void)?
    var onRemove: (() -> Void)?
    var onResizeFinished: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onClickAdvance: (() -> Void)?
    var onBringToFront: (() -> Void)?
    var onSendToBack: (() -> Void)?
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

    /// Padding between the window's edge and the photo. Mirrors the window's own value.
    var canvasInset: CGFloat

    private let handleZone: CGFloat = 16
    private let minSize: CGFloat = 80
    private var isHovering = false

    // v1.3 — Aesthetic layers
    private var borderLayer: CAShapeLayer?
    private var vignetteLayer: CALayer?

    // v2.1 — Borders, frames & depth
    private var matLayer: CAShapeLayer?
    private var borderGradientLayer: CAGradientLayer?
    private var contactShadowLayer: CAShapeLayer?
    private var ambientShadowLayer: CAShapeLayer?
    private var handleLayers: [CALayer] = []
    private var matWidth: CGFloat = 0
    private var matColor: NSColor = .white
    private var shapeMask: PhotoShapeMask = .roundedRect
    private var currentBorderWidth: CGFloat = 0
    private var currentBorderColor: NSColor = .white
    private var borderStyle: PhotoBorderStyle = .solid
    private var borderGradientEnabled = false
    private var borderGradientColor: NSColor = .black
    private var tiltDegrees: CGFloat = 0
    private var shadowEnabledFlag = true
    private var shadowBlurBase: CGFloat = 10
    private var shadowOpacityBase: CGFloat = 0.3
    private var vignetteEnabledFlag = false

    /// The mat's width, so the window can report the outermost opaque edge.
    var matInset: CGFloat { matWidth }

    init(frame: NSRect, content: PhotoContent, locked: Bool, canvasInset: CGFloat, settings: PhotoItem? = nil) {
        self.canvasInset = canvasInset
        self.isLocked = locked
        self.aspectRatio = content.size.width / content.size.height

        super.init(frame: frame)

        wantsLayer = true

        // Seed every appearance property from `settings` before the first relayout, so the
        // first frame drawn already reflects mat/shape/border/shadow/tilt instead of
        // snapping into place a moment later.
        baseCornerRadius = settings?.cornerRadius ?? 16
        shadowEnabledFlag = settings?.shadowEnabled ?? true
        shadowBlurBase = settings?.shadowBlur ?? 10
        shadowOpacityBase = settings?.shadowOpacity ?? 0.3
        currentBorderWidth = settings?.borderWidth ?? 0
        currentBorderColor = settings?.borderColor ?? .white
        borderStyle = PhotoBorderStyle(rawValue: settings?.borderStyle ?? "solid") ?? .solid
        borderGradientEnabled = settings?.borderGradientEnabled ?? false
        borderGradientColor = settings?.borderGradientColor ?? .black
        matWidth = settings?.matWidth ?? 0
        matColor = settings?.matColor ?? .white
        shapeMask = PhotoShapeMask(rawValue: settings?.shapeMask ?? "roundedRect") ?? .roundedRect
        tiltDegrees = CGFloat(settings?.tiltDegrees ?? 0)
        vignetteEnabledFlag = settings?.vignetteEnabled ?? false

        layer?.addSublayer(contentLayer)
        contentLayer.addSublayer(photoLayer.layer)
        photoLayer.apply(content)

        relayout()

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateLayout(_ size: NSSize) {
        frame = NSRect(origin: .zero, size: size)
        relayout()
    }

    /// The padding this photo's current appearance settings require.
    func requiredCanvasInset(photoSize: CGSize) -> CGFloat {
        PhotoCanvas.inset(
            photoSize: photoSize,
            shadowEnabled: shadowEnabledFlag,
            shadowBlur: shadowBlurBase,
            matWidth: matWidth,
            tiltDegrees: tiltDegrees
        )
    }

    // MARK: - Geometry

    /// The photo's rect in this view's coordinates. Exactly the photo's aspect ratio — the
    /// window grew to accommodate shadow and tilt rather than the photo shrinking to make room.
    private var photoRect: NSRect {
        bounds.insetBy(dx: canvasInset, dy: canvasInset)
    }

    /// Photo plus mat: the outermost opaque edge, and the rect the user grabs.
    private var visualRect: NSRect {
        photoRect.insetBy(dx: -matWidth, dy: -matWidth)
    }

    // MARK: - Unified layout

    /// Everything drawn -- image mask, mat, shadows, border, vignette, tilt -- funnels
    /// through here so they are always derived from the same current state and in the same
    /// order, rather than several call sites each keeping their own notion of "the shape" in
    /// sync after a resize.
    private func relayout() {
        let outer = visualRect
        guard outer.width > 0, outer.height > 0 else { return }

        // Sublayers are positioned in contentLayer's own coordinates, so the rotation below
        // is the only thing that has to know where on screen any of this ends up.
        let local = CGRect(origin: .zero, size: outer.size)
        let inner = local.insetBy(dx: matWidth, dy: matWidth)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.bounds = local
        contentLayer.position = CGPoint(x: outer.midX, y: outer.midY)
        contentLayer.transform = tiltDegrees == 0
            ? CATransform3DIdentity
            : CATransform3DMakeRotation(tiltDegrees * .pi / 180, 0, 0, 1)

        let outerRadius = min(baseCornerRadius, min(local.width, local.height) * 0.5)
        let innerRadius = min(baseCornerRadius, min(inner.width, inner.height) * 0.5)

        applyShadowLayers(outer: local, cornerRadius: outerRadius)
        applyMatLayer(outer: local, cornerRadius: outerRadius)
        applyImageLayer(inner: inner, cornerRadius: innerRadius)
        applyVignetteLayer(inner: inner, cornerRadius: innerRadius)
        applyBorderLayers(outer: local, cornerRadius: outerRadius)
        applyHandleLayers(outer: local)

        CATransaction.commit()
    }

    private func applyImageLayer(inner: NSRect, cornerRadius: CGFloat) {
        let img = photoLayer.layer
        img.frame = inner
        let local = CGRect(origin: .zero, size: inner.size)
        switch shapeMask {
        case .roundedRect:
            img.mask = nil
            img.cornerRadius = cornerRadius
            img.cornerCurve = .continuous
        case .circle, .squircle, .arch:
            img.cornerRadius = 0
            let maskLayer = CAShapeLayer()
            maskLayer.frame = local
            maskLayer.path = shapeMask.path(in: local, cornerRadius: cornerRadius)
            maskLayer.fillColor = NSColor.black.cgColor
            img.mask = maskLayer
        }
        // No reordering here on purpose: the image layer is the one layer that persists across
        // relayouts (it owns any running GIF animation), so everything else is positioned
        // relative to it — shadows and mat below, vignette and border above.
    }

    private func makeShadowLayer() -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = NSColor.clear.cgColor
        return l
    }

    /// A tight contact shadow plus a wide, soft ambient one -- two shadows read as real
    /// elevation, where one blurred drop shadow reads as flat. Both derive their path from
    /// `shapeMask`, so a circle or arch casts a shadow shaped like itself rather than a
    /// leftover rectangle.
    private func applyShadowLayers(outer: NSRect, cornerRadius: CGFloat) {
        ambientShadowLayer?.removeFromSuperlayer()
        contactShadowLayer?.removeFromSuperlayer()
        guard shadowEnabledFlag else {
            ambientShadowLayer = nil
            contactShadowLayer = nil
            return
        }

        let path = shapeMask.path(in: outer, cornerRadius: cornerRadius)

        let ambient = makeShadowLayer()
        ambient.frame = outer
        ambient.path = path
        ambient.shadowPath = path
        ambient.shadowColor = NSColor.black.cgColor
        ambient.shadowOpacity = Float(min(shadowOpacityBase * 0.7, 1.0))
        ambient.shadowRadius = max(2, shadowBlurBase * 1.4)
        ambient.shadowOffset = CGSize(width: 0, height: -min(10, shadowBlurBase * 0.5))
        contentLayer.insertSublayer(ambient, below: photoLayer.layer)
        ambientShadowLayer = ambient

        let contact = makeShadowLayer()
        contact.frame = outer
        contact.path = path
        contact.shadowPath = path
        contact.shadowColor = NSColor.black.cgColor
        contact.shadowOpacity = Float(min(shadowOpacityBase * 1.1, 1.0))
        contact.shadowRadius = max(1, shadowBlurBase * 0.25)
        contact.shadowOffset = CGSize(width: 0, height: -min(3, shadowBlurBase * 0.15))
        // Each "below the image" insert lands directly under it, so this second one ends up
        // the closer of the two and ambient stays furthest back.
        contentLayer.insertSublayer(contact, below: photoLayer.layer)
        contactShadowLayer = contact
    }

    /// The passe-partout: a solid border of colour around the image, drawn *outward* so the
    /// image keeps its exact aspect ratio (a mounted print is bigger than the print).
    private func applyMatLayer(outer: NSRect, cornerRadius: CGFloat) {
        matLayer?.removeFromSuperlayer()
        guard matWidth > 0 else {
            matLayer = nil
            return
        }
        let mat = CAShapeLayer()
        mat.frame = outer
        mat.path = shapeMask.path(in: CGRect(origin: .zero, size: outer.size), cornerRadius: cornerRadius)
        mat.fillColor = matColor.cgColor
        // Directly behind the image, in front of both shadows.
        contentLayer.insertSublayer(mat, below: photoLayer.layer)
        matLayer = mat
    }

    /// Darkens the photo's edges and corners.
    ///
    /// Not a CAGradientLayer any more: a `.radial` gradient paints nothing beyond the ellipse
    /// its endpoint describes, so the previous version drew a dark ring *inside* the photo and
    /// left all four corners untouched — the inverse of a vignette. A shape layer with an even-odd
    /// path (photo rect minus an inset rounded rect) shaded by a soft shadow gets the corners.
    private func applyVignetteLayer(inner: NSRect, cornerRadius: CGFloat) {
        vignetteLayer?.removeFromSuperlayer()
        guard vignetteEnabledFlag, inner.width > 0, inner.height > 0 else {
            vignetteLayer = nil
            return
        }

        let local = CGRect(origin: .zero, size: inner.size)
        let feather = min(local.width, local.height) * 0.28

        let ring = CAShapeLayer()
        ring.frame = inner
        let path = CGMutablePath()
        path.addPath(shapeMask.path(in: local, cornerRadius: cornerRadius))
        path.addPath(shapeMask.path(in: local.insetBy(dx: feather, dy: feather), cornerRadius: cornerRadius))
        ring.path = path
        ring.fillRule = .evenOdd
        ring.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
        // Blurring the ring inward is what makes it read as a fade rather than a dark frame.
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.5
        ring.shadowRadius = feather * 0.6
        ring.shadowOffset = .zero
        ring.shadowPath = path

        // Clip to the photo's silhouette so the blur can't bleed onto the mat.
        let clip = CAShapeLayer()
        clip.frame = CGRect(origin: .zero, size: inner.size)
        clip.path = shapeMask.path(in: local, cornerRadius: cornerRadius)
        clip.fillColor = NSColor.black.cgColor
        ring.mask = clip

        // Appended, so it stacks above the image; the border is appended after it.
        contentLayer.addSublayer(ring)
        vignetteLayer = ring
    }

    /// Solid, dashed or dotted; flat colour or a linear gradient sweep. The gradient case
    /// reuses the stroke shape as a mask (fillColor clear, opaque stroke) so the gradient
    /// layer only paints where the stroke actually is.
    private func applyBorderLayers(outer: NSRect, cornerRadius: CGFloat) {
        borderLayer?.removeFromSuperlayer()
        borderGradientLayer?.removeFromSuperlayer()
        guard currentBorderWidth > 0 else {
            borderLayer = nil
            borderGradientLayer = nil
            return
        }

        let local = CGRect(origin: .zero, size: outer.size)
        let strokeRect = local.insetBy(dx: currentBorderWidth / 2, dy: currentBorderWidth / 2)
        let path = shapeMask.path(in: strokeRect, cornerRadius: max(0, cornerRadius - currentBorderWidth / 2))

        let stroke = CAShapeLayer()
        stroke.frame = outer
        stroke.path = path
        stroke.fillColor = nil
        stroke.lineWidth = currentBorderWidth
        switch borderStyle {
        case .solid:
            stroke.lineDashPattern = nil
            stroke.lineCap = .butt
        case .dashed:
            stroke.lineDashPattern = [(currentBorderWidth * 3) as NSNumber, (currentBorderWidth * 2) as NSNumber]
            stroke.lineCap = .butt
        case .dotted:
            stroke.lineDashPattern = [0.01, (currentBorderWidth * 2.2)] as [NSNumber]
            stroke.lineCap = .round
        }

        if borderGradientEnabled {
            stroke.strokeColor = NSColor.black.cgColor // opaque alpha; colour comes from the gradient
            let gradient = CAGradientLayer()
            gradient.frame = outer
            gradient.colors = [currentBorderColor.cgColor, borderGradientColor.cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            gradient.mask = stroke
            contentLayer.addSublayer(gradient)
            borderGradientLayer = gradient
            borderLayer = nil
        } else {
            stroke.strokeColor = currentBorderColor.cgColor
            contentLayer.addSublayer(stroke)
            borderLayer = stroke
            borderGradientLayer = nil
        }
    }

    // MARK: - Resize handles

    /// Four corner grips, shown only while the pointer is over an unlocked widget.
    ///
    /// A cursor change alone was the entire affordance before, and it never fired — the window
    /// was not accepting mouseMoved events at all. Even once it does, a cursor is a poor signal
    /// for a borderless object with no chrome: there is nothing on screen to tell you the
    /// corners are draggable until you happen to hover one.
    private func applyHandleLayers(outer: NSRect) {
        handleLayers.forEach { $0.removeFromSuperlayer() }
        handleLayers = []
        guard isHovering, !isLocked else { return }

        let size: CGFloat = 10
        let corners = [
            CGPoint(x: outer.minX, y: outer.minY),
            CGPoint(x: outer.maxX, y: outer.minY),
            CGPoint(x: outer.minX, y: outer.maxY),
            CGPoint(x: outer.maxX, y: outer.maxY)
        ]
        for corner in corners {
            let dot = CALayer()
            dot.frame = CGRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = NSColor.white.cgColor
            dot.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            dot.borderWidth = 1
            dot.shadowColor = NSColor.black.cgColor
            dot.shadowOpacity = 0.35
            dot.shadowRadius = 2
            dot.shadowOffset = CGSize(width: 0, height: -1)
            contentLayer.addSublayer(dot)
            handleLayers.append(dot)
        }
    }

    private func updateHandles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyHandleLayers(outer: CGRect(origin: .zero, size: visualRect.size))
        CATransaction.commit()
    }

    // MARK: - Aesthetic Controls

    func setCornerRadius(_ radius: CGFloat) {
        baseCornerRadius = radius
        relayout()
    }

    func applyBorder(width: CGFloat, color: NSColor) {
        currentBorderWidth = width
        currentBorderColor = color
        relayout()
    }

    func applyVignette() {
        vignetteEnabledFlag = true
        relayout()
    }

    func removeVignette() {
        vignetteEnabledFlag = false
        relayout()
    }

    /// Called by DesktopPhotoWindow.applyShadowSettings, which owns turning off the
    /// system window shadow in favour of the two layers built in applyShadowLayers.
    func setShadowLayers(enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        shadowEnabledFlag = enabled
        shadowBlurBase = blur
        shadowOpacityBase = opacity
        relayout()
    }

    func setMat(width: CGFloat, color: NSColor) {
        matWidth = max(0, width)
        matColor = color
        relayout()
    }

    func setShapeMask(_ shape: PhotoShapeMask) {
        shapeMask = shape
        relayout()
    }

    func setBorderStyle(_ style: PhotoBorderStyle) {
        borderStyle = style
        relayout()
    }

    func setBorderGradient(enabled: Bool, color: NSColor) {
        borderGradientEnabled = enabled
        borderGradientColor = color
        relayout()
    }

    func setTilt(_ degrees: CGFloat) {
        tiltDegrees = max(-12, min(12, degrees))
        relayout()
    }

    // MARK: - Hit zones

    /// Converts a point in view coordinates into the tilted content's own frame, so the corner
    /// grips stay grabbable where they are actually drawn rather than where an unrotated rect
    /// would put them.
    private func pointInContent(_ p: NSPoint) -> NSPoint {
        let outer = visualRect
        let centre = NSPoint(x: outer.midX, y: outer.midY)
        let dx = p.x - centre.x
        let dy = p.y - centre.y
        guard tiltDegrees != 0 else {
            return NSPoint(x: dx + outer.width / 2, y: dy + outer.height / 2)
        }
        let rad = -tiltDegrees * .pi / 180
        return NSPoint(
            x: dx * cos(rad) - dy * sin(rad) + outer.width / 2,
            y: dx * sin(rad) + dy * cos(rad) + outer.height / 2
        )
    }

    private func modeAt(_ localPoint: NSPoint) -> DragMode {
        let outer = visualRect
        let p = pointInContent(localPoint)
        let h = handleZone

        guard p.x > -h, p.y > -h, p.x < outer.width + h, p.y < outer.height + h else { return .none }

        let nearLeft = p.x < h
        let nearRight = p.x > outer.width - h
        let nearBottom = p.y < h
        let nearTop = p.y > outer.height - h

        if nearBottom && nearLeft { return .resizeBottomLeft }
        if nearBottom && nearRight { return .resizeBottomRight }
        if nearTop && nearLeft { return .resizeTopLeft }
        if nearTop && nearRight { return .resizeTopRight }
        return .move
    }

    // MARK: - Cursor

    private func applyCursor(at localPoint: NSPoint) {
        if isLocked { NSCursor.arrow.set(); return }
        switch modeAt(localPoint) {
        case .resizeTopLeft, .resizeBottomRight, .resizeTopRight, .resizeBottomLeft:
            NSCursor.crosshair.set()
        case .move:
            NSCursor.openHand.set()
        case .none:
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Belt and braces alongside mouseMoved: AppKit re-asserts the cursor from cursor rects
    /// after various events, and cursorUpdate is the hook it offers for saying otherwise.
    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHandles()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHandles()
        NSCursor.arrow.set()
    }

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

        guard let win = window as? DesktopPhotoWindow else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragMode = modeAt(p)
        initialMouse = NSEvent.mouseLocation
        unsnappedOrigin = win.photoFrame.origin

        // Window positions do not change while a widget is being dragged, so the alignment
        // targets are gathered once here rather than re-queried on every mouseDragged.
        SnapEngine.shared.beginDrag(for: win)

        let f = win.photoFrame
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
        guard let win = window as? DesktopPhotoWindow else { return }

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
                size: win.photoFrame.size,
                matInset: matWidth,
                modifiers: event.modifierFlags,
                dragStart: NSPoint(x: unsnappedOrigin.x - dx, y: unsnappedOrigin.y - dy)
            )
            win.setPhotoOrigin(snapped)

            if let screen = win.screen ?? NSScreen.main {
                SnapGuideOverlay.shared.show(guides, on: screen, above: win)
            }

        case .resizeBottomRight:
            let newW = max(minSize, mouse.x - anchorPoint.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x, y: anchorPoint.y - newW / aspectRatio, width: newW, height: newW / aspectRatio), to: win)

        case .resizeBottomLeft:
            let newW = max(minSize, anchorPoint.x - mouse.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x - newW, y: anchorPoint.y - newW / aspectRatio, width: newW, height: newW / aspectRatio), to: win)

        case .resizeTopRight:
            let newW = max(minSize, mouse.x - anchorPoint.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x, y: anchorPoint.y, width: newW, height: newW / aspectRatio), to: win)

        case .resizeTopLeft:
            let newW = max(minSize, anchorPoint.x - mouse.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x - newW, y: anchorPoint.y, width: newW, height: newW / aspectRatio), to: win)

        case .none:
            break
        }
    }

    private func applyPhotoFrame(_ rect: NSRect, to win: DesktopPhotoWindow) {
        canvasInset = requiredCanvasInset(photoSize: rect.size)
        win.setPhotoFrame(rect)
    }

    override func mouseUp(with event: NSEvent) {
        SnapGuideOverlay.shared.hide()
        SnapEngine.shared.endDrag()

        if isLocked { return }
        guard let win = window as? DesktopPhotoWindow else { return }

        // Save position
        NotificationCenter.default.post(name: .desktopPhotoMoved, object: win)

        // If we were resizing, report the new width
        if dragMode != .move && dragMode != .none {
            onResizeFinished?(win.photoFrame.width)
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

        // Overlapping photos had no way to be reordered at all short of hiding one.
        let frontItem = NSMenuItem(title: "Bring to Front", action: #selector(handleBringToFront), keyEquivalent: "")
        frontItem.target = self
        menu.addItem(frontItem)

        let backItem = NSMenuItem(title: "Send to Back", action: #selector(handleSendToBack), keyEquivalent: "")
        backItem.target = self
        menu.addItem(backItem)

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
    @objc private func handleBringToFront() { onBringToFront?() }
    @objc private func handleSendToBack() { onSendToBack?() }

    // MARK: - Lock flash

    func flashLockState(_ locked: Bool) {
        let size: CGFloat = 48
        let outer = visualRect
        let indicator = NSView(frame: NSRect(
            x: outer.midX - size / 2,
            y: outer.midY - size / 2,
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

    /// Only the photo itself is clickable. The window is deliberately larger than the photo
    /// now (see PhotoCanvas), and claiming that padding would swallow clicks meant for the
    /// desktop icons and wallpaper behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        modeAt(point) == .none ? nil : self
    }
}

// MARK: - Notification

extension Notification.Name {
    static let desktopPhotoMoved = Notification.Name("desktopPhotoMoved")
}
