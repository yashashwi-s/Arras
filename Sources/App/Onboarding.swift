import AppKit
import SwiftUI

/// Installation-local progress. Closing or skipping the tour is a complete choice,
/// and an existing library never earns an unsolicited welcome window after an update.
@MainActor
final class OnboardingProgress {
    static let completedKey = "onboarding.welcomeCompleted"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    var isComplete: Bool { defaults.bool(forKey: Self.completedKey) }

    func shouldPresent(hasLibrary: Bool, needsRecovery: Bool) -> Bool {
        guard !isComplete else { return false }
        if hasLibrary || needsRecovery {
            complete()
            return false
        }
        return true
    }

    func complete() { defaults.set(true, forKey: Self.completedKey) }
}

/// A separate, reusable tour window. It never replaces Settings or creates desktop
/// widgets until the user explicitly chooses the sample on the final page.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let progress: OnboardingProgress
    private let manager: PhotoManager
    private let onFinish: () -> Void

    init(progress: OnboardingProgress, manager: PhotoManager, onFinish: @escaping () -> Void) {
        self.progress = progress
        self.manager = manager
        self.onFinish = onFinish
    }

    func show() {
        if let window {
            if !window.isOnActiveSpace { window.orderOut(nil) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to Arras"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 560)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: OnboardingView(manager: manager) { [weak self] in
            self?.window?.close()
        })
        window.delegate = self
        window.center()
        if let visible = window.screen?.visibleFrame {
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        progress.complete()
        window = nil
        onFinish()
    }
}
