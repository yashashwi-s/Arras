import AppKit
import AVFoundation
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
/// −2147483603 (all of them, in one screen-sized window), Arras at −2147483602, and the
/// system's own desktop widgets at −2147483601. That last one is why an overlapping Sonoma
/// widget always drew on top of a photo — Arras was one level short.
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

    /// Back-to-front order of the four depths, so Bring to Front / Send to Back can walk them.
    var stackIndex: Int {
        switch self {
        case .behindIcons: return 0
        case .onDesktop: return 1
        case .aboveWidgets: return 2
        case .floating: return 3
        }
    }

    init?(stackIndex: Int) {
        guard let match = WidgetDepth.allCases.first(where: { $0.stackIndex == stackIndex }) else { return nil }
        self = match
    }
}

/// Keeps the user's saved opacity separate from the alpha currently drawn on screen.
/// Behind Icons is deliberately always visible because Finder prevents hover events there.
func effectivePhotoAlpha(
    configuredOpacity: CGFloat,
    revealOnHover: Bool,
    isHovering: Bool,
    isInteractive: Bool
) -> CGFloat {
    let opacity = max(0.1, min(1.0, configuredOpacity))
    return revealOnHover && isInteractive && !isHovering ? 0 : opacity
}

/// A borderless, always-on-desktop panel that displays a photo.
///
/// The window frame is a *canvas*: the photo's own rect inset outward by `canvasInset` (see
/// `PhotoCanvas`). Everything user-facing — the persisted frame, snapping, resize handles —
/// works in photo coordinates, never window coordinates.
///
/// An `NSPanel` with `.nonactivatingPanel`, not a plain `NSWindow`. Clicking an ordinary
/// window activates its application, whatever `canBecomeKey` says — so dragging a widget used
/// to pull Arras to the front, hand it the menu bar, and leave it there. A non-activating
/// panel takes mouse events without ever making the app active, which is the only way a
/// desktop ornament can be interactive without being intrusive.
class DesktopPhotoWindow: NSPanel {
    var photoId: UUID?
    var onVisualGeometryChanged: (() -> Void)?
    var onCollageDragBegan: ((Bool) -> Void)?
    var onCollageDragProposed: ((CGRect, Bool) -> CGRect?)?
    var onCollageDragEnded: (() -> Bool)?
    var onCollageDragCancelled: (() -> Void)?
    var onLockToggle: (() -> Void)?
    var onRemove: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onClickAction: (() -> Void)?
    var onBringToFront: (() -> Void)?
    var onSendToBack: (() -> Void)?
    var arrangementMenuItems: (() -> [NSMenuItem])?
    var onRuntimeActivityChanged: ((RuntimeActivityDecision) -> Void)?

    private var isCoveredByApp = false
    private var hasPlaylistContent = false
    var hasDynamicContent: Bool {
        guard let view = contentView as? DraggablePhotoView else { return false }
        return hasPlaylistContent
            || view.photoLayer.animatedFrames != nil || view.photoLayer.videoPlaybackStatus != .notVideo
    }

    func setCoveredByApp(_ covered: Bool) {
        guard covered != isCoveredByApp else { return }
        isCoveredByApp = covered
        refreshRuntimeActivity()
    }

    private var runtimeCenterListener: UUID?
    private var occlusionObserver: NSObjectProtocol?
    private var isRuntimeActivityMonitoring = false
    private var didPublishRuntimeActivity = false
    private(set) var runtimeActivityDecision = RuntimeActivityDecision.active
    var onWindowInteraction: (() -> Void)?
    var isCollageMember: (() -> Bool)?
    /// Read the screen pointer independently of a window that moves during a gesture.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var onBackgroundEventTarget: ((CGPoint) -> DesktopPhotoWindow?)?
    private weak var backgroundGestureTarget: DesktopPhotoWindow?
    private var backgroundGestureActive = false
    private weak var backgroundHoverTarget: DesktopPhotoWindow?

    /// Padding between the window frame and the photo rect, on every side.
    private(set) var canvasInset: CGFloat = 0

    private(set) var configuredOpacity: CGFloat = 1
    private var revealOnHover = false
    private var pointerIsInside = false
    private var widgetDepth: WidgetDepth = .onDesktop
    private var settingsWindowIsActive = false

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
        // Desktop scenes own their transitions. Do not independently zoom each
        // borderless photo or backdrop when AppKit orders its panel in or out.
        animationBehavior = .none
        // Shadows are two custom CALayers on the container now (contact + ambient), not the
        // system window shadow -- see applyShadowSettings.
        hasShadow = false
        // Our handlers own movement and snapping. Server-side dragging can
        // move a panel without updating photoFrame, racing the collage gesture.
        isMovable = false
        ignoresMouseEvents = false
        // Explicitly retain AppKit's transient behavior after setting our Space flags. Transient
        // windows hide in Mission Control, preventing desktop widgets from flashing while a
        // fullscreen Space is being spread into the overview.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .transient, .ignoresCycle]
        hidesOnDeactivate = false

