import AppKit

/// Where the app is running from, and getting it somewhere it can update itself.
///
/// The updater replaces the running bundle in place, which needs a writable parent directory.
/// Launched straight from a mounted disk image that is read-only, so the update fails with
/// "move it to Applications" and there is nothing the app can do about it afterwards: moving a
/// *running* bundle does not change `Bundle.main.bundleURL`, so retrying keeps failing until
/// the user quits and reopens from the new location. That is a confusing dead end.
///
/// Offering the move at launch, before anyone tries to update, avoids the dead end entirely.
enum InstallLocation {
    private static let declinedKey = "declinedMoveToApplications"

    static var bundleURL: URL { Bundle.main.bundleURL }

    /// Whether the bundle's parent directory can be written, i.e. whether an in-place swap is
    /// possible at all.
    static var canSelfUpdate: Bool {
        FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
    }

    /// Gatekeeper runs quarantined apps from a throwaway read-only mount rather than where the
    /// user put them. The path is the only public tell.
    static var isTranslocated: Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    static var isInApplications: Bool {
        let path = bundleURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var destination: URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
    }

    /// Asks once whether to move into /Applications, then relaunches from there.
    ///
    /// Declining is remembered, because nagging on every launch is worse than an app that
    /// cannot update itself.
    @MainActor
    static func offerToInstallIfNeeded(force: Bool = false) {
        guard !isInApplications else { return }
        // `force` is the updater asking after a failed attempt, where an earlier "Not Now"
        // shouldn't silence the one prompt that can actually unblock them.
        guard force || !UserDefaults.standard.bool(forKey: declinedKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Move \(Constants.appName) to Applications?"
        alert.informativeText = isTranslocated || !canSelfUpdate
            ? "\(Constants.appName) is running from a read-only location, so it can't install its own updates. Moving it to your Applications folder fixes that."
            : "\(Constants.appName) updates itself in place, which works properly once it lives in your Applications folder."
        alert.addButton(withTitle: "Move and Relaunch")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            return
        }

        do {
            try moveAndRelaunch()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't Move \(Constants.appName)"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag it to your Applications folder yourself, then reopen it from there."
            failure.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            failure.runModal()
        }
    }

    /// Copies rather than moves: the source may be a read-only mount or a translocated image,
    /// neither of which can be moved out of.
    @MainActor
    private static func moveAndRelaunch() throws {
        let source = bundleURL
        let target = destination
        let manager = FileManager.default

        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: try stagedCopy(of: source))
        } else {
            try manager.copyItem(at: source, to: target)
        }

        // Downloaded bundles arrive quarantined. Left in place, the copy we just made gets the
        // same Gatekeeper prompt the user already dismissed once to get this far.
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", target.path]
        try? strip.run()
        strip.waitUntilExit()

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// `replaceItemAt` needs the replacement on the same volume as the destination.
    private static func stagedCopy(of source: URL) throws -> URL {
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        let copy = staging.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }
}
