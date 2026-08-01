import AppKit

/// Computes magnetic snap adjustments for a photo widget being dragged.
///
/// Targets are gathered once per drag, in `beginDrag(for:)`. Nothing on screen moves while
/// the user is dragging a desktop widget, so re-querying the window server on every
/// `mouseDragged` would burn a cross-process round trip per event for data that cannot have
/// changed — and this app's idle and drag cost is a stated feature.
///
/// Everything here works in *visual* rect space — the outermost opaque edge of the widget,
/// mat included. The window is deliberately larger than that (see `PhotoCanvas`), and
/// snapping window frames is what made the old engine feel broken: at default settings the
/// window edge sat 23pt outside the photo, so a guide drawn on a screen edge left the photo
/// 23pt away from it. Since that is 2.6x the engage threshold, visually correct edge
/// alignment was not merely inaccurate, it was unreachable.
final class SnapEngine {
    static let shared = SnapEngine()
    private init() {}

    /// How close a proposed edge must land before it locks on, and how far it must then be
    /// pulled before it lets go. A single threshold makes a snap engage and disengage on
    /// alternating events when the cursor sits right at the boundary; the gap between these
    /// two is what stops that flicker.
    private let engageThreshold: CGFloat = 8
    private let releaseThreshold: CGFloat = 16

    private let defaultsKey = "snapToEdgesEnabled"
    private let otherAppsKey = "snapToOtherAppsEnabled"

