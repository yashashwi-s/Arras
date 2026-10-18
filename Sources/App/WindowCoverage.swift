import AppKit

struct CoverageWindow {
    let id: Int
    let bounds: CGRect
    let layer: Int
    let alpha: Double
}

/// WindowServer lists windows front to back. Geometry is sufficient for this energy policy;
/// no window titles, screenshots, Accessibility access, or pixel contents are read.
enum WindowCoveragePolicy {
    static func isCovered(windowID: Int, contentBounds: CGRect, windows: [CoverageWindow]) -> Bool {
        guard !contentBounds.isEmpty,
              let target = windows.firstIndex(where: { $0.id == windowID }) else { return false }
        return windows[..<target].contains { candidate in
            // Desktop backgrounds/icon surfaces are not app content. Ignore invisible helper
            // windows, and mere edge contact, but pause for any actual app-window overlap.
            guard candidate.layer >= 0, candidate.alpha > 0.05 else { return false }
            let overlap = contentBounds.intersection(candidate.bounds)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }

    /// Convert the photo rectangle using its own WindowServer bounds. This also works on
    /// displays above or left of the primary display, without assuming a primary screen height.
    static func contentBounds(photo: CGRect, appKitWindow: CGRect, serverWindow: CGRect) -> CGRect {
        CGRect(x: serverWindow.minX + photo.minX - appKitWindow.minX,
               y: serverWindow.minY + appKitWindow.maxY - photo.maxY,
               width: photo.width, height: photo.height)
    }
}

/// One metadata snapshot per tick for every widget, including while a covering app is dragged.
/// AppKit's occlusion notification alone does not fire for partial coverage changes.
@MainActor
final class WindowCoverageMonitor {
    static let shared = WindowCoverageMonitor()
    private let windows = NSHashTable<DesktopPhotoWindow>.weakObjects()
    private var timer: Timer?
    var isPolling: Bool { timer != nil }

    func add(_ window: DesktopPhotoWindow) {
        guard window.hasDynamicContent else { remove(window); return }
        windows.add(window)
        if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    func remove(_ window: DesktopPhotoWindow) {
        windows.remove(window)
        if windows.allObjects.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        let targets = windows.allObjects.filter { $0.isVisible && $0.hasDynamicContent }
        guard !targets.isEmpty else { return }
        // Other blockers already stop all expensive work. Avoid querying WindowServer while
        // sleeping or conserving energy; refresh on the next tick when those conditions end.
        guard RuntimeActivityPolicy.decision(for: RuntimeActivityInput(
            environment: RuntimeActivityCenter.shared.environment
        )).allowsExpensiveAnimation else { return }
        // Keep desktop entries: excluding them also removes Arras desktop-level widgets.
        // The policy filters background layers only among potential covering windows.
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return }
        // Caption/guide windows have large transparent canvases. Their window
        // rectangles are not covers, even when WindowServer briefly retains
        // an ordered-out panel after AppKit marks it invisible.
        let chromeIDs = Set(NSApp.windows.filter {
            $0 is CollageLabelWindow || $0 is SnapGuideOverlay
        }.map(\.windowNumber))
        let snapshot = info.compactMap { entry -> CoverageWindow? in
            guard let id = entry[kCGWindowNumber as String] as? Int,
                  !chromeIDs.contains(id),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            return CoverageWindow(id: id, bounds: rect, layer: layer,
                                  alpha: entry[kCGWindowAlpha as String] as? Double ?? 1)
        }
        for window in targets {
            guard let record = snapshot.first(where: { $0.id == window.windowNumber }) else {
                window.setCoveredByApp(false)
                continue
            }
            let bounds = WindowCoveragePolicy.contentBounds(
                photo: window.visualFrame, appKitWindow: window.frame, serverWindow: record.bounds
            )
            window.setCoveredByApp(WindowCoveragePolicy.isCovered(
                windowID: window.windowNumber, contentBounds: bounds, windows: snapshot
            ))
        }
    }
}