        // Without this the window receives no mouseMoved events at all, even with a tracking
        // area that asks for them — installing the tracking area does not set this for you.
        // That is why the resize crosshair never appeared: mouseEntered fired, mouseMoved
        // never did, so the cursor was never changed.
        acceptsMouseMovedEvents = true
    }

    /// A widget never needs keyboard focus — it has no text field and no key equivalents of
    /// its own — and taking key status is what put Arras's menu bar on screen in place of
    /// whatever the user was actually working in. Mouse events do not require it.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Runtime activity

    /// Starts the shared process-state observer and this window's occlusion observer after the
    /// window has been ordered in. AppKit's occlusion state is meaningful only for an onscreen
    /// window, so registering before `orderFront` would make the initial state unreliable.
    func startRuntimeActivityMonitoring() {
        guard runtimeCenterListener == nil else { return }
        isRuntimeActivityMonitoring = true

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRuntimeActivity() }
        }
        runtimeCenterListener = RuntimeActivityCenter.shared.addListener { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRuntimeActivity() }
        }
        WindowCoverageMonitor.shared.add(self)
        refreshRuntimeActivity()
    }

    func stopRuntimeActivityMonitoring() {
        isRuntimeActivityMonitoring = false
        WindowCoverageMonitor.shared.remove(self)
        isCoveredByApp = false
        didPublishRuntimeActivity = false
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let runtimeCenterListener {
            RuntimeActivityCenter.shared.removeListener(runtimeCenterListener)
            self.runtimeCenterListener = nil
        }
    }

    var mediaPlaybackStatus: VideoPlaybackStatus {
        (contentView as? DraggablePhotoView)?.photoLayer.videoPlaybackStatus ?? .notVideo
    }

    private func refreshRuntimeActivity() {
        guard isRuntimeActivityMonitoring else { return }
        var input = RuntimeActivityInput()
        input.isOccluded = RuntimeActivityPolicy.isFullyOccluded(occlusionState) || isCoveredByApp
        input.environment = RuntimeActivityCenter.shared.environment

        let decision = RuntimeActivityPolicy.decision(for: input)
        let didChange = decision != runtimeActivityDecision
        runtimeActivityDecision = decision

        if let container = contentView as? DraggablePhotoView {
            container.photoLayer.setPlaybackEnabled(decision.allowsExpensiveAnimation)
            if !decision.allowsExpensiveAnimation {
                // A Space swap may have started its crossfade just before WindowServer reported
                // occlusion. Dropping that one-shot transition is safe because the next swap
                // will install a fresh transition when motion is allowed again.
                container.imageLayer.removeAnimation(forKey: kCATransition)
            }
        }
        if didChange || !didPublishRuntimeActivity {
            didPublishRuntimeActivity = true
            onRuntimeActivityChanged?(decision)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        defer {
            if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) { onWindowInteraction?() }
        }
        guard [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved].contains(event.type) else {
            super.sendEvent(event)
            return
        }
        if event.type == .leftMouseDown { cancelBackgroundGesture() }
        let captured = backgroundGestureActive && [.leftMouseDragged, .leftMouseUp].contains(event.type)
        let screenPoint = convertPoint(toScreen: event.locationInWindow)
        var target: DesktopPhotoWindow?
        if [.leftMouseDragged, .leftMouseUp].contains(event.type) {
            target = backgroundGestureTarget
        } else if [.leftMouseDown, .rightMouseDown, .mouseMoved].contains(event.type),
                  let photo = contentView as? DraggablePhotoView,
                  !photo.containsPhotoInteractionPoint(photo.convert(event.locationInWindow, from: nil)) {
            target = onBackgroundEventTarget?(screenPoint)
            if event.type == .leftMouseDown { backgroundGestureTarget = target; backgroundGestureActive = target != nil }
        }
        if event.type == .leftMouseUp { backgroundGestureTarget = nil; backgroundGestureActive = false }
        if event.type == .mouseMoved, backgroundHoverTarget !== target {
            clearBackgroundHover(with: event)
            backgroundHoverTarget = target
        }
        if let target, target !== self, target.isVisible,
           let forwarded = NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screenPoint),
                                             modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                             windowNumber: target.windowNumber, context: nil,
                                             eventNumber: event.eventNumber, clickCount: event.type == .mouseMoved ? 0 : event.clickCount,
                                             pressure: event.type == .mouseMoved ? 0 : event.pressure) {
            // Mouse movement belongs to the original window's tracking area.
            // AppKit may discard a synthesized move sent to another panel, so
            // resolve its hover feedback directly, as cursorUpdate already does.
            if event.type == .mouseMoved {
                _ = routeBackgroundPointer(with: event)
                return
            }
            // Declining a view hit inside a photo's shadow window does not route
            // the event to another window. Preserve one target for the gesture.
            target.sendEvent(forwarded)
            return
        }
        if captured { return }
        super.sendEvent(event)
    }

    @discardableResult
    func cancelBackgroundGesture() -> Bool {
        let active = backgroundGestureActive
        let target = backgroundGestureTarget
        backgroundGestureTarget = nil
        backgroundGestureActive = false
        if active { target?.contentView?.cancelOperation(nil) }
        return active
    }

    func clearBackgroundHover(with event: NSEvent) {
        let target = backgroundHoverTarget
        if event.type == .mouseExited, let target, let view = target.contentView {
            let screenPoint = convertPoint(toScreen: event.locationInWindow)
            let point = view.convert(target.convertPoint(fromScreen: screenPoint), from: nil)
            // A delayed exit from this shadow can arrive after the pointer has
            // entered its destination. Preserve that destination's hover cues.
            if let surface = view as? CollageSurfaceView, surface.containsBackgroundPoint(point) { return }
            if let photo = view as? DraggablePhotoView, photo.containsPhotoInteractionPoint(point) { return }
        }
        backgroundHoverTarget = nil
        target?.contentView?.mouseExited(with: event)
    }

    /// Cursor-update events belong to tracking areas, not mouseEvent creation.
    /// Resolve their destination just like gap input, then update that view
    /// directly so the foreground shadow cannot reset the background's cursor.
    var canClaimPointer: Bool {
        guard isVisible, !ignoresMouseEvents else { return false }
        // Settings can cover widgets while active-always tracking still delivers events.
        return !settingsWindowIsActive || NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == windowNumber
    }

    func routeBackgroundPointer(with event: NSEvent) -> Bool {
        guard canClaimPointer else { return false }
        guard let photo = contentView as? DraggablePhotoView else { return false }
        let local = photo.convert(event.locationInWindow, from: nil)
        let target = photo.containsPhotoInteractionPoint(local) ? nil : onBackgroundEventTarget?(convertPoint(toScreen: event.locationInWindow))
        if backgroundHoverTarget !== target {
            clearBackgroundHover(with: event)
            backgroundHoverTarget = target
        }
        guard let target, target !== self, target.isVisible else { return false }
        let screenPoint = convertPoint(toScreen: event.locationInWindow)
        let point = target.contentView?.convert(target.convertPoint(fromScreen: screenPoint), from: nil) ?? .zero
        if let surface = target.contentView as? CollageSurfaceView { surface.updatePointer(at: point) }
        else if let photo = target.contentView as? DraggablePhotoView { photo.updatePointer(at: point) }
        else { return false }
        return true
    }

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

    func setCollageCanvasInset(_ inset: CGFloat) { canvasInset = inset }

    func windowFrame(forPhoto rect: NSRect) -> NSRect {
        rect.insetBy(dx: -canvasInset, dy: -canvasInset)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // A collage spans several borderless panels. AppKit's titled-window
        // screen-top constraint moves each floating panel by a different amount,
        // separating photos from their backdrop and from their saved geometry.
        // Desktop and floating widgets must use the same screen-coordinate scene.
        frameRect
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
        var moved = photoFrame
        moved.origin = origin
        setPhotoOrigin(origin, nativeOrigin: windowFrame(forPhoto: moved).origin)
    }

    /// A transitioning collage can retain a larger host than its logical bounds.
    func setPhotoOrigin(_ origin: NSPoint, nativeOrigin: NSPoint) {
        photoFrame.origin = origin
        if frame.origin != nativeOrigin { setFrameOrigin(nativeOrigin) }
    }

    /// AppKit translates attached panels with their parent. Update scene geometry
    /// without issuing the same native placement a second time.
    func setPhotoOriginFollowingParent(_ origin: NSPoint) {
        photoFrame.origin = origin
    }

    /// Re-derives the padding after an appearance change, holding the photo rect fixed so the
    /// photo does not appear to move when a shadow, mat or tilt is adjusted.
    func refreshCanvasInset() {
        setPhotoFrame(photoFrame)
        onVisualGeometryChanged?()
    }

    func showPhoto(_ content: PhotoContent, baseWidth: CGFloat = 300, locked: Bool = false, settings: PhotoItem? = nil) {
        let content = PhotoReferenceRenderer.content(content, settings: settings?.reference ?? PhotoReferenceSettings())
        hasPlaylistContent = !(settings?.spaceImageFilenames.isEmpty ?? true)
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
        container.onHoverChanged = { [weak self] hovering in self?.setPointerInside(hovering) }
        container.onBringToFront = { [weak self] in self?.onBringToFront?() }
        container.onSendToBack = { [weak self] in self?.onSendToBack?() }
        container.arrangementMenuItems = { [weak self] in self?.arrangementMenuItems?() ?? [] }
        container.onClickAction = { [weak self] in self?.onClickAction?() }

        pointerIsInside = false
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
            setRevealOnHover(s.revealOnHover, animated: false)
        }

        // orderFront, never makeKeyAndOrderFront: showing a widget must not pull the app to
        // the front. Every launch used to activate Arras once per visible widget.
        orderFront(nil)
        if isRuntimeActivityMonitoring { WindowCoverageMonitor.shared.add(self) }
    }

    func hidePhoto() {
        cancelBackgroundGesture()
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
            container.photoLayer.releaseVideoResources()
        }

        stopRuntimeActivityMonitoring()

        // AppKit or another caller can retain a closed panel; isReleasedWhenClosed
        // is false to keep caller-owned reuse safe. Clear its identity so a stale
        // reference cannot be mistaken for the replacement window a later show creates.
        photoId = nil
        close()
        // AppKit can retain a closed panel. Release its decoded media/layer
        // tree now; showPhoto builds a fresh view if this window is reused.
        contentView = nil
    }

    func setLocked(_ locked: Bool) {
        (contentView as? DraggablePhotoView)?.isLocked = locked
    }

    func frameForResizing(toWidth width: CGFloat) -> NSRect? {
        guard width.isFinite, width > 0 else { return nil }
        guard let container = contentView as? DraggablePhotoView,
              let image = container.photoImage else { return nil }
        // photoImage is always a representative still (even for animated
        // content -- see PhotoImageLayer.image), so aspect-ratio math
        // here needs no animated-specific branch.
        let ar = container.aspectRatio > 0 ? container.aspectRatio : image.size.width / image.size.height
        let height = width / ar
        guard ar.isFinite, ar > 0, height.isFinite, height > 0 else { return nil }
        let photo = photoFrame
        return NSRect(x: photo.origin.x, y: photo.origin.y, width: width, height: height)
    }

    func resizeTo(width: CGFloat) {
        guard let container = contentView as? DraggablePhotoView,
              let newPhoto = frameForResizing(toWidth: width) else { return }
        canvasInset = container.requiredCanvasInset(photoSize: newPhoto.size)
        container.canvasInset = canvasInset
        photoFrame = newPhoto
        let newFrame = windowFrame(forPhoto: newPhoto)
        if !runtimeActivityDecision.allowsExpensiveAnimation {
            setFrame(newFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.animator().setFrame(newFrame, display: true)
            }
        }
        container.updateLayout(newFrame.size)
        // PhotoManager commits this programmatic resize and its enclosing
        // collage together before reaching the native window.
    }

    // MARK: - Depth

    func setDepth(_ depth: WidgetDepth) {
        widgetDepth = depth
        let targetLevel = depth.windowLevel
        // Reassigning a panel's level can reorder it, even when its depth did
        // not change. In particular, collage sync must not raise the backdrop.
        if level != targetLevel { level = targetLevel }
        // A widget behind Finder's desktop window can never be clicked, so there is no reason
        // to keep hit-testing it — and letting go of the events means the desktop underneath
        // behaves exactly as it would with no widget there.
        ignoresMouseEvents = !depth.isInteractive
        hidesOnDeactivate = false
        updateEffectiveAlpha(animated: false)
    }

    func setPhotoOpacity(_ value: CGFloat) {
        configuredOpacity = max(0.1, min(1.0, value))
        updateEffectiveAlpha(animated: false)
    }

    /// Track Settings focus for pointer ownership without changing widget depth.
    func setSettingsWindowActive(_ active: Bool) {
        settingsWindowIsActive = active
    }

    func setRevealOnHover(_ enabled: Bool, animated: Bool = true) {
        revealOnHover = enabled
        updateEffectiveAlpha(animated: animated)
    }

    private func setPointerInside(_ hovering: Bool) {
        guard pointerIsInside != hovering else { return }
        pointerIsInside = hovering
        updateEffectiveAlpha(animated: true)
    }

    private func updateEffectiveAlpha(animated: Bool) {
        guard let contentView else { return }
        let target = effectivePhotoAlpha(
            configuredOpacity: configuredOpacity,
            revealOnHover: revealOnHover,
            isHovering: pointerIsInside,
            isInteractive: widgetDepth.isInteractive
        )
        guard contentView.alphaValue != target else { return }

        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            contentView.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            contentView.animator().alphaValue = target
        }
    }

    // MARK: - Shadow

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

    static func frameForSwapping(contentSize: NSSize, photoFrame: NSRect, targetFrame: NSRect? = nil, mode: String = "dynamic") -> NSRect? {
        func valid(_ frame: NSRect) -> Bool {
            frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return nil }
        if mode == "fixed" { return valid(photoFrame) ? photoFrame : nil }
        if let targetFrame, valid(targetFrame) { return targetFrame }
        guard valid(photoFrame) else { return nil }
        let height = photoFrame.width * contentSize.height / contentSize.width
        guard height.isFinite, height > 0 else { return nil }
        return NSRect(x: photoFrame.minX, y: photoFrame.maxY - height, width: photoFrame.width, height: height)
    }

    func swapImage(_ content: PhotoContent, targetFrame: NSRect? = nil, mode: String = "dynamic", animate: Bool = true,
                   notifyGeometryChange: Bool = true) {
        guard let container = contentView as? DraggablePhotoView else { return }
        let content = PhotoReferenceRenderer.content(content, settings: container.referenceSettings)
        let shouldAnimate = animate && runtimeActivityDecision.allowsExpensiveAnimation
        let newSize = content.size
        let newAR = newSize.width / newSize.height

        // Determine the target *photo* rect. Callers persist and pass photo rects, never
        // window frames — the padding is re-derived here.
        guard let newPhoto = Self.frameForSwapping(contentSize: newSize, photoFrame: photoFrame,
                                                   targetFrame: targetFrame, mode: mode) else { return }
        if mode == "dynamic" { container.aspectRatio = newAR }

        canvasInset = container.requiredCanvasInset(photoSize: newPhoto.size)
        container.canvasInset = canvasInset
        photoFrame = newPhoto
        let newFrame = windowFrame(forPhoto: newPhoto)

        if shouldAnimate {
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
        container.photoLayer.apply(content, animationStartDelay: shouldAnimate ? Self.crossfadeDuration : 0)
        if isRuntimeActivityMonitoring { WindowCoverageMonitor.shared.add(self) }

        if shouldAnimate {
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
        if notifyGeometryChange { onVisualGeometryChanged?() }
    }

    // MARK: - Space Binding

    /// AppKit has no public API to enumerate or target a specific Space by identity (that's
    /// private CGS/SkyLight territory), so "bind to a Space" here means "stay on whichever
    /// Space this window is already on" rather than "always Space #3" — the achievable subset
    /// of the feature. Dropping `.canJoinAllSpaces` stops the window from following Mission
    /// Control switches; `.moveToActiveSpace` (instead of no behavior flags) keeps it visible
    /// immediately when the binding is turned on from whatever Space the user is currently on,
    /// rather than requiring a manual switch away and back.
    func setSpaceBound(_ bound: Bool) {
        let behavior: NSWindow.CollectionBehavior = bound
            ? [.moveToActiveSpace, .canJoinAllApplications, .transient, .ignoresCycle]
            : [.canJoinAllSpaces, .canJoinAllApplications, .transient, .ignoresCycle]
        if collectionBehavior != behavior { collectionBehavior = behavior }
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
    private static let videoEndNotification = AVPlayerItem.didPlayToEndTimeNotification

    let layer = CALayer()

    /// A representative still (first frame, for animated content) kept in
    /// sync at all times so aspect-ratio/size math elsewhere (resizeTo,
    /// DraggablePhotoView.photoImage) doesn't need to know or care whether
    /// playback is currently animated.
    private(set) var image: NSImage?

    /// The decoded frames for the current GIF-style content, retained while playback is paused
    /// as well so a visibility or energy transition can resume without another decode.
    private(set) var animatedFrames: AnimatedImageFrames?

    /// False while runtime policy says this widget should yield. Keeping the decoded frames
    /// lets playback resume immediately without decoding the source again; removing the CA
    /// animation is enough to stop render-server frame advancement while the widget is hidden.
    private(set) var isPlaybackEnabled = true
    private(set) var videoPlaybackStatus: VideoPlaybackStatus = .notVideo

    /// Bumped on every `apply(_:)` call. A deferred playback-start closure
    /// captures the generation it was scheduled under and checks it before
    /// installing the CAKeyframeAnimation, so a rapid-fire Space rotation
    /// (swap A, then swap B before A's crossfade finishes) can't let A's
    /// delayed animation clobber B's content after the fact.
    private var generation = 0

    /// Fixed Spaces opt into a deliberate fill crop; ordinary widgets leave this false so
    /// their true-ratio aspect-fit behaviour is unchanged. A focal point changes only the
    /// source rectangle inside that crop.
    private(set) var isCropEnabled = false
    private var focalPoint: NormalizedFocalPoint?
    private let videoLayer = AVPlayerLayer()
    private var videoPlayer: AVPlayer?
    private var videoContent: VideoPlaybackContent?
    private var videoEndObserver: NSObjectProtocol?

    init() {
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        videoLayer.videoGravity = .resizeAspect
        videoLayer.isHidden = true
        layer.addSublayer(videoLayer)
    }

    deinit {
        releaseVideoResources()
    }

    func setCropFocalPoint(_ point: NormalizedFocalPoint?, cropEnabled: Bool) {
        focalPoint = point
        isCropEnabled = cropEnabled
        layer.contentsGravity = cropEnabled ? .resizeAspectFill : .resizeAspect
        updateContentsRect()
    }

    /// Recomputes the normalized source rectangle after the target layer changes size. A nil
    /// focal point intentionally means the historical centred crop, not "show the whole image"
    /// when a fixed Space or collage slot must fill its bounds.
    func updateContentsRect() {
        guard isCropEnabled, let image else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            updateVideoLayout()
            return
        }
        layer.contentsRect = PhotoCropGeometry.contentsRect(
            sourceSize: image.size,
            targetSize: layer.bounds.size,
            focalPoint: focalPoint
        )
        updateVideoLayout()
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
        case .video(let video):
            setVideo(video, representativeImage: video.editedPoster ?? video.poster)
        case .livePhoto(let still, let video):
            setVideo(video, representativeImage: still)
        }
    }

    private func setStill(_ newImage: NSImage?) {
        stopAnimating()
        releaseVideoResources()
        image = newImage
        layer.contents = newImage
        updateContentsRect()
    }

    private func setAnimated(_ frames: AnimatedImageFrames, representativeImage: NSImage, startDelay: TimeInterval) {
        stopAnimating()
        releaseVideoResources()
        image = representativeImage
        // Show frame 0 right away so there's always something on screen,
        // even before (or if) the keyframe animation below installs.
        layer.contents = frames.images.first
        updateContentsRect()
        guard frames.images.count > 1 else { return }
        animatedFrames = frames

        guard isPlaybackEnabled else { return }

        generation += 1
        let expectedGeneration = generation
        let install: () -> Void = { [weak self] in
            // Bail if a newer `apply(_:)` call superseded us while this was
            // pending -- see the stale-callback discipline documented on
            // hidePhoto().
            guard let self,
                  self.generation == expectedGeneration,
                  self.isPlaybackEnabled,
                  self.animatedFrames != nil else { return }
            self.layer.add(frames.makeContentsAnimation(), forKey: Self.gifAnimationKey)
        }
        if startDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + startDelay, execute: install)
        } else {
            install()
        }
    }

    private func setVideo(_ content: VideoPlaybackContent, representativeImage: NSImage) {
        stopAnimating()
        releaseVideoResources()
        image = representativeImage
        layer.contents = representativeImage
        videoContent = content
        let player = AVPlayer(url: content.url)
        if content.referenceSettings.hasImageEdits, let item = player.currentItem {
            let settings = content.referenceSettings
            Task { @MainActor [weak self, weak player, weak item] in
                guard let item else { return }
                do {
                    let composition = try await PhotoReferenceRenderer.videoComposition(for: item.asset, settings: settings)
                    guard let self, let player, self.videoPlayer === player else { return }
                    item.videoComposition = composition
                    if self.isPlaybackEnabled { self.startVideoPlayback(player) }
                } catch {
                    // Keep the edited poster visible if the composition cannot be built.
                }
            }
        }
        player.isMuted = true
        player.volume = 0
        videoPlayer = player
        videoLayer.player = player
        videoLayer.isHidden = true
        videoPlaybackStatus = .paused
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: Self.videoEndNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player, self.isPlaybackEnabled, self.videoPlayer === player else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                guard let self, let player, self.isPlaybackEnabled, self.videoPlayer === player else { return }
                self.startVideoPlayback(player)
            }
        }
        updateContentsRect()
        if isPlaybackEnabled && !content.referenceSettings.hasImageEdits {
            startVideoPlayback(player)
        }
    }

    private func startVideoPlayback(_ player: AVPlayer) {
        guard videoPlayer === player, isPlaybackEnabled else { return }
        guard videoContent?.referenceSettings.hasImageEdits != true || player.currentItem?.videoComposition != nil else { return }
        videoLayer.isHidden = false
        videoPlaybackStatus = .playing
        player.isMuted = true
        player.volume = 0
        player.play()
    }

    private func pauseVideoPlayback() {
        videoPlayer?.pause()
        guard videoPlayer != nil else { return }
        videoLayer.isHidden = true
        videoPlaybackStatus = .paused
    }

    /// Releases AVPlayer/AVPlayerLayer resources when a widget is torn down.  A hidden widget is
    /// rebuilt from its managed bytes on show, so retaining a decoder across hide/show is not
    /// worth the memory and file-descriptor cost.
    func releaseVideoResources() {
        if let videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
        }
        videoEndObserver = nil
        videoPlayer?.pause()
        videoLayer.player = nil
        videoPlayer = nil
        videoContent = nil
        videoLayer.isHidden = true
        videoPlaybackStatus = .notVideo
    }

    private func updateVideoLayout() {
        guard let videoContent, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
        let bounds = layer.bounds
        guard isCropEnabled else {
            videoLayer.frame = bounds
            videoLayer.videoGravity = .resizeAspect
            return
        }

        let sourceSize = image?.size ?? videoContent.size
        let sourceAspect = sourceSize.width / max(sourceSize.height, 1)
        let targetAspect = bounds.width / max(bounds.height, 1)
        let focus = focalPoint ?? .center
        if sourceAspect > targetAspect {
            let fullWidth = bounds.height * sourceAspect
            videoLayer.frame = CGRect(
                x: bounds.minX - (fullWidth - bounds.width) * focus.x,
                y: bounds.minY,
                width: fullWidth,
                height: bounds.height
            )
        } else {
            let fullHeight = bounds.width / max(sourceAspect, 0.001)
            videoLayer.frame = CGRect(
                x: bounds.minX,
                y: bounds.minY - (fullHeight - bounds.height) * focus.y,
                width: bounds.width,
                height: fullHeight
            )
        }
        // The expanded layer already has the source aspect ratio; aspect-fit within it avoids
        // introducing a second crop while the parent mask clips the focused rectangle.
        videoLayer.videoGravity = .resizeAspect
    }

    /// Stops GIF playback and drops the tracked frame data. Cheap and safe
    /// to call even when nothing is animating.
    func stopAnimating() {
        generation += 1
        layer.removeAnimation(forKey: Self.gifAnimationKey)
        animatedFrames = nil
    }

    /// Enables or disables render-server frame advancement without touching the representative
    /// still in `layer.contents`. This is intentionally separate from `stopAnimating()`: hidden
    /// or thermally constrained widgets retain their decoded frames so wake/visibility changes
    /// do not perform another image decode on the main thread.
    func setPlaybackEnabled(_ enabled: Bool) {
        guard enabled != isPlaybackEnabled else { return }
        isPlaybackEnabled = enabled
        generation += 1
        layer.removeAnimation(forKey: Self.gifAnimationKey)

        if enabled, let frames = animatedFrames {
            guard frames.images.count > 1 else { return }
            layer.add(frames.makeContentsAnimation(), forKey: Self.gifAnimationKey)
        } else if enabled, let player = videoPlayer {
            startVideoPlayback(player)
        } else {
            pauseVideoPlayback()
        }
    }
}

