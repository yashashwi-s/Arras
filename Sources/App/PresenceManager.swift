import AppKit
import Darwin

// MARK: - Presence detection

/// Converts noisy fullscreen samples around Space/Mission Control transitions into actions.
/// Suppression is immediate; only restoration requires a second, stable sample. AppKit exposes
/// the active-Space notification but no public "Mission Control transition ended" callback.
enum FullscreenPresencePolicy {
    enum Action: Equatable {
        case publishFullscreen
        case beginExitTransition
        case unchanged
    }

    static func action(
        isPublishedFullscreen: Bool,
        sampledFullscreen: Bool,
        isExitTransition: Bool = false
    ) -> Action {
        if sampledFullscreen {
            return !isPublishedFullscreen || isExitTransition ? .publishFullscreen : .unchanged
        }
        return isPublishedFullscreen ? .beginExitTransition : .unchanged
    }

    static func shouldSuppress(
        isExitTransition: Bool,
        hideFullscreenEnabled: Bool,
        isFullscreen: Bool,
        hideConferencingEnabled: Bool,
        isConferencing: Bool
    ) -> Bool {
        isExitTransition ||
        (hideFullscreenEnabled && isFullscreen) ||
        (hideConferencingEnabled && isConferencing)
    }
}

/// Privacy preferences and best-effort presence signals. PhotoManager derives
/// temporary window suppression without changing the user's own isVisible choice.
///
/// `excludeFromScreenCapture` retains the legacy `.none` window-sharing request
/// for compatible older capture paths. Apple's current reference says macOS no
/// longer uses this constant; it must not be presented as guaranteed exclusion
/// from ScreenCaptureKit or other recording/sharing tools:
/// https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none
///
/// Conferencing/fullscreen detection is also heuristic: a running app does not
/// prove an active share, and browser calls are not detected. Hiding widgets
/// before starting a share is the user's direct control over desktop visibility.
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
    private(set) var isFullscreenExitTransition = false
    private var fullscreenRestorationTask: Task<Void, Never>?

    /// Whether either enabled global heuristic currently says "hide".
    var shouldSuppressForPresence: Bool {
        FullscreenPresencePolicy.shouldSuppress(
            isExitTransition: isFullscreenExitTransition,
            hideFullscreenEnabled: hideWhenFullscreenActive,
            isFullscreen: isFullscreenActive,
            hideConferencingEnabled: autoHideForConferencingApps,
            isConferencing: isConferencingAppRunning
        )
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
            Task { @MainActor [weak self] in
                self?.checkConferencingApps()
                self?.checkFullscreen()
            }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkConferencingApps()
                self?.checkFullscreen()
            }
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

    static func isLiveConferencingApplication(bundleIdentifier: String?, processIdentifier: Int32,
                                              isTerminated: Bool, processExists: (Int32) -> Bool) -> Bool {
        guard let bundleIdentifier, conferencingBundleIDs.contains(bundleIdentifier),
              processIdentifier > 0, !isTerminated else { return false }
        return processExists(processIdentifier)
    }

    private func checkConferencingApps() {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            Self.isLiveConferencingApplication(bundleIdentifier: app.bundleIdentifier,
                processIdentifier: app.processIdentifier, isTerminated: app.isTerminated) { pid in
                // LaunchServices can retain a dead application with isTerminated == false.
                // Signal zero checks existence without signalling or changing the process.
                kill(pid, 0) == 0 || errno == EPERM
            }
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
        let sampledFullscreen = Self.sampleFullscreen()
        switch FullscreenPresencePolicy.action(
            isPublishedFullscreen: isFullscreenActive,
            sampledFullscreen: sampledFullscreen,
            isExitTransition: isFullscreenExitTransition
        ) {
        case .publishFullscreen:
            fullscreenRestorationTask?.cancel()
            fullscreenRestorationTask = nil
            isFullscreenExitTransition = false
            isFullscreenActive = true
            // Re-entering fullscreen cancels the temporary exit gate. The user's normal
            // fullscreen preference remains the authority once the transition is cancelled.
            onChange?()
        case .beginExitTransition:
            if !isFullscreenExitTransition {
                isFullscreenExitTransition = true
                // This narrow blocker is always active: even with the optional memory-saving
                // fullscreen preference off, windows must leave the compositor before the
                // outgoing fullscreen Space exposes its black transition surface.
                onChange?()
            }
            scheduleFullscreenRestoration()
        case .unchanged:
            break
        }
    }

    private static func sampleFullscreen() -> Bool {
        NSScreen.screens.contains { $0.frame == $0.visibleFrame }
    }

    private func scheduleFullscreenRestoration() {
        // Repeated activation/Space notifications during the same animation restart one task.
        // The delayed second sample is only a fallback because AppKit has no public notification
        // for the end of another application's fullscreen or Mission Control animation.
        fullscreenRestorationTask?.cancel()
        fullscreenRestorationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.fullscreenRestorationTask = nil
            guard !Self.sampleFullscreen() else {
                self.checkFullscreen()
                return
            }
            guard self.isFullscreenActive || self.isFullscreenExitTransition else { return }
            self.isFullscreenActive = false
            self.isFullscreenExitTransition = false
            self.onChange?()
        }
    }
}
