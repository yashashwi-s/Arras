import AppKit

/// A borderless, click-through overlay that renders temporary alignment lines while a
/// photo widget is being dragged. Kept as a single window sized to whichever screen the
/// drag is currently on, rather than one window per photo, since only one drag can be
/// in flight at a time and reusing the same window avoids alloc/dealloc churn per event.
///
/// The lines are CALayers whose frames are assigned per event, not a `draw(_:)` pass. The
/// previous version invalidated a screen-sized view — 5.4 megapixels of backing store at 2x —
/// on every single `mouseDragged`, to stroke two one-pixel lines. Handing the compositing to
/// the render server is the same discipline GIF playback follows here, for the same reason.
final class SnapGuideOverlay: NSWindow {
    static let shared = SnapGuideOverlay()

    private let guideView = NSView()
    private var lineLayers: [CALayer] = []

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true

        // Drag-time chrome, not desktop content: keep it out of Mission Control/Exposé
        // thumbnails (.transient, .ignoresCycle) and out of other apps' screen captures
        // (.sharingType = .none), since neither reflects anything the user placed on screen.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        sharingType = .none

        guideView.wantsLayer = true
        contentView = guideView

        // Singleton that's ordered out, never closed — isReleasedWhenClosed is irrelevant
        // here since close() is never called, but set explicitly to document the intent.
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Displays `guides` over `screen`, just above the window being dragged. Passing an empty
    /// array hides the overlay.
    ///
    /// The level tracks the dragged widget rather than sitting at a fixed floating level: a
    /// desktop-level widget dragged behind an open app window would otherwise get guides
    /// painted on top of that app while the widget itself stayed hidden behind it.
    func show(_ guides: [SnapGuide], on screen: NSScreen, above draggedWindow: NSWindow) {
        guard !guides.isEmpty else {
            hide()
            return
        }

        let targetLevel = NSWindow.Level(rawValue: draggedWindow.level.rawValue + 1)
        if level != targetLevel { level = targetLevel }

        if frame != screen.frame {
            setFrame(screen.frame, display: false)
            guideView.frame = NSRect(origin: .zero, size: screen.frame.size)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let origin = screen.frame.origin
        for (index, guide) in guides.enumerated() {
            let line = layer(at: index)
            let colour = NSColor.controlAccentColor.withAlphaComponent(guide.style == .dotted ? 0.5 : 0.85)
            line.backgroundColor = colour.cgColor
            switch guide.orientation {
            case .vertical:
                line.frame = NSRect(
                    x: guide.position - origin.x,
                    y: guide.start - origin.y,
                    width: 1,
                    height: guide.end - guide.start
                )
            case .horizontal:
                line.frame = NSRect(
                    x: guide.start - origin.x,
                    y: guide.position - origin.y,
                    width: guide.end - guide.start,
                    height: 1
                )
            }
            line.isHidden = false
        }
        for index in guides.count..<lineLayers.count {
            lineLayers[index].isHidden = true
        }

        CATransaction.commit()

        if !isVisible {
            orderFront(nil)
        }
    }

    func hide() {
        guard isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayers.forEach { $0.isHidden = true }
        CATransaction.commit()
        orderOut(nil)
    }

    /// Two lines is the steady state (one per axis), so the pool never really grows; it exists
    /// so `show` can't allocate a layer per drag event.
    private func layer(at index: Int) -> CALayer {
        while lineLayers.count <= index {
            let line = CALayer()
            line.isHidden = true
            guideView.layer?.addSublayer(line)
            lineLayers.append(line)
        }
        return lineLayers[index]
    }
}