// MARK: - Draggable Photo View

class DraggablePhotoView: NSView {
    let photoLayer = PhotoImageLayer()
    var referenceSettings = PhotoReferenceSettings()

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
    var isLockedByCollage = false
    var lockActionTitle: String { isLockedByCollage ? "Unlock Collage" : (isLocked ? "Unlock Position" : "Lock Position") }

    var onLockToggle: (() -> Void)?
    var onRemove: (() -> Void)?
    var onResizeFinished: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onClickAction: (() -> Void)?
    var onBringToFront: (() -> Void)?
    var onSendToBack: (() -> Void)?
    var arrangementMenuItems: (() -> [NSMenuItem])?
    private var lastAdvanceTime: TimeInterval = 0

    private var dragMode: DragMode = .none { didSet { if dragMode != oldValue { updateHandles() } } }
    private var initialMouse: NSPoint = .zero
    private var anchorPoint: NSPoint = .zero   // the fixed corner (screen coords)
    // The drag's true origin, accumulated straight from mouse deltas. Never read the window's
    // on-screen frame back into this — once snapping displays an adjusted origin, the frame and
    // the true drag position diverge on purpose, and re-deriving one from the other is what
    // causes the widget to lag behind or run away from the cursor. See SnapEngine.
    private var unsnappedOrigin: NSPoint = .zero
    private var dragPickupOrigin: NSPoint = .zero
    private var collageOwnsPlacement = false
    var aspectRatio: CGFloat = 1.0
    var baseCornerRadius: CGFloat = 16

