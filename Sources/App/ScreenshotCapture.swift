import AppKit

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
        }
    }
}
