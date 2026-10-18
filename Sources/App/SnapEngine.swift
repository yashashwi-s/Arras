import AppKit

/// Computes magnetic snap adjustments for a photo widget being dragged.
///
/// Ordinary alignment targets are gathered once per drag, in `beginDrag(for:)`.
/// Collage backgrounds change during dragging and are excluded; their member
/// placement and gap guides belong to CollageGeometry.
///
/// Everything here works in *visual* rect space — the outermost opaque edge of the widget,
/// mat included. The window is deliberately larger than that (see `PhotoCanvas`), and
/// snapping window frames is what made the old engine feel broken: at default settings the
/// window edge sat 23pt outside the photo, so a guide drawn on a screen edge left the photo
/// 23pt away from it. Since that is 2.6x the engage threshold, visually correct edge
/// alignment was not merely inaccurate, it was unreachable.
final class SnapEngine {
    static let shared = SnapEngine()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// How close a proposed edge must land before it locks on, and how far it must then be
    /// pulled before it lets go. A single threshold makes a snap engage and disengage on
    /// alternating events when the cursor sits right at the boundary; the gap between these
    /// two is what stops that flicker.
    private let engageThreshold: CGFloat = 6
    private let releaseThreshold: CGFloat = 10

    private let defaultsKey = "snapToEdgesEnabled"
    private let otherAppsKey = "snapToOtherAppsEnabled"

