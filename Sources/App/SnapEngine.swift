import AppKit

/// Computes magnetic snap adjustments for a photo widget being dragged, against screen
/// edges/centers and the edges/centers of other visible photo widgets.
///
/// The engine is deliberately stateless between drag events — it takes the drag's true,
/// unsnapped position and returns a (possibly adjusted) origin plus guide lines to draw.
/// Statelessness is what makes the "escape" feel natural: as soon as the true position
/// drifts more than `threshold` from every target, the engine simply stops proposing an
/// adjustment, with no leftover magnetism from the previous event.
final class SnapEngine {
    static let shared = SnapEngine()
    private init() {}

    /// How close (in points) a proposed edge/center must land next to a target before it
    /// locks on. Small enough to read as assistance rather than a sticky trap.
    private let threshold: CGFloat = 9

    private let defaultsKey = "snapToEdgesEnabled"

    /// Snapping preference, persisted in UserDefaults. No settings UI exists for this yet,
    /// so an absent key is treated as "on" — snapping ships enabled by default.
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: defaultsKey) == nil
                || UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private struct Target {
        let value: CGFloat
        let extentStart: CGFloat
        let extentEnd: CGFloat
    }

    /// Returns the snapped origin (identical to `proposedOrigin` when nothing is in range)
    /// plus any guide lines that should be drawn for the match.
    ///
    /// `proposedOrigin` MUST be the true, unsnapped drag position — accumulated straight from
    /// raw mouse deltas, never read back from the window's on-screen frame. The caller owns
    /// that accumulator; feeding this function an already-snapped origin would compound the
    /// snap offset on every subsequent event, making the widget lag behind or run away from
    /// the cursor instead of just visually assisting the drag.
    func snappedOrigin(for window: NSWindow, proposedOrigin: NSPoint, size: NSSize) -> (origin: NSPoint, guides: [SnapGuide]) {
        guard isEnabled else { return (proposedOrigin, []) }

        var xTargets: [Target] = []
        var yTargets: [Target] = []

        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            xTargets.append(Target(value: vf.minX, extentStart: vf.minY, extentEnd: vf.maxY))
            xTargets.append(Target(value: vf.maxX, extentStart: vf.minY, extentEnd: vf.maxY))
            xTargets.append(Target(value: vf.midX, extentStart: vf.minY, extentEnd: vf.maxY))
            yTargets.append(Target(value: vf.minY, extentStart: vf.minX, extentEnd: vf.maxX))
            yTargets.append(Target(value: vf.maxY, extentStart: vf.minX, extentEnd: vf.maxX))
            yTargets.append(Target(value: vf.midY, extentStart: vf.minX, extentEnd: vf.maxX))
        }

        for other in NSApp.windows.compactMap({ $0 as? DesktopPhotoWindow }) {
            guard other !== window, other.isVisible else { continue }
            let f = other.frame
            xTargets.append(Target(value: f.minX, extentStart: f.minY, extentEnd: f.maxY))
            xTargets.append(Target(value: f.maxX, extentStart: f.minY, extentEnd: f.maxY))
            xTargets.append(Target(value: f.midX, extentStart: f.minY, extentEnd: f.maxY))
            yTargets.append(Target(value: f.minY, extentStart: f.minX, extentEnd: f.maxX))
            yTargets.append(Target(value: f.maxY, extentStart: f.minX, extentEnd: f.maxX))
            yTargets.append(Target(value: f.midY, extentStart: f.minX, extentEnd: f.maxX))
        }

        // Left edge, center, right edge — any of the three can lock onto any target independently.
        let candidatesX = [proposedOrigin.x, proposedOrigin.x + size.width / 2, proposedOrigin.x + size.width]
        let candidatesY = [proposedOrigin.y, proposedOrigin.y + size.height / 2, proposedOrigin.y + size.height]

        var bestX: (delta: CGFloat, target: Target)?
        for c in candidatesX {
            for t in xTargets {
                let d = t.value - c
                if abs(d) < threshold, bestX == nil || abs(d) < abs(bestX!.delta) {
                    bestX = (d, t)
                }
            }
        }

        var bestY: (delta: CGFloat, target: Target)?
        for c in candidatesY {
            for t in yTargets {
                let d = t.value - c
                if abs(d) < threshold, bestY == nil || abs(d) < abs(bestY!.delta) {
                    bestY = (d, t)
                }
            }
        }

        var snapped = proposedOrigin
        var guides: [SnapGuide] = []

        if let bx = bestX {
            snapped.x += bx.delta
            // Extend the guide to cover whichever is larger: the target's own span or the
            // dragged widget's span, so the line reads clearly against both.
            let start = min(bx.target.extentStart, proposedOrigin.y)
            let end = max(bx.target.extentEnd, proposedOrigin.y + size.height)
            guides.append(SnapGuide(orientation: .vertical, position: bx.target.value, start: start, end: end))
        }
        if let by = bestY {
            snapped.y += by.delta
            let start = min(by.target.extentStart, proposedOrigin.x)
            let end = max(by.target.extentEnd, proposedOrigin.x + size.width)
            guides.append(SnapGuide(orientation: .horizontal, position: by.target.value, start: start, end: end))
        }

        return (snapped, guides)
    }
}

// MARK: - Guide Model

/// A single alignment line to render, in global screen coordinates (origin bottom-left).
struct SnapGuide {
    enum Orientation { case vertical, horizontal }

    let orientation: Orientation
    /// x for vertical guides, y for horizontal guides.
    let position: CGFloat
    /// Perpendicular-axis span the line should be drawn across.
    let start: CGFloat
    let end: CGFloat
}
