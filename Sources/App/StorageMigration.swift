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
        guard let source = containerDir else { return }
        do {
            try copyLibraryIfNeeded(from: source, to: destination)
        } catch {
            NSLog("Arras: storage migration failed. \(error.localizedDescription)")
        }
    }

    static func copyLibraryIfNeeded(
        from source: URL, to destination: URL,
        copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws {
        let fm = FileManager.default
        let destManifest = destination.appendingPathComponent("photos.json")
        let sourceManifest = source.appendingPathComponent("photos.json")
        guard !fm.fileExists(atPath: destManifest.path),
              fm.fileExists(atPath: sourceManifest.path) else { return }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let names = try fm.contentsOfDirectory(atPath: source.path).filter { $0 != "photos.json" }
        // Publish each complete copy and move the manifest last. Interrupted copies
        // stay in staging, and a retry can reuse any completed destination files.
        for name in names + ["photos.json"] {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { continue }
            let staged = staging.appendingPathComponent(name)
            try copy(from, staged)
            try fm.moveItem(at: staged, to: to)
        }
        NSLog("Arras: migrated widget data out of the sandbox container")
    }
}