    /// Snapping preference, persisted in UserDefaults. An absent key is treated as "on" —
    /// snapping ships enabled by default.
    var isEnabled: Bool {
        get {
            defaults.object(forKey: defaultsKey) == nil
                || defaults.bool(forKey: defaultsKey)
        }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    /// Whether other applications' windows and the system's desktop widgets act as alignment
    /// targets. Default on: reading window *bounds* from the window server needs no
    /// permission of any kind (only window titles are gated behind Screen Recording, and this
    /// never reads them), so there is nothing to prompt for and nothing to opt into.
    var includesOtherApps: Bool {
        get {
            defaults.object(forKey: otherAppsKey) == nil
                || defaults.bool(forKey: otherAppsKey)
        }
        set { defaults.set(newValue, forKey: otherAppsKey) }
    }

    /// Lower number wins when two targets are equally close, so a sibling widget beats a
    /// screen edge beats another app's window.
    private enum Priority: Int {
        case widget = 0
        case screen = 1
        case otherApp = 2
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
    @MainActor
    func beginDrag(for window: DesktopPhotoWindow, excluding excludedIDs: Set<UUID> = [], includeCollages: Bool = false) {
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
            guard other !== window, other.isVisible, other.photoId.map({ excludedIDs.contains($0) }) != true else { continue }
            if let collage = other as? CollageDesktopWindow {
                if includeCollages { addRect(collage.displayedBounds, priority: .widget, style: .solid) }
            } else {
                addRect(other.visualFrame, priority: .widget, style: .solid)
            }
        }

        guard includesOtherApps else { return }

        let (appWindows, systemWidgets) = onScreenWindowRects()
        for rect in appWindows {
            addRect(rect, priority: .otherApp, style: .solid)
        }
        for rect in systemWidgets {
            addRect(rect, priority: .screen, style: .solid)
        }
    }

    func endDrag() {
        xTargets = []
        yTargets = []
        lockedX = nil
        lockedY = nil
    }

    func clearLocks() { lockedX = nil; lockedY = nil }

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

    /// Resizing follows the pointer directly, as in 2.4.9. Show nearby
    /// alignments without a magnetic scale lock that makes the corner stick.
    func resizeGuides(for rect: CGRect, corner: CollageResizeCorner,
                      modifiers: NSEvent.ModifierFlags) -> [SnapGuide] {
        guard isEnabled, !modifiers.contains(.option), !modifiers.contains(.command) else { return [] }
        let anchor = corner.anchor(in: rect)
        var guides: [SnapGuide] = []
        for (orientation, targets, coordinates, fixed) in [
            (SnapGuide.Orientation.vertical, xTargets, [rect.minX, rect.midX, rect.maxX], anchor.x),
            (.horizontal, yTargets, [rect.minY, rect.midY, rect.maxY], anchor.y)
        ] {
            var winner: (target: Target, distance: CGFloat)?
            for coordinate in coordinates where abs(coordinate - fixed) > 0.001 {
                for target in targets where isNearby(target, span: perpendicularSpan(of: rect, orientation: orientation)) {
                    let distance = abs(target.value - coordinate)
                    guard distance < engageThreshold else { continue }
                    if winner == nil || distance < winner!.distance - 0.01 ||
                        (abs(distance - winner!.distance) <= 0.01 && target.priority.rawValue < winner!.target.priority.rawValue) {
                        winner = (target, distance)
                    }
                }
            }
            if let winner { guides.append(resizeGuide(winner.target, orientation: orientation, rect: rect)) }
        }
        return guides
    }

    private func perpendicularSpan(of rect: CGRect, orientation: SnapGuide.Orientation) -> ClosedRange<CGFloat> {
        orientation == .vertical ? rect.minY...rect.maxY : rect.minX...rect.maxX
    }

    private func resizeGuide(_ target: Target, orientation: SnapGuide.Orientation, rect: CGRect) -> SnapGuide {
        let start = orientation == .vertical ? rect.minY : rect.minX
        let end = orientation == .vertical ? rect.maxY : rect.maxX
        return SnapGuide(orientation: orientation, position: target.value,
                         start: min(start, target.extentStart), end: max(end, target.extentEnd), style: target.style)
    }

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
        var allowsX = true
        var allowsY = true

        // Shift constrains the drag to whichever axis has moved further, the same convention
        // every canvas app uses.
        if modifiers.contains(.shift) {
            if abs(proposed.x - dragStart.x) > abs(proposed.y - dragStart.y) {
                proposed.y = dragStart.y
                allowsY = false
            } else {
                proposed.x = dragStart.x
                allowsX = false
            }
        }

        // The same free-placement modifiers work inside and outside a collage.
        guard isEnabled, !modifiers.contains(.command), !modifiers.contains(.option) else {
            lockedX = nil
            lockedY = nil
            return (proposed, [])
        }

        // Snap the visible edge, not the window's.
        let visualOrigin = NSPoint(x: proposed.x - matInset, y: proposed.y - matInset)
        let visualSize = NSSize(width: size.width + matInset * 2, height: size.height + matInset * 2)

        let candidatesX = [visualOrigin.x, visualOrigin.x + visualSize.width / 2, visualOrigin.x + visualSize.width]
        let candidatesY = [visualOrigin.y, visualOrigin.y + visualSize.height / 2, visualOrigin.y + visualSize.height]

        if !allowsX { lockedX = nil }
        if !allowsY { lockedY = nil }
        let bestX = allowsX ? resolve(candidates: candidatesX, targets: xTargets,
                                     span: visualOrigin.y...(visualOrigin.y + visualSize.height), locked: &lockedX) : nil
        let bestY = allowsY ? resolve(candidates: candidatesY, targets: yTargets,
                                     span: visualOrigin.x...(visualOrigin.x + visualSize.width), locked: &lockedY) : nil

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
    private func resolve(candidates: [CGFloat], targets: [Target], span: ClosedRange<CGFloat>, locked: inout Lock?) -> (delta: CGFloat, target: Target)? {
        if let held = locked {
            let delta = held.target.value - candidates[held.candidate]
            if isNearby(held.target, span: span), abs(delta) < releaseThreshold { return (delta, held.target) }
            locked = nil
        }

        var best: (delta: CGFloat, target: Target, candidate: Int)?
        for (index, candidate) in candidates.enumerated() {
            for target in targets where isNearby(target, span: span) {
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

    // Keep alignment useful across a small gap, without attracting a photo to
    // unrelated windows or another display far along the perpendicular axis.
    private func isNearby(_ target: Target, span: ClosedRange<CGFloat>) -> Bool {
        let reach: CGFloat = target.priority == .screen ? releaseThreshold : 200
        return span.upperBound >= target.extentStart - reach
            && span.lowerBound <= target.extentEnd + reach
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


}

// MARK: - Guide Model

/// A single alignment line to render, in global screen coordinates (origin bottom-left).
struct SnapGuide {
    enum Orientation { case vertical, horizontal }

    /// Solid for edge alignment; dotted for equal-gap guides within a collage.
    enum Style { case solid, dotted }

    let orientation: Orientation
    /// x for vertical guides, y for horizontal guides.
    let position: CGFloat
    /// Perpendicular-axis span the line should be drawn across.
    let start: CGFloat
    let end: CGFloat
    let style: Style
}