    /// Padding between the window's edge and the photo. Mirrors the window's own value.
    var canvasInset: CGFloat

    private let handleZone: CGFloat = 16
    private let minSize: CGFloat = 80
    private var isHovering = false

    // Aesthetic layers
    private var borderLayer: CAShapeLayer?
    private var vignetteLayer: CALayer?

    // Borders, frames & depth
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
        referenceSettings = settings?.reference ?? PhotoReferenceSettings()

        layer?.addSublayer(contentLayer)
        contentLayer.addSublayer(photoLayer.layer)
        photoLayer.apply(content)
        let cropEnabled = settings.map {
            !$0.spaceImageFilenames.isEmpty && $0.folderSizeMode == "fixed"
        } ?? false
        photoLayer.setCropFocalPoint(settings?.focalPoint, cropEnabled: cropEnabled)

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

    func setFocalPoint(_ point: NormalizedFocalPoint?, cropEnabled: Bool) {
        photoLayer.setCropFocalPoint(point, cropEnabled: cropEnabled)
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
        photoLayer.updateContentsRect()
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

    /// A continuous, low-opacity vignette. The farthest corner lies inside the gradient's
    /// ellipse, avoiding an opaque ring or an unshaded strip around the photo.
    private func applyVignetteLayer(inner: NSRect, cornerRadius: CGFloat) {
        vignetteLayer?.removeFromSuperlayer()
        guard vignetteEnabledFlag, inner.width > 0, inner.height > 0 else {
            vignetteLayer = nil
            return
        }
        let local = CGRect(origin: .zero, size: inner.size)
        let fade = CAGradientLayer()
        fade.frame = inner
        fade.type = .radial
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        fade.endPoint = CGPoint(x: 1.21, y: 1.21)
        fade.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                       NSColor.black.withAlphaComponent(0.025).cgColor,
                       NSColor.black.withAlphaComponent(0.14).cgColor]
        fade.locations = [0, 0.45, 1]
        let clip = CAShapeLayer()
        clip.frame = local
        clip.path = shapeMask.path(in: local, cornerRadius: cornerRadius)
        fade.mask = clip
        contentLayer.addSublayer(fade)
        vignetteLayer = fade
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

    /// Show unlocked photo grips only while hovered or interacting.
    private func applyHandleLayers(outer: NSRect) {
        handleLayers.forEach { $0.removeFromSuperlayer() }
        handleLayers = []
        guard !isLocked, isHovering || dragMode != .none else { return }

        let size: CGFloat = 10
        // Shadow-free photos can have no window padding. Keep the full marker
        // inside the photo instead of clipping three quarters off at the corner.
        let inset: CGFloat = 7
        let corners = [
            CGPoint(x: outer.minX + inset, y: outer.minY + inset),
            CGPoint(x: outer.maxX - inset, y: outer.minY + inset),
            CGPoint(x: outer.minX + inset, y: outer.maxY - inset),
            CGPoint(x: outer.maxX - inset, y: outer.maxY - inset)
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

    /// Group scaling updates geometry in place, keeping animated content and
    /// window identity intact. One layout avoids four intermediate styles.
    func applyScaledAppearance(_ item: PhotoItem) {
        baseCornerRadius = item.cornerRadius
        currentBorderWidth = item.borderWidth
        matWidth = item.matWidth
        shadowBlurBase = item.shadowBlur
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

    func containsPhotoInteractionPoint(_ point: NSPoint) -> Bool {
        let local = pointInContent(point)
        let rect = CGRect(origin: .zero, size: visualRect.size)
        let radius = min(baseCornerRadius, min(rect.width, rect.height) * 0.5)
        if shapeMask.path(in: rect, cornerRadius: radius).contains(local) { return true }
        // Keep the small corner grips usable without claiming the invisible
        // sixteen-point side strips that fill the gaps between grouped photos.
        guard !isLocked, rect.insetBy(dx: -5, dy: -5).contains(local) else { return false }
        switch modeAt(point) {
        case .resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight: return true
        default: return false
        }
    }

    // MARK: - Cursor

    private func applyCursor(at localPoint: NSPoint) {
        // Active-always tracking can deliver a late cursor update after Settings covers a
        // widget. Only the window actually under the pointer may claim the drag cursor.
        guard let window = window as? DesktopPhotoWindow, window.canClaimPointer else { return }
        if isLocked { NSCursor.arrow.set(); return }
        switch modeAt(localPoint) {
        case .resizeTopLeft, .resizeBottomRight, .resizeTopRight, .resizeBottomLeft:
            setResizeCursor(modeAt(localPoint))
        case .move:
            NSCursor.arrow.set()
        case .none:
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }

    /// Belt and braces alongside mouseMoved: AppKit re-asserts the cursor from cursor rects
    /// after various events, and cursorUpdate is the hook it offers for saying otherwise.
    override func cursorUpdate(with event: NSEvent) {
        if (window as? DesktopPhotoWindow)?.routeBackgroundPointer(with: event) == true { return }
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    func updatePointer(at point: CGPoint) {
        let inside = containsPhotoInteractionPoint(point)
        if isHovering != inside { isHovering = inside; updateHandles() }
        applyCursor(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
        isHovering = true
        onHoverChanged?(true)
        updateHandles()
    }

    override func mouseExited(with event: NSEvent) {
        (window as? DesktopPhotoWindow)?.clearBackgroundHover(with: event)
        isHovering = false
        onHoverChanged?(false)
        updateHandles()
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        // Lock Position disables moving/resizing, not the widget's configured action.
        if event.clickCount == 2 {
            let now = Date().timeIntervalSince1970
            if now - lastAdvanceTime > 0.3 {
                lastAdvanceTime = now
                onClickAction?()
            }
            return
        }

        guard !isLocked else { return }
        guard let win = window as? DesktopPhotoWindow else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragMode = modeAt(p)
        applyGestureCursor()
        traceCollagePointer("down mode=\(dragMode)", event: event)
        initialMouse = win.pointerLocation()
        unsnappedOrigin = win.photoFrame.origin
        dragPickupOrigin = win.photoFrame.origin
        collageOwnsPlacement = false
        if dragMode != .none { win.onCollageDragBegan?(dragMode != .move) }

        // Ordinary targets are gathered once; changing collage backgrounds are
        // excluded and their placement/gap guides are handled separately.
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

    private func applyGestureCursor() {
        switch dragMode {
        case .move: NSCursor.arrow.set()
        case .none: break
        default: setResizeCursor(dragMode)
        }
    }

    private func setResizeCursor(_ mode: DragMode) {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch mode {
            case .resizeTopLeft: position = .topLeft
            case .resizeTopRight: position = .topRight
            case .resizeBottomLeft: position = .bottomLeft
            default: position = .bottomRight
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        } else { NSCursor.crosshair.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        if isLocked { return }
        guard let win = window as? DesktopPhotoWindow else { return }

        applyGestureCursor()
        let mouse = win.pointerLocation()
        traceCollagePointer("drag mode=\(dragMode)", event: event)

        switch dragMode {
        case .move:
            let dx = mouse.x - initialMouse.x
            let dy = mouse.y - initialMouse.y
            // Accumulate onto the true drag position, not the (possibly snapped) displayed
            // frame — see the comment on `unsnappedOrigin`.
            unsnappedOrigin.x += dx
            unsnappedOrigin.y += dy
            initialMouse = mouse

            var collageOrigin = unsnappedOrigin
            if event.modifierFlags.contains(.shift) {
                if abs(collageOrigin.x - dragPickupOrigin.x) >= abs(collageOrigin.y - dragPickupOrigin.y) { collageOrigin.y = dragPickupOrigin.y }
                else { collageOrigin.x = dragPickupOrigin.x }
            }
            let bypass = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) || !SnapEngine.shared.isEnabled
            let collageFrame = win.onCollageDragProposed?(CGRect(origin: collageOrigin, size: win.photoFrame.size), bypass)
            if let collageFrame {
                SnapEngine.shared.clearLocks()
                collageOwnsPlacement = true
                win.setPhotoOrigin(collageFrame.origin)
            } else if collageOwnsPlacement {
                // Leave at the raw pointer position, without inheriting magnetic
                // locks that were calculated invisibly underneath collage snapping.
                SnapEngine.shared.clearLocks()
                collageOwnsPlacement = false
                win.setPhotoOrigin(collageOrigin)
                SnapGuideOverlay.shared.hide()
            } else {
                let (snapped, guides) = SnapEngine.shared.snappedOrigin(
                    for: win, proposedOrigin: unsnappedOrigin, size: win.photoFrame.size,
                    matInset: matWidth, modifiers: event.modifierFlags, dragStart: dragPickupOrigin
                )
                win.setPhotoOrigin(snapped)
                if let screen = win.screen ?? NSScreen.main { SnapGuideOverlay.shared.show(guides, on: screen, above: win) }
            }

        case .resizeBottomRight:
            let newW = max(minSize, mouse.x - anchorPoint.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x, y: anchorPoint.y - newW / aspectRatio, width: newW, height: newW / aspectRatio), to: win, modifiers: event.modifierFlags)

        case .resizeBottomLeft:
            let newW = max(minSize, anchorPoint.x - mouse.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x - newW, y: anchorPoint.y - newW / aspectRatio, width: newW, height: newW / aspectRatio), to: win, modifiers: event.modifierFlags)

        case .resizeTopRight:
            let newW = max(minSize, mouse.x - anchorPoint.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x, y: anchorPoint.y, width: newW, height: newW / aspectRatio), to: win, modifiers: event.modifierFlags)

        case .resizeTopLeft:
            let newW = max(minSize, anchorPoint.x - mouse.x)
            applyPhotoFrame(NSRect(x: anchorPoint.x - newW, y: anchorPoint.y, width: newW, height: newW / aspectRatio), to: win, modifiers: event.modifierFlags)

        case .none:
            break
        }
    }

    private func applyPhotoFrame(_ rect: NSRect, to win: DesktopPhotoWindow, modifiers: NSEvent.ModifierFlags) {
        let corner: CollageResizeCorner
        switch dragMode {
        case .resizeTopLeft: corner = .topLeft
        case .resizeTopRight: corner = .topRight
        case .resizeBottomLeft: corner = .bottomLeft
        default: corner = .bottomRight
        }
        canvasInset = requiredCanvasInset(photoSize: rect.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            win.setPhotoFrame(rect)
            _ = win.onCollageDragProposed?(rect, modifiers.contains(.option))
        }
        let guides = SnapEngine.shared.resizeGuides(for: win.visualFrame, corner: corner, modifiers: modifiers)
        if let screen = win.screen ?? NSScreen.main { SnapGuideOverlay.shared.show(guides, on: screen, above: win) }
    }

    override func mouseUp(with event: NSEvent) {
        SnapGuideOverlay.shared.hide()
        SnapEngine.shared.endDrag()

        if isLocked { return }
        guard let win = window as? DesktopPhotoWindow else { return }

        guard dragMode != .none else { return }
        traceCollagePointer("up mode=\(dragMode)", event: event)
        let collageHandled = win.onCollageDragEnded?() ?? false
        if !collageHandled { NotificationCenter.default.post(name: .desktopPhotoMoved, object: win) }

        // If we were resizing, report the new width
        if !collageHandled && dragMode != .move && dragMode != .none {
            onResizeFinished?(win.photoFrame.width)
        }
        dragMode = .none
        collageOwnsPlacement = false
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func traceCollagePointer(_ stage: String, event: NSEvent) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ARRAS_COLLAGE_POINTER_TRACE"] == "1",
              let root = ProcessInfo.processInfo.environment["ARRAS_UI_TEST_STORAGE_DIR"],
              let window = window as? DesktopPhotoWindow else { return }
        let path = URL(fileURLWithPath: root).appendingPathComponent("pointer-trace.txt")
        let message = "\(stage) id=\(window.photoId?.uuidString ?? "nil") event=\(event.locationInWindow) screen=\(window.convertPoint(toScreen: event.locationInWindow)) global=\(NSEvent.mouseLocation) frame=\(window.photoFrame)\n"
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: path) { defer { try? handle.close() }; try? handle.seekToEnd(); try? handle.write(contentsOf: Data(message.utf8)) }
        #endif
    }

    override func cancelOperation(_ sender: Any?) {
        if (window as? DesktopPhotoWindow)?.cancelBackgroundGesture() == true { return }
        guard dragMode != .none, let win = window as? DesktopPhotoWindow else { return }
        dragMode = .none
        collageOwnsPlacement = false
        win.onCollageDragCancelled?()
        SnapGuideOverlay.shared.hide()
        SnapEngine.shared.endDrag()
    }

    // MARK: - Scroll wheel → opacity

    override func scrollWheel(with event: NSEvent) {
        guard !isLocked else { return }
        let delta = event.deltaY * 0.02
        guard let photoWindow = window as? DesktopPhotoWindow else { return }
        let newAlpha = max(0.1, min(1.0, photoWindow.configuredOpacity + delta))
        // The manager saves the requested value before changing live alpha,
        // just as it does for the Settings slider. A failed save leaves it alone.
        onOpacityChanged?(newAlpha)
    }

    // MARK: - Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let historyItems = arrangementMenuItems?() ?? []
        for item in historyItems { menu.addItem(item) }
        if !historyItems.isEmpty { menu.addItem(.separator()) }

        let lockItem = NSMenuItem(
            title: lockActionTitle,
            action: #selector(handleLockToggle),
            keyEquivalent: ""
        )
        lockItem.target = self
        menu.addItem(lockItem)

        menu.addItem(.separator())

        // Overlapping photos had no way to be reordered at all short of hiding one.
        let grouped = (window as? DesktopPhotoWindow)?.isCollageMember?() ?? false
        let frontItem = NSMenuItem(title: grouped ? "Bring Collage to Front" : "Bring to Front", action: #selector(handleBringToFront), keyEquivalent: "")
        frontItem.target = self
        menu.addItem(frontItem)

        let backItem = NSMenuItem(title: grouped ? "Send Collage to Back" : "Send to Back", action: #selector(handleSendToBack), keyEquivalent: "")
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
    override var mouseDownCanMoveWindow: Bool { false }
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
