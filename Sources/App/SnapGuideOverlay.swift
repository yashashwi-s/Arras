import AppKit

/// A borderless, click-through overlay that renders temporary alignment lines while a
/// photo widget is being dragged. Kept as a single window sized to whichever screen the
/// drag is currently on, rather than one window per photo, since only one drag can be
/// in flight at a time and reusing the same window avoids alloc/dealloc churn per event.
final class SnapGuideOverlay: NSWindow {
    static let shared = SnapGuideOverlay()

    private let guideView = GuideDrawingView()

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

        // Above both desktop- and floating-level photo windows so guides are always visible
        // over whatever is being dragged.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)

        contentView = guideView

        // Singleton that's ordered out, never closed — isReleasedWhenClosed is irrelevant
        // here since close() is never called, but set explicitly to document the intent.
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Displays `guides` over `screen`. Passing an empty array hides the overlay.
    func show(_ guides: [SnapGuide], on screen: NSScreen) {
        guard !guides.isEmpty else {
            hide()
            return
        }

        if frame != screen.frame {
            setFrame(screen.frame, display: false)
        }

        let origin = screen.frame.origin
        guideView.frame = NSRect(origin: .zero, size: screen.frame.size)
        guideView.segments = guides.map { guide -> (NSPoint, NSPoint) in
            switch guide.orientation {
            case .vertical:
                let x = guide.position - origin.x
                return (NSPoint(x: x, y: guide.start - origin.y), NSPoint(x: x, y: guide.end - origin.y))
            case .horizontal:
                let y = guide.position - origin.y
                return (NSPoint(x: guide.start - origin.x, y: y), NSPoint(x: guide.end - origin.x, y: y))
            }
        }
        guideView.needsDisplay = true

        if !isVisible {
            orderFront(nil)
        }
    }

    func hide() {
        guard isVisible else { return }
        guideView.segments = []
        orderOut(nil)
    }
}

// MARK: - Drawing

private final class GuideDrawingView: NSView {
    var segments: [(NSPoint, NSPoint)] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !segments.isEmpty else { return }

        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
        for (start, end) in segments {
            ctx.move(to: start)
            ctx.addLine(to: end)
        }
        ctx.strokePath()
    }
}
