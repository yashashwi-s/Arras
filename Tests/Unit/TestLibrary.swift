import AppKit
import XCTest
@testable import Arras

/// Own only scratch storage and windows created by the test; never use the user's library.
@MainActor
func withTestLibrary(_ body: (PhotoManager) throws -> Void) throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manager = PhotoManager(storageDirectory: root)
    defer {
        manager.cancelCollageInteractions(endAppearancePreviews: true)
        manager.windows.values.forEach { $0.hidePhoto() }
        manager.windows.removeAll()
        try? FileManager.default.removeItem(at: root)
    }
    try body(manager)
}

func photoDictionary(_ item: PhotoItem) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
}

/// Exercise AppKit gesture handling without moving the user's real mouse.
/// All test windows observe the same screen pointer, including forwarded events.
@MainActor
func testMouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint,
                    clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    for widget in NSApp.windows.compactMap({ $0 as? DesktopPhotoWindow }) { widget.pointerLocation = { point } }
    return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
}
