import AppKit

// MARK: - Presence detection

/// Best-effort and reliable signals for keeping photo widgets out of places they don't
/// belong, gathered in one place since they share the same "auto-hide without touching
/// the user's own isVisible" contract that PhotoManager applies on top.
///
/// Two genuinely different strengths of guarantee live here -- do not blur them:
///
/// - `excludeFromScreenCapture` drives `NSWindow.sharingType = .none`, enforced by the
///   window server itself. Any capture that goes through the normal window-server
///   compositing path -- ScreenCaptureKit, `CGWindowListCreateImage`, QuickTime screen
///   recording, and every video-conferencing app's screen/window share -- simply never
///   sees a window with this set. It's the same mechanism macOS uses to hide password
///   fields during screen sharing, needs no detection at all, and so has no false
///   positives or negatives. It does **not** cover a physical mirror of the display --
///   AirPlay Mirroring, an HDMI capture dongle -- since those copy the raw framebuffer
///   rather than asking the window server for a picture.
/// - `autoHideForConferencingApps` and `hideWhenFullscreenActive` are heuristics. There
///   is no public API on macOS to ask "is my screen being captured right now." A running
///   Zoom process doesn't mean a meeting is live, a live meeting doesn't mean the screen
///   (rather than just the camera) is being shared, and a browser tab running Google Meet
///   is invisible to a bundle-identifier check entirely. Ship these as best-effort extras
///   layered on top of the real guarantee above, never as a replacement for it.
@MainActor
final class PresenceMonitor {

    // MARK: Known conferencing/recording apps

    /// Bundle identifiers whose presence is a reasonable, not certain, signal that a call
    /// or recording might be under way. `com.apple.QuickTimePlayerX` and
    /// `com.apple.screenshot.launcher` were confirmed directly against a local macOS
    /// install; `us.zoom.xos` and the Teams identifiers are widely documented but
    /// unverifiable here since neither app is installed in this environment. Deliberately
    /// short: a longer list doesn't buy accuracy, since browser-based conferencing (Meet,
    /// or Teams/Zoom running inside a browser tab) is invisible to this check no matter
    /// how many bundle IDs are on it.
    static let conferencingBundleIDs: Set<String> = [
        "us.zoom.xos",                   // Zoom
        "com.microsoft.teams2",          // Microsoft Teams (current)
        "com.microsoft.teams",           // Microsoft Teams (classic, still in use)
        "com.apple.QuickTimePlayerX",    // QuickTime Player screen recording
        "com.apple.screenshot.launcher", // Screenshot.app (Cmd+Shift+5) screen recording
        "com.obsproject.obs-studio",     // OBS Studio
    ]

    // MARK: UserDefaults-backed preferences

    private enum Keys {
        static let exclude = "presence.excludeFromScreenCapture"
        static let autoHideConferencing = "presence.autoHideForConferencingApps"
        static let hideFullscreen = "presence.hideWhenFullscreenActive"
    }

    private(set) var excludeFromScreenCapture: Bool
    private(set) var autoHideForConferencingApps: Bool
    private(set) var hideWhenFullscreenActive: Bool

    // MARK: Detected state (read-only; informational for the Settings UI)

    private(set) var isConferencingAppRunning = false
    private(set) var isFullscreenActive = false

    /// Whether either enabled global heuristic currently says "hide".
    var shouldSuppressForPresence: Bool {
        (autoHideForConferencingApps && isConferencingAppRunning) ||
        (hideWhenFullscreenActive && isFullscreenActive)
    }

    /// Fires whenever any preference or detected value above changes. Callers aren't told
    /// which one -- both things PhotoManager does in response (re-apply sharingType,
    /// re-evaluate window suppression) are cheap and idempotent, so there's nothing to
    /// gain from tracking that more precisely.
    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        excludeFromScreenCapture = defaults.bool(forKey: Keys.exclude)
        autoHideForConferencingApps = defaults.bool(forKey: Keys.autoHideConferencing)
        hideWhenFullscreenActive = defaults.bool(forKey: Keys.hideFullscreen)

        checkConferencingApps()
        checkFullscreen()

        // Event-driven, not polled: NSWorkspace already posts these on launch/terminate
        // and on app activation/Space changes, which is exactly when either detection
        // could change. A timer here would cost idle CPU for no benefit.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkConferencingApps() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkConferencingApps() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkFullscreen() }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkFullscreen() }
        }
    }

    // MARK: Preference setters

    func setExcludeFromScreenCapture(_ enabled: Bool) {
        guard enabled != excludeFromScreenCapture else { return }
        excludeFromScreenCapture = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.exclude)
        onChange?()
    }

    func setAutoHideForConferencingApps(_ enabled: Bool) {
        guard enabled != autoHideForConferencingApps else { return }
        autoHideForConferencingApps = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.autoHideConferencing)
        onChange?()
    }

    func setHideWhenFullscreenActive(_ enabled: Bool) {
        guard enabled != hideWhenFullscreenActive else { return }
        hideWhenFullscreenActive = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.hideFullscreen)
        onChange?()
    }

    // MARK: Detection

    private func checkConferencingApps() {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier.map(Self.conferencingBundleIDs.contains) ?? false
        }
        guard running != isConferencingAppRunning else { return }
        isConferencingAppRunning = running
        onChange?()
    }

    /// Heuristic, not a query: macOS has no public API to ask whether another app is
    /// currently fullscreen. A fullscreen app takes over its own Space and macOS
    /// auto-hides that screen's menu bar as a side effect, which makes `visibleFrame`
    /// (the area excluding the menu bar/Dock) grow to match `frame` exactly -- so this
    /// checks for that rather than anything about the frontmost app directly. Checked
    /// across all screens, since the fullscreen Space isn't necessarily the one
    /// `NSScreen.main` currently points at.
    ///
    /// Known to misfire in both directions: a user with Displays > "Automatically hide
    /// and show the menu bar" set to Always (not just "In Full Screen") reads as
    /// permanently fullscreen even on the plain desktop; a borderless window that merely
    /// covers the whole screen without being a real fullscreen Space could in principle
    /// trip it too. A fully reliable signal would need Accessibility permission or a
    /// private API, both ruled out for this app.
    private func checkFullscreen() {
        let fullscreen = NSScreen.screens.contains { $0.frame == $0.visibleFrame }
        guard fullscreen != isFullscreenActive else { return }
        isFullscreenActive = fullscreen
        onChange?()
    }
}
