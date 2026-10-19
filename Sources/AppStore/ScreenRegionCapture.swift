import AppKit
import ScreenCaptureKit

struct ScreenCaptureRegion {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect

    /// AppKit positions displays from the bottom left; ScreenCaptureKit uses display-local
    /// coordinates from the top left. Keeping this in points also supports Retina displays.
    static func sourceRect(selection: CGRect, screen: CGRect) -> CGRect? {
        let clipped = selection.standardized.intersection(screen)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return CGRect(x: clipped.minX - screen.minX, y: screen.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }
}

@MainActor
enum ScreenRegionCapture {
    static func capture(_ region: ScreenCaptureRegion) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((region.sourceRect.width * scale).rounded()))
        configuration.height = max(1, Int((region.sourceRect.height * scale).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: image, size: region.sourceRect.size)
    }

    private enum CaptureError: LocalizedError {
        case displayUnavailable
        var errorDescription: String? { "That display is no longer available. Try capturing the region again." }
    }
}

/// Transient selection overlays. Only the selected display region is captured, after every
/// overlay is removed. Cancelling resumes the request without writing any temporary image.
@MainActor
final class ScreenRegionSelector {
    private static var active: ScreenRegionSelector?
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<ScreenCaptureRegion?, Never>?
    private var observers: [NSObjectProtocol] = []

    static func select() async -> ScreenCaptureRegion? {
        guard active == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let selector = ScreenRegionSelector()
            selector.continuation = continuation
            active = selector
            selector.present()
        }
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityLabel("Drag to select a screen region. Press Escape to cancel.")
            view.didFinish = { [weak self] rect in
                let region = rect.flatMap { ScreenCaptureRegion.sourceRect(selection: $0, screen: screen.frame) }
                    .map { ScreenCaptureRegion(displayID: number.uint32Value, sourceRect: $0) }
                self?.finish(region)
            }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else { finish(nil); return }
        let pointer = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(pointer) } ?? panels[0]).makeKey()
        // A disconnected/rearranged display invalidates the region's coordinate system.
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(nil) }
            })
        }
    }

    private func finish(_ region: ScreenCaptureRegion?) {
        guard let continuation else { return }
        self.continuation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        Self.active = nil
        continuation.resume(returning: region)
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionSelectionView: NSView {
    var screenFrame = CGRect.zero
    var didFinish: ((CGRect?) -> Void)?
    private var anchor: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        shade.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        let hint = "Drag to capture a region · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (hint as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - 90,
                          width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -16, dy: -10), xRadius: 10, yRadius: 10).fill()
        (hint as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        mouseDragged(with: event)
        anchor = nil
        guard selection.width >= 2, selection.height >= 2 else {
            selection = .zero
            needsDisplay = true
            return
        }
        didFinish?(selection.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { didFinish?(nil) }
        else { super.keyDown(with: event) }
    }
}
