import Foundation

/// Moves widget data out of the old sandbox container.
///
/// Dropping the App Sandbox (so the updater can replace the app bundle) also
/// changes where `applicationSupportDirectory` resolves to: sandboxed builds
/// wrote to ~/Library/Containers/<bundle-id>/Data/Library/Application Support,
/// unsandboxed ones write to ~/Library/Application Support. Without this, every
/// existing user would launch the update to find an empty desktop.
enum StorageMigration {

    /// Path the sandboxed builds wrote to. Hardcoded rather than derived,
    /// because an unsandboxed process can't ask the OS for its own container.
    private static var containerDir: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support/PhotoWidget", isDirectory: true)
    }

    /// Copies sandboxed data into `destination` if, and only if, `destination`
    /// has no layout of its own.
    ///
    /// The guard matters: a user who has run both a sandboxed and an
    /// unsandboxed build has data in both places, and the unsandboxed copy is
    /// the one they've been editing. Overwriting it would silently discard
    /// their current desktop, which is unrecoverable — so when in doubt, do
    /// nothing.
    static func migrateIfNeeded(to destination: URL) {
        let fm = FileManager.default
        let destManifest = destination.appendingPathComponent("photos.json")

        // Destination already has a layout — leave it strictly alone.
        guard !fm.fileExists(atPath: destManifest.path) else { return }

        guard let source = containerDir else { return }
        let sourceManifest = source.appendingPathComponent("photos.json")
        guard fm.fileExists(atPath: sourceManifest.path) else { return }

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            // Copy rather than move: leaving the container intact means a user
            // who downgrades to a sandboxed build still finds their widgets,
            // and a half-finished migration can simply be retried.
            for name in try fm.contentsOfDirectory(atPath: source.path) {
                let from = source.appendingPathComponent(name)
                let to = destination.appendingPathComponent(name)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try fm.copyItem(at: from, to: to)
            }
            NSLog("Tableau: migrated widget data out of the sandbox container")
        } catch {
            NSLog("Tableau: storage migration failed — \(error.localizedDescription)")
        }
    }
}
