import AppKit

/// Foreground text has no material and receives no input. Keeping it independent
/// of the glass prevents a label over a photo from raising the glass over it.
@MainActor
final class CollageLabelWindow: NSPanel {
    private let textView = CollageTextView(frame: .zero)
    private var lastSettings: DesktopCollageSettings?
    private var lastBounds: CGRect?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        // Text follows the collage's placement and explicit scene transitions.
        animationBehavior = .none
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        contentView = textView
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.staticText)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func update(from parent: CollageDesktopWindow) {
        let bounds = parent.displayedBounds
        if level != parent.level { level = parent.level }
        if collectionBehavior != parent.collectionBehavior { collectionBehavior = parent.collectionBehavior }
        if sharingType != parent.sharingType { sharingType = parent.sharingType }
        let alpha = parent.contentView?.alphaValue ?? 1
        if alphaValue != alpha { alphaValue = alpha }
        // Compare requested scene sizes, not WindowServer-rounded panel sizes.
        // A translation needs no display request or content-frame assignment.
        let sizeChanged = lastBounds?.size != bounds.size
        if sizeChanged {
            setFrame(bounds, display: true)
            textView.frame = CGRect(origin: .zero, size: bounds.size)
        } else if frame.origin != bounds.origin {
            setFrameOrigin(bounds.origin)
        }
        if lastSettings != parent.settings || sizeChanged {
            lastSettings = parent.settings
            textView.layouts = CollageLabelLayout.layouts(settings: parent.settings, in: textView.bounds)
            textView.setAccessibilityLabel(parent.settings.textLabels.map(\.text).filter { !$0.isEmpty }.joined(separator: ", "))
        }
        lastBounds = bounds
    }
}

@MainActor
extension PhotoManager {
    func updateCollageLabels(_ id: UUID) {
        guard let parent = windows[id] as? CollageDesktopWindow else {
            collageLabelWindows.removeValue(forKey: id)?.close()
            return
        }
        guard parent.isVisible,
              parent.settings.textLabels.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.style.opacity > 0 }) else {
            // Depth changes temporarily order the parent out. Preserve its text
            // panel identity until an explicit hide/remove ends the composition.
            collageLabelWindows[id]?.orderOut(nil)
            return
        }
        // An existing panel can follow scene geometry without being ordered.
        // Querying its parent's active Space is a synchronous WindowServer call;
        // reserve it for showing or changing the panel's placement.
        if let overlay = collageLabelWindows[id], overlay.isVisible,
           overlay.level == parent.level,
           overlay.collectionBehavior == parent.collectionBehavior {
            overlay.update(from: parent)
            return
        }
        // Ordering an off-Space label with moveToActiveSpace would detach it
        // from its collage. Preserve this guard when placement needs changing.
        guard parent.isOnActiveSpace else { return }
        let overlay = collageLabelWindows[id] ?? CollageLabelWindow()
        collageLabelWindows[id] = overlay
        overlay.update(from: parent)
        if !overlay.isVisible { overlay.orderFront(nil) }
    }

    func orderCollageLabels(at level: NSWindow.Level) {
        for parent in photos where parent.desktopCollage != nil && windows[parent.id]?.level == level {
            orderCollageLabels(parent.id)
        }
    }

    func orderCollageLabels(_ id: UUID) {
        updateCollageLabels(id)
        guard let parent = windows[id], let overlay = collageLabelWindows[id], parent.isOnActiveSpace, overlay.isVisible else { return }
        // All photo panels at this depth precede text. The transparent overlay
        // never becomes a snapping target or a second pointer destination.
        let visible = photos.filter { $0.desktopCollage == nil && windows[$0.id]?.isVisible == true && windows[$0.id]?.isOnActiveSpace == true && windows[$0.id]?.level == parent.level }
            .sorted { $0.stackOrder > $1.stackOrder }
        let active = Set(collageDrags.filter { $0.value.parentID == id || $0.value.targetID == id }.map(\.key))
        let top = (visible.last { active.contains($0.id) } ?? visible.first).flatMap { windows[$0.id] } ?? parent
        overlay.order(.above, relativeTo: top.windowNumber)
    }
}
