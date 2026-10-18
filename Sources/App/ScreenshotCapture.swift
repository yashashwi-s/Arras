import AppKit

@MainActor
enum ScreenCapturePermission {
    static func ensureAccess(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: () -> Bool = { CGRequestScreenCaptureAccess() },
        recover: @MainActor () -> Void = { presentRecovery() }
    ) -> Bool {
        if preflight() || request() { return true }
        recover()
        return false
    }

    private static func presentRecovery() {
        let alert = AppDialog.make(
            title: "Allow Screen Recording",
            message: "In System Settings → Privacy & Security → Screen & System Audio Recording, allow Arras to capture the screen. On older macOS versions this pane is called Screen Recording. Reopen Arras if macOS asks, then try Capture Screen Region again.",
            actions: [.init(title: "Open Screen Recording Settings"), .init(title: "Cancel", role: .cancel)]
        )
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { PrivacySettingsPane.screenRecording.open() }
    }
}

#if ARRAS_APP_STORE
extension PhotoManager {
    func captureScreenshotRegion() {
        guard ScreenCapturePermission.ensureAccess() else { return }
        Task { @MainActor in
            guard let region = await ScreenRegionSelector.select() else { return }
            do {
                let image = try await ScreenRegionCapture.capture(region)
                addPhoto(image)
            } catch {
                recordMediaImportFailure("Screen capture failed: \(error.localizedDescription)")
                AppDialog.inform(title: "Couldn’t Capture Screen Region", message: error.localizedDescription, style: .warning)
            }
        }
    }
}
#else
/// Pins a user-selected region of the screen as a persistent desktop widget --
/// useful for a chart or reference doc someone wants to keep visible, not just
/// a photo (see FEATURES.md, "Content sources").
///
/// The app is deliberately not sandboxed (see CLAUDE.md), which makes
/// `/usr/sbin/screencapture` available via `Process`. That's the practical
/// public route to an interactive region selection -- there is no supported
/// API for it.
extension PhotoManager {
    /// Runs the interactive screenshot picker (drag a region, Space bar to
    /// capture a window, Escape to cancel) and, if the user completes a
    /// selection, adds the result as a new widget.
    ///
    /// `screencapture -i` doesn't return until the user finishes, but
    /// `Process.run()` itself does not block -- the completion is observed via
    /// `terminationHandler`, which AppKit invokes on a background queue, so
    /// this is safe to call from the main actor without freezing the app.
    func captureScreenshotRegion() {
        guard ScreenCapturePermission.ensureAccess() else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive selection. -r: no window shadow/drop-shadow decoration
        // baked into the capture, since that reads oddly once it's cropped to a
        // widget with its own shadow.
        task.arguments = ["-i", "-r", tempURL.path]

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: tempURL) }

                // Escape, or a click that didn't drag a region, leaves no file on
                // disk -- that's the only cancel signal screencapture gives us.
                // Without this check a cancelled capture would create an empty widget.
                guard FileManager.default.fileExists(atPath: tempURL.path),
                      let image = NSImage(contentsOf: tempURL) else { return }

                self?.addPhoto(image)
            }
        }

        do {
            try task.run()
        } catch {
            recordMediaImportFailure("Screen capture could not be started: \(error.localizedDescription).")
            AppDialog.inform(title: "Couldn’t Capture Screen Region", message: error.localizedDescription, style: .warning)
        }
    }
}

#endif
