import AppKit
import UniformTypeIdentifiers

/// Transparent overlay on the status bar button that accepts dropped images.
///
/// `NSStatusItem` gives us its button but no way to subclass it, and AppKit finds
/// a drag destination by hit-testing — so a view that declines hit tests would
/// never receive the drop. This view therefore *does* claim hit tests and hands
/// mouse events back to the button underneath, which keeps the menu working.
final class StatusItemDropView: NSView {

    /// Called with the dropped image file URLs.
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Mouse pass-through

    // The status button owns click handling (it pops the menu); we only exist for
    // drags, so every mouse event goes straight back to it.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { superview?.otherMouseDown(with: event) }

    // MARK: - Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !imageURLs(from: sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !imageURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = imageURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    /// Dropped file URLs that point at images we can decode.
    private func imageURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: PhotoManager.importableTypes.map(\.identifier)
        ]
        return sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
    }

    // MARK: - Drop feedback

    /// Mirrors the button's own pressed appearance so a hovering drag reads as
    /// a valid target.
    private var highlighted = false {
        didSet {
            guard highlighted != oldValue else { return }
            (superview as? NSStatusBarButton)?.highlight(highlighted)
        }
    }
}
