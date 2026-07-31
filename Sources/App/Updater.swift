// The Mac App Store delivers its own updates, and Review Guideline 2.4.5(iv)
// forbids an app shipping a second update path. The MAS target compiles this out.
#if !MAS

import AppKit
import CryptoKit
import UserNotifications

/// Remote manifest describing the newest build and any broadcast message.
struct Appcast: Decodable {
    struct Announcement: Decodable {
        let id: String
        let title: String
        let body: String
        let url: String?
    }

    let latestVersion: String
    /// Direct link to a `.zip` of the new `.app`. If this points at a web page
    /// instead of an archive, the updater degrades to opening it in a browser.
    let downloadURL: String
    /// Lowercase hex SHA-256 of the archive. Optional in the schema so older
    /// manifests still parse, but unsigned installs are refused without it.
    let sha256: String?
    let releaseNotes: String?
    let minimumOSVersion: String?
    let announcement: Announcement?
}

/// Checks for, downloads, and installs updates in place.
///
/// This is the reason the Developer ID build is not sandboxed: replacing
/// `Tableau.app` and spawning a helper that outlives the process are both
/// blocked under the sandbox.
@MainActor
final class Updater: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = Updater()

    /// Edit this file in the repo to publish an update to every user.
    private let appcastURL = URL(string: "https://raw.githubusercontent.com/yashashwi-s/Tableau/main/appcast.json")!

    /// Once a week is often enough for a desktop toy, and keeps us off the
    /// network on most launches.
    private let automaticInterval: TimeInterval = 7 * 24 * 60 * 60

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String?)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Last successful check, surfaced in the UI so "up to date" is meaningful.
    @Published private(set) var lastChecked: Date?

    /// Newest version the last check saw, whether or not it was installed.
    @Published private(set) var latestKnownVersion: String?

    private var pending: Appcast?
    private var timer: Timer?

    private let lastCheckKey = "lastUpdateCheck"
    private let latestVersionKey = "latestKnownVersion"
    private let notifiedVersionKey = "lastNotifiedVersion"
    private let notifiedAnnouncementKey = "lastNotifiedAnnouncementID"

    var currentVersion: String { Constants.version }

    private override init() {
        super.init()
        lastChecked = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        latestKnownVersion = UserDefaults.standard.string(forKey: latestVersionKey)
    }

    // MARK: - Lifecycle

    func start() {
        guard notificationsAvailable else { return }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Only reach for the network if we haven't looked in a while.
        let due = lastChecked.map { Date().timeIntervalSince($0) >= automaticInterval } ?? true
        if due {
            Task { await check(userInitiated: false) }
        }

        // Long-running sessions still get a weekly check.
        timer = Timer.scheduledTimer(withTimeInterval: automaticInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    /// `UNUserNotificationCenter.current()` traps when the process has no bundle
    /// registered with LaunchServices — e.g. launched straight from a mounted
    /// DMG. Bail out rather than take the whole launch down with us.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Check

    func check(userInitiated: Bool) async {
        phase = .checking

        var request = URLRequest(url: appcastURL)
        // raw.githubusercontent sits behind a CDN; skip every cache on the way.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        guard let appcast = await fetch(request) else {
            phase = userInitiated ? .failed("Couldn't reach the update server.") : .idle
            return
        }

        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        latestKnownVersion = appcast.latestVersion
        UserDefaults.standard.set(appcast.latestVersion, forKey: latestVersionKey)

        if let announcement = appcast.announcement {
            deliverAnnouncement(announcement)
        }

        guard Self.compare(appcast.latestVersion, isNewerThan: currentVersion) else {
            pending = nil
            phase = .upToDate
            return
        }

        // Refuse an update the current OS can't run — installing it would leave
        // the user with an app that won't launch and no way back.
        if let minimum = appcast.minimumOSVersion, !Self.osMeets(minimum) {
            phase = .failed("Version \(appcast.latestVersion) needs macOS \(minimum) or later.")
            return
        }

        pending = appcast
        phase = .available(version: appcast.latestVersion, notes: appcast.releaseNotes)

        if !userInitiated {
            // Only nag once per version, so a launch loop isn't a notification loop.
            guard UserDefaults.standard.string(forKey: notifiedVersionKey) != appcast.latestVersion else { return }
            UserDefaults.standard.set(appcast.latestVersion, forKey: notifiedVersionKey)

            var body = "Version \(appcast.latestVersion) is available."
            if let notes = appcast.releaseNotes, !notes.isEmpty { body += " \(notes)" }
            postNotification(
                identifier: "update-\(appcast.latestVersion)",
                title: "\(Constants.appName) update available",
                body: body
            )
        }
    }

    private func fetch(_ request: URLRequest) async -> Appcast? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(Appcast.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Install

    /// Whether we can replace the running bundle without an admin prompt.
    /// False when the app sits somewhere read-only, e.g. still inside a DMG.
    var canSelfUpdate: Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    /// Downloads, verifies, and swaps in the pending update, then relaunches.
    /// Returns only on failure — on success the app terminates.
    func installPendingUpdate() async {
        guard let appcast = pending else { return }

        guard let url = URL(string: appcast.downloadURL), url.scheme == "https" else {
            phase = .failed("The update link isn't a secure URL.")
            return
        }

        // A manifest pointing at a release *page* rather than an archive can't be
        // installed automatically; hand it to the browser instead of failing.
        guard url.pathExtension.lowercased() == "zip" else {
            NSWorkspace.shared.open(url)
            phase = .idle
            return
        }

        guard canSelfUpdate else {
            phase = .failed("Move \(Constants.appName) to your Applications folder, then try again.")
            return
        }

        // Refusing an unverifiable download is the only real integrity check we
        // have: without a paid Developer ID certificate the new bundle carries
        // no signature we could validate against the running one.
        guard let expectedHash = appcast.sha256?.lowercased(), !expectedHash.isEmpty else {
            phase = .failed("This update is missing its checksum, so it can't be verified.")
            return
        }

        do {
            phase = .downloading(progress: 0)
            let archive = try await download(url)

            phase = .installing
            try verify(archive, matches: expectedHash)

            let staged = try unpack(archive, expecting: appcast.latestVersion)
            try launchSwapHelper(replacing: Bundle.main.bundleURL, with: staged)

            // The helper waits for this process to exit before swapping.
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let destination = try Self.makeWorkDirectory().appendingPathComponent("update.zip")
        try await DownloadTask.run(url: url, to: destination) { [weak self] fraction in
            Task { @MainActor in self?.phase = .downloading(progress: fraction) }
        }
        return destination
    }

    private func verify(_ archive: URL, matches expected: String) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw UpdateError.message("The download didn't match its checksum and was discarded.")
        }
    }

    /// Expands the archive and sanity-checks what came out of it.
    private func unpack(_ archive: URL, expecting version: String) throws -> URL {
        let workDir = archive.deletingLastPathComponent()
        let expanded = workDir.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)

        // ditto rather than NSFileManager: it preserves the resource forks and
        // symlinks inside an .app bundle that a naive unzip would flatten.
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])

        let contents = try FileManager.default.contentsOfDirectory(
            at: expanded,
            includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("The update didn't contain an application.")
        }

        // Guard against a manifest pointing at somebody else's build.
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.message("The update isn't a copy of \(Constants.appName).")
        }
        guard let shipped = info["CFBundleShortVersionString"] as? String, shipped == version else {
            throw UpdateError.message("The update's version didn't match what was advertised.")
        }

        // Downloaded bundles arrive quarantined; left in place, the swapped-in
        // app is refused at launch and the user is stranded with nothing running.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        return app
    }

    /// Writes and detaches the helper that performs the swap.
    ///
    /// A process cannot reliably replace its own bundle while running, so the
    /// actual move happens in a shell script that waits for us to exit first.
    private func launchSwapHelper(replacing destination: URL, with staged: URL) throws {
        let workDir = staged.deletingLastPathComponent().deletingLastPathComponent()
        let scriptURL = workDir.appendingPathComponent("swap.sh")
        let backup = workDir.appendingPathComponent("previous.app")

        // Roll back to the backup if the copy fails, so a botched update can
        // never leave the user with no app at all.
        let script = """
        #!/bin/sh
        PID="$1"
        NEW="$2"
        DEST="$3"
        BACKUP="$4"
        WORK="$5"

        # Wait for the old app to exit, but never hang forever.
        i=0
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
            if [ "$i" -gt 300 ]; then exit 1; fi
        done

        rm -rf "$BACKUP"
        mv "$DEST" "$BACKUP" || exit 1

        if ! /usr/bin/ditto "$NEW" "$DEST"; then
            rm -rf "$DEST"
            mv "$BACKUP" "$DEST"
            exit 1
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        rm -rf "$BACKUP"
        /usr/bin/open "$DEST"
        rm -rf "$WORK"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            destination.path,
            backup.path,
            workDir.path
        ]
        try process.run()
    }

    // MARK: - Helpers

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// A scratch directory that outlives this process, so the helper can still
    /// read the staged app after we terminate.
    private static func makeWorkDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableauUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("\(URL(fileURLWithPath: launchPath).lastPathComponent) failed.")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Notifications

    private func deliverAnnouncement(_ announcement: Appcast.Announcement) {
        guard UserDefaults.standard.string(forKey: notifiedAnnouncementKey) != announcement.id else { return }
        UserDefaults.standard.set(announcement.id, forKey: notifiedAnnouncementKey)

        postNotification(
            identifier: "announcement-\(announcement.id)",
            title: announcement.title,
            body: announcement.body,
            url: announcement.url.flatMap(URL.init(string:))
        )
    }

    private func postNotification(identifier: String, title: String, body: String, url: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Menu bar app is always "frontmost-less", but show the banner regardless.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let string = info["url"] as? String, let url = URL(string: string) {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    // MARK: - Version comparison

    /// Numeric component-wise compare, so "2.0.10" correctly beats "2.0.9".
    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Whether the running OS satisfies a "14.0"-style minimum.
    private static func osMeets(_ minimum: String) -> Bool {
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let required = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }
}

#endif
