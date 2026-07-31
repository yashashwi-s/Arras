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
        // Shadows are two custom CALayers on the container now (contact + ambient), not the
        // system window shadow -- see applyShadowSettings.
        hasShadow = false
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

        // Lay out synchronously before the window is ordered in, so the first frame
        // drawn is already the right size rather than snapping into place.
        //
        // This used to also call disableScreenUpdatesUntilFlush(), which Apple
        // deprecated in macOS 15 and documents as doing nothing at all. Keeping it
        // implied a guarantee that has not held for two releases; the synchronous
        // layout below is what actually prevents the flicker.
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

    // MARK: - v1.3 / v2.1 Shadow

    /// The system window shadow (`hasShadow`) is a single, fixed-look shadow that AppKit
    /// draws outside the window's own frame -- convenient in that it's never clipped, but it
    /// can't be split into a tight contact shadow plus a wide ambient one, which is what
    /// actually reads as elevation. So it stays off permanently, and both shadows are
    /// rendered as CALayers on the container instead (see DraggablePhotoView.relayout).
    func applyShadowSettings(enabled: Bool, blur: CGFloat, opacity: CGFloat) {
        hasShadow = false
        (contentView as? DraggablePhotoView)?.setShadowLayers(enabled: enabled, blur: blur, opacity: opacity)
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

    /// Hosts vignette + border. A layer-backed NSView's own layer always composites above
    /// whatever manual sibling CAShapeLayers/CAGradientLayers its *superview* adds directly
    /// -- z-order calls like insertSublayer(above:) can't override that once the reference
    /// layer belongs to a subview rather than being a literal entry in the parent's own
    /// sublayers array. Mat and the two shadow layers sit fine as direct sublayers of
    /// `self.layer` because they only ever need to be *below* imageView, which that same
    /// rule gives them for free; vignette and border need to be *above* it, so they live as
    /// sublayers of this second subview instead, added after imageView so ordinary AppKit
    /// subview stacking (later-added-on-top) puts it on top.
    private let overlayView: NSView

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

    // v2.1 — Borders, frames & depth
    private var matLayer: CAShapeLayer?
    private var borderGradientLayer: CAGradientLayer?
    private var contactShadowLayer: CAShapeLayer?
    private var ambientShadowLayer: CAShapeLayer?
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

    init(frame: NSRect, content: PhotoContent, locked: Bool, settings: PhotoItem? = nil) {
        imageView = AspectFillImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.apply(content)
        imageView.wantsLayer = true

        overlayView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        overlayView.wantsLayer = true

        self.isLocked = locked
        self.aspectRatio = content.size.width / content.size.height

        super.init(frame: frame)

        wantsLayer = true
        addSubview(imageView)
        addSubview(overlayView) // after imageView, so it stacks on top -- see the property comment

        // Seed every appearance property from `settings` before the first relayout, so the
        // first frame drawn already reflects mat/shape/border/shadow/tilt instead of
        // snapping into place a moment later. The old NSShadow-based single shadow is gone
        // -- see relayout()/applyShadowLayers for why two CALayers replace it.
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

        relayout()

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateLayout(_ size: NSSize) {
        frame = NSRect(origin: .zero, size: size)
        relayout()
    }

    // MARK: - v2.1 Unified layout

    /// Everything drawn -- image mask, mat, shadows, border, vignette, tilt -- funnels
    /// through here so they are always derived from the same current state and in the same
    /// order, rather than several call sites each keeping their own notion of "the shape" in
    /// sync after a resize.
    ///
    /// Shadows and tilt both need pixels beyond the photo's own silhouette to render or
    /// rotate into, but the window itself cannot grow to provide that room: ImageManager
    /// treats `window.frame.width` as the photo's persisted `widgetWidth` and writes it
    /// straight back to photos.json on every move/resize, so inflating the window frame here
    /// would inflate the saved size on the next launch. Reserving margin by shrinking the
    /// *content* inside a fixed-size window sidesteps that coupling entirely -- the tradeoff
    /// is that a photo with a large shadow or a tilt renders very slightly smaller than its
    /// nominal widgetWidth inside its window, rather than clipping.
    private func relayout() {
        let size = bounds.size
        let margin = contentMargin(for: size)
        let outer = NSRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let inner = outer.insetBy(dx: matWidth, dy: matWidth)
        imageView.frame = inner
        overlayView.frame = NSRect(origin: .zero, size: size)

        let outerRadius = min(baseCornerRadius, min(outer.width, outer.height) * 0.3)
        let innerRadius = min(baseCornerRadius, min(inner.width, inner.height) * 0.3)

        applyImageMask(inner: inner, cornerRadius: innerRadius)
        applyShadowLayers(outer: outer, cornerRadius: outerRadius)
        applyMatLayer(outer: outer, cornerRadius: outerRadius)
        applyVignetteLayer(inner: inner)
        applyBorderLayers(outer: outer, cornerRadius: outerRadius)
        applyTiltTransform()
    }

    private func contentMargin(for size: CGSize) -> CGFloat {
        let minDim = min(size.width, size.height)
        let shadowMargin: CGFloat = shadowEnabledFlag
            ? (shadowBlurBase * 1.4 + shadowBlurBase * 0.5 + 4)
            : 0
        let margin = max(shadowMargin, Self.tiltMargin(for: size, degrees: tiltDegrees))
        // Never let margin eat more than ~22% of the shorter side -- a small widget at max
        // shadow blur is a documented soft limit, not a crash, but it shouldn't be allowed to
        // consume the whole photo either.
        return min(margin, minDim * 0.22)
    }

    /// Extra half-width/height a rect of `size` needs on each side once rotated by `degrees`
    /// to keep its rotated bounding box inside the original (unrotated) footprint.
    private static func tiltMargin(for size: CGSize, degrees: CGFloat) -> CGFloat {
        guard degrees != 0 else { return 0 }
        let rad = degrees * .pi / 180
        let w = size.width, h = size.height
        let rotatedW = abs(w * cos(rad)) + abs(h * sin(rad))
        let rotatedH = abs(w * sin(rad)) + abs(h * cos(rad))
        return max(0, max(rotatedW - w, rotatedH - h) / 2)
    }

    private func applyImageMask(inner: NSRect, cornerRadius: CGFloat) {
        guard let imgLayer = imageView.layer else { return }
        switch shapeMask {
        case .roundedRect:
            imgLayer.mask = nil
            imgLayer.cornerRadius = cornerRadius
            imgLayer.masksToBounds = true
            imgLayer.cornerCurve = .continuous
        case .circle, .squircle, .arch:
            imgLayer.cornerRadius = 0
            let local = CGRect(origin: .zero, size: inner.size)
            let maskLayer = CAShapeLayer()
            maskLayer.frame = local
            maskLayer.path = shapeMask.path(in: local, cornerRadius: cornerRadius)
            maskLayer.fillColor = NSColor.black.cgColor
            imgLayer.mask = maskLayer
            imgLayer.masksToBounds = true
        }
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
        guard shadowEnabledFlag, let img = imageView.layer else {
            ambientShadowLayer = nil
            contactShadowLayer = nil
            return
        }

        let local = CGRect(origin: .zero, size: outer.size)
        let path = shapeMask.path(in: local, cornerRadius: cornerRadius)

        let ambient = makeShadowLayer()
        ambient.frame = outer
        ambient.path = path
        ambient.shadowPath = path
        ambient.shadowColor = NSColor.black.cgColor
        ambient.shadowOpacity = Float(min(shadowOpacityBase * 0.7, 1.0))
        ambient.shadowRadius = max(2, shadowBlurBase * 1.4)
        ambient.shadowOffset = CGSize(width: 0, height: -min(10, shadowBlurBase * 0.5))
        layer?.insertSublayer(ambient, below: img)
        ambientShadowLayer = ambient

        let contact = makeShadowLayer()
        contact.frame = outer
        contact.path = path
        contact.shadowPath = path
        contact.shadowColor = NSColor.black.cgColor
        contact.shadowOpacity = Float(min(shadowOpacityBase * 1.1, 1.0))
        contact.shadowRadius = max(1, shadowBlurBase * 0.25)
        contact.shadowOffset = CGSize(width: 0, height: -min(3, shadowBlurBase * 0.15))
        // Inserted after ambient -- each "below img" insert lands directly under img, so the
        // second one (contact) ends up the closer of the two, ambient furthest back.
        layer?.insertSublayer(contact, below: img)
        contactShadowLayer = contact
    }

    /// The passe-partout: a solid inset border of colour between the frame edge and the
    /// image, sitting directly behind it.
    private func applyMatLayer(outer: NSRect, cornerRadius: CGFloat) {
        matLayer?.removeFromSuperlayer()
        guard matWidth > 0, let img = imageView.layer else {
            matLayer = nil
            return
        }
        let local = CGRect(origin: .zero, size: outer.size)
        let mat = CAShapeLayer()
        mat.frame = outer
        mat.path = shapeMask.path(in: local, cornerRadius: cornerRadius)
        mat.fillColor = matColor.cgColor
        layer?.insertSublayer(mat, below: img)
        matLayer = mat
    }

    private func applyVignetteLayer(inner: NSRect) {
        vignetteLayer?.removeFromSuperlayer()
        guard vignetteEnabledFlag else {
            vignetteLayer = nil
            return
        }
        let gradient = CAGradientLayer()
        gradient.frame = inner
        gradient.type = .radial
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.4).cgColor
        ]
        gradient.locations = [0.5, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        gradient.cornerRadius = imageView.layer?.cornerRadius ?? 16
        // overlayView, not self.layer -- see the property comment on overlayView for why a
        // manual sublayer of the container can never paint above a subview's own layer no
        // matter the insertion call, so "above the image" has to be a second subview instead.
        overlayView.layer?.addSublayer(gradient)
        vignetteLayer = gradient
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

        // overlayView, not self.layer -- see the property comment on overlayView. Appended
        // after the vignette (added earlier in relayout()), so the border ends up on top of
        // that too within the overlay.
        if borderGradientEnabled {
            stroke.strokeColor = NSColor.black.cgColor // opaque alpha; colour comes from the gradient
            let gradient = CAGradientLayer()
            gradient.frame = outer
            gradient.colors = [currentBorderColor.cgColor, borderGradientColor.cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            gradient.mask = stroke
            overlayView.layer?.addSublayer(gradient)
            borderGradientLayer = gradient
            borderLayer = nil
        } else {
            stroke.strokeColor = currentBorderColor.cgColor
            overlayView.layer?.addSublayer(stroke)
            borderLayer = stroke
            borderGradientLayer = nil
        }
    }

    private func applyTiltTransform() {
        layer?.transform = tiltDegrees == 0
            ? CATransform3DIdentity
            : CATransform3DMakeRotation(tiltDegrees * .pi / 180, 0, 0, 1)
    }

    // MARK: - v1.3 / v2.1 Aesthetic Controls

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