    /// Snapping preference, persisted in UserDefaults. An absent key is treated as "on" —
    /// snapping ships enabled by default.
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: defaultsKey) == nil
                || UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Whether other applications' windows and the system's desktop widgets act as alignment
    /// targets. Default on: reading window *bounds* from the window server needs no
    /// permission of any kind (only window titles are gated behind Screen Recording, and this
    /// never reads them), so there is nothing to prompt for and nothing to opt into.
    var includesOtherApps: Bool {
        get {
            UserDefaults.standard.object(forKey: otherAppsKey) == nil
                || UserDefaults.standard.bool(forKey: otherAppsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: otherAppsKey) }
    }

    /// Lower number wins when two targets are equally close, so a sibling widget beats a
    /// screen edge beats another app's window beats a speculative grid line.
    private enum Priority: Int {
        case widget = 0
        case screen = 1
        case otherApp = 2
        case lattice = 3
    }

    private struct Target {
        let value: CGFloat
        let extentStart: CGFloat
        let extentEnd: CGFloat
        let priority: Priority
        let style: SnapGuide.Style
    }

    private struct Lock {
        let candidate: Int
        let target: Target
    }

    private var xTargets: [Target] = []
    private var yTargets: [Target] = []
    private var lockedX: Lock?
    private var lockedY: Lock?

    // MARK: - Drag lifecycle

    /// Snapshots every alignment target for the drag about to start.
    func beginDrag(for window: DesktopPhotoWindow) {
        xTargets = []
        yTargets = []
        lockedX = nil
        lockedY = nil
        guard isEnabled else { return }

        // Only screens the widget could plausibly reach during this drag.
        for screen in NSScreen.screens {
            addRect(screen.visibleFrame, priority: .screen, style: .solid)
            // The true screen edges too — with the Dock showing, visibleFrame alone makes the
            // real bottom of the screen unreachable.
            addRect(screen.frame, priority: .screen, style: .solid)
            // The 8pt gutter the system's own desktop widgets sit in. Matching it is what
            // makes an Arras widget look placed rather than dropped.
            addRect(screen.visibleFrame.insetBy(dx: 8, dy: 8), priority: .screen, style: .solid)
        }

        for other in NSApp.windows.compactMap({ $0 as? DesktopPhotoWindow }) {
            guard other !== window, other.isVisible else { continue }
            addRect(other.visualFrame, priority: .widget, style: .solid)
        }

        guard includesOtherApps else { return }

        let (appWindows, systemWidgets) = onScreenWindowRects()
        for rect in appWindows {
            addRect(rect, priority: .otherApp, style: .solid)
        }
        for rect in systemWidgets {
            addRect(rect, priority: .screen, style: .solid)
        }
        addSystemWidgetLattice()
    }

    func endDrag() {
        xTargets = []
        yTargets = []
        lockedX = nil
        lockedY = nil
    }

    private func addRect(_ r: NSRect, priority: Priority, style: SnapGuide.Style) {
        guard r.width > 0, r.height > 0 else { return }
        xTargets.append(Target(value: r.minX, extentStart: r.minY, extentEnd: r.maxY, priority: priority, style: style))
        xTargets.append(Target(value: r.maxX, extentStart: r.minY, extentEnd: r.maxY, priority: priority, style: style))
        xTargets.append(Target(value: r.midX, extentStart: r.minY, extentEnd: r.maxY, priority: priority, style: style))
        yTargets.append(Target(value: r.minY, extentStart: r.minX, extentEnd: r.maxX, priority: priority, style: style))
        yTargets.append(Target(value: r.maxY, extentStart: r.minX, extentEnd: r.maxX, priority: priority, style: style))
        yTargets.append(Target(value: r.midY, extentStart: r.minX, extentEnd: r.maxX, priority: priority, style: style))
    }

    // MARK: - Snapping

    /// Returns the snapped *photo* origin plus any guide lines to draw.
    ///
    /// `proposedOrigin` MUST be the true, unsnapped drag position — accumulated straight from
    /// raw mouse deltas, never read back from the window's on-screen frame. Feeding this an
    /// already-snapped origin compounds the offset on every event, making the widget lag
    /// behind or run away from the cursor.
    func snappedOrigin(
        for window: DesktopPhotoWindow,
        proposedOrigin: NSPoint,
        size: NSSize,
        matInset: CGFloat,
        modifiers: NSEvent.ModifierFlags,
        dragStart: NSPoint
    ) -> (origin: NSPoint, guides: [SnapGuide]) {
        var proposed = proposedOrigin

        // Shift constrains the drag to whichever axis has moved further, the same convention
        // every canvas app uses.
        if modifiers.contains(.shift) {
            if abs(proposed.x - dragStart.x) > abs(proposed.y - dragStart.y) {
                proposed.y = dragStart.y
            } else {
                proposed.x = dragStart.x
            }
        }

        // Command suspends snapping outright, for placing something a few points off a guide.
        guard isEnabled, !modifiers.contains(.command) else {
            lockedX = nil
            lockedY = nil
            return (proposed, [])
        }

        // Snap the visible edge, not the window's.
        let visualOrigin = NSPoint(x: proposed.x - matInset, y: proposed.y - matInset)
        let visualSize = NSSize(width: size.width + matInset * 2, height: size.height + matInset * 2)

        let candidatesX = [visualOrigin.x, visualOrigin.x + visualSize.width / 2, visualOrigin.x + visualSize.width]
        let candidatesY = [visualOrigin.y, visualOrigin.y + visualSize.height / 2, visualOrigin.y + visualSize.height]

        let bestX = resolve(candidates: candidatesX, targets: xTargets, locked: &lockedX)
        let bestY = resolve(candidates: candidatesY, targets: yTargets, locked: &lockedY)

        var snapped = proposed
        var guides: [SnapGuide] = []

        if let bx = bestX {
            snapped.x += bx.delta
            // Extend the guide to cover whichever is larger: the target's own span or the
            // dragged widget's span, so the line reads clearly against both.
            let start = min(bx.target.extentStart, visualOrigin.y)
            let end = max(bx.target.extentEnd, visualOrigin.y + visualSize.height)
            guides.append(SnapGuide(orientation: .vertical, position: bx.target.value, start: start, end: end, style: bx.target.style))
        }
        if let by = bestY {
            snapped.y += by.delta
            let start = min(by.target.extentStart, visualOrigin.x)
            let end = max(by.target.extentEnd, visualOrigin.x + visualSize.width)
            guides.append(SnapGuide(orientation: .horizontal, position: by.target.value, start: start, end: end, style: by.target.style))
        }

        return (snapped, guides)
    }

    /// Picks the target to follow on one axis, holding on to the previous one until the drag
    /// has clearly pulled away from it.
    private func resolve(candidates: [CGFloat], targets: [Target], locked: inout Lock?) -> (delta: CGFloat, target: Target)? {
        if let held = locked {
            let delta = held.target.value - candidates[held.candidate]
            if abs(delta) < releaseThreshold { return (delta, held.target) }
            locked = nil
        }

        var best: (delta: CGFloat, target: Target, candidate: Int)?
        for (index, candidate) in candidates.enumerated() {
            for target in targets {
                let delta = target.value - candidate
                guard abs(delta) < engageThreshold else { continue }
                guard let current = best else {
                    best = (delta, target, index)
                    continue
                }
                let closer = abs(delta) < abs(current.delta) - 0.01
                let tied = abs(abs(delta) - abs(current.delta)) <= 0.01
                if closer || (tied && target.priority.rawValue < current.target.priority.rawValue) {
                    best = (delta, target, index)
                }
            }
        }

        guard let winner = best else { return nil }
        locked = Lock(candidate: winner.candidate, target: winner.target)
        return (winner.delta, winner.target)
    }

    // MARK: - Other applications' windows

    /// On-screen window rects, split into ordinary app windows and the system's desktop
    /// widgets, converted into AppKit's bottom-left-origin screen space.
    ///
    /// Reads only `kCGWindowBounds`, `kCGWindowLayer`, `kCGWindowOwnerPID` and
    /// `kCGWindowAlpha`, none of which are gated by TCC. `kCGWindowName` is the one key that
    /// requires Screen Recording, and it is deliberately never touched — asking for that
    /// permission to align a photo would be an absurd trade.
    private func onScreenWindowRects() -> (appWindows: [NSRect], systemWidgets: [NSRect]) {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ([], [])
        }

        // CGWindowList coordinates are flipped and rooted at the top-left of the display whose
        // AppKit origin is (0,0). Index 0 of NSScreen.screens is not reliably that display.
        guard let base = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.maxY else {
            return ([], [])
        }

        let myPid = ProcessInfo.processInfo.processIdentifier
        let widgetLayer = Int(CGWindowLevelForKey(.desktopIconWindow)) + 2

        var appWindows: [NSRect] = []
        var systemWidgets: [NSRect] = []

        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 40, cgRect.height >= 40 else { continue }

            // Invisible keep-alive windows are real and would produce phantom guides.
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.05 { continue }

            let rect = NSRect(x: cgRect.minX, y: base - cgRect.maxY, width: cgRect.width, height: cgRect.height)
            // The login window parks a 30000x30000 rect off-screen; anything that doesn't
            // touch a real display is not something the user can align to.
            guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { continue }

            if layer == 0 {
                appWindows.append(rect)
            } else if layer == widgetLayer {
                systemWidgets.append(rect)
            }
        }

        return (appWindows, systemWidgets)
    }

    /// Speculative grid lines for the empty cells of the system desktop-widget grid.
    ///
    /// The occupied cells are already covered by the real window rects above; this only
    /// extrapolates the rest of the lattice so a widget can be aligned to a slot nothing is
    /// sitting in yet. The 8pt gutter and 180pt pitch were measured against this machine's
    /// widget placement store and confirmed against the live window bounds, but neither is
    /// documented by Apple and neither was tested across display scales — so these are drawn
    /// dotted, ranked below everything else, and are harmless if the pitch is ever wrong.
    private func addSystemWidgetLattice() {
        let pitch: CGFloat = 180
        let gutter: CGFloat = 8

        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            let originX = vf.minX + gutter
            let originTopY = vf.maxY - gutter

            let columns = Int((vf.width - gutter) / pitch)
            let rows = Int((vf.height - gutter) / pitch)
            guard columns > 0, rows > 0 else { continue }

            for column in 0...columns {
                let x = originX + pitch * CGFloat(column)
                guard x <= vf.maxX else { break }
                xTargets.append(Target(value: x, extentStart: vf.minY, extentEnd: vf.maxY, priority: .lattice, style: .dotted))
            }
            for row in 0...rows {
                let y = originTopY - pitch * CGFloat(row)
                guard y >= vf.minY else { break }
                yTargets.append(Target(value: y, extentStart: vf.minX, extentEnd: vf.maxX, priority: .lattice, style: .dotted))
            }
        }
    }
}

// MARK: - Guide Model

/// A single alignment line to render, in global screen coordinates (origin bottom-left).
struct SnapGuide {
    enum Orientation { case vertical, horizontal }

    /// Solid for a real edge that exists on screen; dotted for an extrapolated grid line, so
    /// the user can tell "aligned to that window" from "aligned to where a widget would go".
    enum Style { case solid, dotted }

    let orientation: Orientation
    /// x for vertical guides, y for horizontal guides.
    let position: CGFloat
    /// Perpendicular-axis span the line should be drawn across.
    let start: CGFloat
    let end: CGFloat
    let style: Style
}
