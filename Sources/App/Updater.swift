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
/// This is why the app is not sandboxed: replacing `Arras.app` and spawning a
/// helper that outlives the process are both blocked under the sandbox.
@MainActor
final class Updater: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = Updater()

    /// Direct CDN URL avoids the extra github.com redirect on every manual check. The old
    /// route measured about four times slower despite returning this same tiny JSON file.
    static let appcastURL = URL(string: "https://raw.githubusercontent.com/yashashwi-s/Arras/main/appcast.json")!

    /// How often the app checks on its own.
    ///
    /// Daily is the automatic default. Manual-install mode can use a different
    /// cadence, but anything shorter than an hour would needlessly hammer the
    /// update feed.
    enum CheckFrequency: TimeInterval, CaseIterable, Identifiable, Equatable {
        case hourly = 3600
        case everySixHours = 21600
        case daily = 86400
        case weekly = 604800
        case never = 0

        var id: TimeInterval { rawValue }

        var label: String {
            switch self {
            case .hourly: return "Hourly"
            case .everySixHours: return "Every 6 Hours"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .never: return "Never"
            }
        }
    }

    private let frequencyKey = "updateCheckFrequency"
    private let automaticUpdatesKey = "automaticUpdatesEnabled"

    /// The cadence used when automatic installation is disabled. Automatic installation has
    /// its own fixed daily cadence so changing this value remains a useful, preserved choice
    /// rather than changing the update policy behind the user's back.
    var checkFrequency: CheckFrequency {
        get {
            let stored = UserDefaults.standard.object(forKey: frequencyKey) as? TimeInterval
            return stored.flatMap(CheckFrequency.init(rawValue:)) ?? .daily
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: frequencyKey)
            rescheduleTimer()
        }
    }

    /// Automatic installation is the default for any installation with no stored preference. The
    /// explicit stored-value check is important because `UserDefaults.bool(forKey:)` would turn
    /// an absent key into `false`.
    var automaticUpdatesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: automaticUpdatesKey) as? Bool ?? true }
        set {
            guard automaticUpdatesEnabled != newValue else { return }
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: automaticUpdatesKey)
            rescheduleTimer()
        }
    }

    /// Automatic updates always check daily; manual-install mode retains the user's chosen
    /// cadence, including Never for users who only check from the Settings button.
    var activeCheckFrequency: CheckFrequency {
        automaticUpdatesEnabled ? .daily : checkFrequency
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String?)
        case downloading(progress: Double)
        case installing
        /// Shown once on the first launch after a successful update.
        case installed(version: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Last successful check, surfaced in the UI so "up to date" is meaningful.
    @Published private(set) var lastChecked: Date?

    /// Newest version the last check saw, whether or not it was installed.
    @Published private(set) var latestKnownVersion: String?

    private var pending: Appcast?
    private var timer: Timer?
    private var idleResetTask: Task<Void, Never>?
    private var notificationRequestsInFlight = Set<String>()

    /// Set just before the swap; the relaunched copy consumes it to confirm the update.
    static let justUpdatedKey = "justUpdatedToVersion"

    /// Path to a temporary marker the replacement writes after it reaches app startup. The swap
    /// helper keeps the previous bundle until this breadcrumb exists; LaunchServices accepting an
    /// `open` request alone is not enough to prove that the new copy actually launched.
    static let updateHealthMarkerKey = "updateHealthMarkerPath"

    private let lastCheckKey = "lastUpdateCheck"
    private let latestVersionKey = "latestKnownVersion"
    private let notifiedVersionKey = "lastNotifiedVersion"
    private let notifiedAnnouncementKey = "lastNotifiedAnnouncementID"
    private let automaticFailureNotifiedVersionKey = "lastAutomaticUpdateFailureVersion"

    var currentVersion: String { Constants.version }

    private override init() {
        super.init()
        lastChecked = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        latestKnownVersion = UserDefaults.standard.string(forKey: latestVersionKey)
    }

    // MARK: - Lifecycle

    func start() {
        // Register the delegate as soon as the updater starts so a later notification tap can be
        // delivered even when the first check finds nothing. This intentionally does not ask for
        // permission; authorization is requested only by postNotification when needed.
        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }

        let interval = activeCheckFrequency.rawValue
        guard interval > 0 else { return }

        // Only reach for the network if we haven't looked in a while.
        let due = lastChecked.map { Date().timeIntervalSince($0) >= interval } ?? true
        if due, phase == .idle {
            Task { await check(userInitiated: false) }
        }

        rescheduleTimer()
    }

    /// Restarts the background timer for the current frequency.
    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil

        let interval = activeCheckFrequency.rawValue
        guard interval > 0 else { return }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    /// `UNUserNotificationCenter.current()` traps when the process has no bundle
    /// registered with LaunchServices — e.g. launched straight from a mounted
    /// DMG. Bail out rather than take the whole launch down with us.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Reports a completed update in the settings footer, where the version number the
    /// user is checking already lives.
    func announceInstalled(version: String) {
        phase = .installed(version: version)
        scheduleReturnToIdle(after: 5)
    }

    /// Consumes the swap helper's breadcrumb only after confirming that the relaunched bundle
    /// is actually the version that was advertised. A rollback or failed launch must remain
    /// visible as a failure instead of being reported as a successful update.
    func announceInstallResult(expectedVersion: String) {
        guard expectedVersion == currentVersion else {
            phase = .failed(
                "Update to \(expectedVersion) did not complete. \(Constants.appName) is still running \(currentVersion). Check for Updates to retry."
            )
            return
        }
        announceInstalled(version: expectedVersion)
    }

    /// Called at the very beginning of app startup. A matching version proves that the replacement
    /// bundle reached its own process, so the helper can safely discard its rollback copy. The
    /// marker is deliberately written before update UI/network work, keeping the health handshake
    /// bounded even if a later startup task fails.
    static func markUpdateHealthyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: justUpdatedKey) == Constants.version,
              let path = defaults.string(forKey: updateHealthMarkerKey), !path.isEmpty else {
            return
        }

        do {
            try Data("healthy\n".utf8).write(
                to: URL(fileURLWithPath: path),
                options: .atomic
            )
            defaults.removeObject(forKey: updateHealthMarkerKey)
        } catch {
            // Leave the breadcrumb in defaults so the swap helper times out and restores the
            // previous bundle rather than declaring a launch healthy without proof.
        }
    }

    /// Drops a transient result back to `.idle` so the Check for Updates control
    /// comes back. Cancelled if the phase changes in the meantime.
    private func scheduleReturnToIdle(after seconds: TimeInterval = 5) {
        idleResetTask?.cancel()
        let expected = phase
        idleResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == expected else { return }
            self.phase = .idle
        }
    }

    // MARK: - Check

    func check(userInitiated: Bool) async {
        // Launch-time and manual checks can overlap when Settings is opened immediately.
        // The first request is already fetching the same manifest; a duplicate only adds
        // another redirect/network wait and lets the slower response win the UI state.
        switch phase {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        phase = .checking

        var request = URLRequest(url: Self.appcastURL)
        // raw.githubusercontent sits behind a CDN; skip every cache on the way.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5

        guard let appcast = await fetch(request) else {
            phase = userInitiated ? .failed("Couldn't reach the update server.") : .idle
            return
        }

        // The release workflow publishes SemVer versions. Reject malformed values instead of
        // treating an unparseable prerelease as "not newer" and silently ignoring an update.
        guard Self.isValidVersion(appcast.latestVersion) else {
            phase = userInitiated ? .failed("The update manifest contained an invalid version.") : .idle
            return
        }

        let now = Date()
        lastChecked = now
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        latestKnownVersion = appcast.latestVersion
        UserDefaults.standard.set(appcast.latestVersion, forKey: latestVersionKey)

        if let announcement = appcast.announcement {
            await deliverAnnouncement(announcement)
        }

        guard Self.compare(appcast.latestVersion, isNewerThan: currentVersion) else {
            pending = nil
            phase = .upToDate
            // "Up to date" is a receipt for an action, not a lasting state. Left
            // on screen it permanently replaces the Check for Updates button, so
            // the only way to check again is to relaunch. Fade back to idle.
            scheduleReturnToIdle()
            return
        }

        // Refuse an update the current OS can't run — installing it would leave
        // the user with an app that won't launch and no way back.
        if let minimum = appcast.minimumOSVersion, !Self.osMeets(minimum) {
            let message = "Version \(appcast.latestVersion) needs macOS \(minimum) or later."
            phase = .failed(message)
            if automaticUpdatesEnabled {
                await notifyAutomaticInstallFailure(version: appcast.latestVersion, reason: message)
            }
            return
        }

        pending = appcast
        phase = .available(version: appcast.latestVersion, notes: appcast.releaseNotes)

        if automaticUpdatesEnabled {
            // The toggle is the user's standing consent. Keep the explicit available phase for
            // one render pass so Settings can explain what is happening, then use the same
            // checksum, archive, bundle, and rollback gates as a manual install.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.automaticUpdatesEnabled else {
                    if !userInitiated { await self.notifyAvailableUpdate(appcast) }
                    return
                }
                await self.installPendingUpdate(automatically: true)
            }
        } else if !userInitiated {
            await notifyAvailableUpdate(appcast)
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
    var canSelfUpdate: Bool { InstallLocation.canSelfUpdate }

    /// Downloads, verifies, and swaps in the pending update, then relaunches.
    /// Returns only on failure — on success the app terminates.
    func installPendingUpdate(automatically: Bool = false) async {
        switch phase {
        case .downloading, .installing:
            return
        default:
            break
        }
        guard let appcast = pending else { return }

        guard let url = URL(string: appcast.downloadURL), url.scheme == "https" else {
            let message = "The update link isn't a secure URL."
            phase = .failed(message)
            if automatically {
                await notifyAutomaticInstallFailure(version: appcast.latestVersion, reason: message)
            }
            return
        }

        // A manifest pointing at a release *page* rather than an archive is still useful for a
        // manual check, but automatic mode must not open a browser or treat it as an install.
        guard url.pathExtension.lowercased() == "zip" else {
            if automatically {
                let message = "The available update is not a downloadable archive."
                phase = .failed(message)
                await notifyAutomaticInstallFailure(version: appcast.latestVersion, reason: message)
            } else {
                NSWorkspace.shared.open(url)
                phase = .idle
            }
            return
        }

        guard canSelfUpdate else {
            // Moving a *running* bundle doesn't change Bundle.main.bundleURL, so telling the
            // user to move it and retry sends them into a loop that only quitting escapes.
            // Offer to do the move and relaunch instead.
            let message = "\(Constants.appName) can't update from here."
            phase = .failed(message)
            if automatically {
                await notifyAutomaticInstallFailure(version: appcast.latestVersion, reason: message)
            }
            InstallLocation.offerToInstallIfNeeded(force: true)
            return
        }

        // Refusing an unverifiable download is the only real integrity check we
        // have: without a paid Developer ID certificate the new bundle carries
        // no signature we could validate against the running one.
        guard let expectedHash = appcast.sha256?.lowercased(), !expectedHash.isEmpty else {
            let message = "This update is missing its checksum, so it can't be verified."
            phase = .failed(message)
            if automatically {
                await notifyAutomaticInstallFailure(version: appcast.latestVersion, reason: message)
            }
            return
        }

        var installBreadcrumbWasSet = false
        do {
            phase = .downloading(progress: 0)
            let download = try await download(Self.trackedDownloadURL(url))
            var handedOffToHelper = false
            defer {
                if !handedOffToHelper {
                    Self.cleanupUpdateWorkDirectory(download.workDirectory)
                }
            }

            // Revoking automatic-update consent while the archive is in flight must stop before
            // the verified bundle is staged or the running app is relaunched. A download already
            // in progress is allowed to finish because DownloadTask has no destructive cancel
            // path, but it is never installed after consent is withdrawn.
            guard !automatically || automaticUpdatesEnabled else {
                phase = .available(version: appcast.latestVersion, notes: appcast.releaseNotes)
                await notifyAvailableUpdate(appcast)
                return
            }

            phase = .installing
            try verify(download.archive, matches: expectedHash)

            let staged = try unpack(download.archive, expecting: appcast.latestVersion)

            // Leave breadcrumbs the relaunched copy reads on startup, so the update visibly lands
            // instead of the app appearing to just close and reopen. The health marker is unique
            // to this work directory and is written only after the replacement reaches startup.
            let healthMarker = download.workDirectory.appendingPathComponent("update-health")
            try? FileManager.default.removeItem(at: healthMarker)
            UserDefaults.standard.set(healthMarker.path, forKey: Self.updateHealthMarkerKey)
            UserDefaults.standard.set(appcast.latestVersion, forKey: Self.justUpdatedKey)
            installBreadcrumbWasSet = true

            try launchSwapHelper(
                replacing: Bundle.main.bundleURL,
                with: staged,
                workDirectory: download.workDirectory,
                healthMarker: healthMarker
            )
            handedOffToHelper = true

            // The helper waits for this process to exit before swapping.
            NSApp.terminate(nil)
        } catch {
            if installBreadcrumbWasSet {
                UserDefaults.standard.removeObject(forKey: Self.justUpdatedKey)
                UserDefaults.standard.removeObject(forKey: Self.updateHealthMarkerKey)
            }
            phase = .failed(error.localizedDescription)
            if automatically {
                await notifyAutomaticInstallFailure(version: appcast.latestVersion, reason: error.localizedDescription)
            }
        }
    }

    private func download(_ url: URL) async throws -> (archive: URL, workDirectory: URL) {
        let workDirectory = try Self.makeWorkDirectory()
        let destination = workDirectory.appendingPathComponent("update.zip")
        do {
            try await DownloadTask.run(url: url, to: destination) { [weak self] fraction in
                Task { @MainActor in self?.phase = .downloading(progress: fraction) }
            }
            return (destination, workDirectory)
        } catch {
            Self.cleanupUpdateWorkDirectory(workDirectory)
            throw error
        }
    }

    /// Forces every install attempt to begin at GitHub's release endpoint instead of reusing
    /// a cached signed CDN redirect. Besides avoiding stale redirects, this gives GitHub one
    /// distinct release-asset request to count for each update download.
    static func trackedDownloadURL(_ url: URL, requestID: UUID = UUID()) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "source" }) {
            queryItems.append(URLQueryItem(name: "source", value: "arras-updater"))
        }
        queryItems.removeAll { $0.name == "request" }
        queryItems.append(URLQueryItem(name: "request", value: requestID.uuidString.lowercased()))
        components.queryItems = queryItems
        return components.url ?? url
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
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        return app
    }

    /// Writes and detaches the helper that performs the swap.
    ///
    /// A process cannot reliably replace its own bundle while running, so the
    /// actual move happens in a shell script that waits for us to exit first.
    private func launchSwapHelper(
        replacing destination: URL,
        with staged: URL,
        workDirectory: URL,
        healthMarker: URL
    ) throws {
        let workDir = workDirectory
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
        HEALTH="$6"

        cleanup() {
            rm -rf "$WORK"
        }

        restore_previous() {
            rm -rf "$DEST"
            if mv "$BACKUP" "$DEST"; then
                /usr/bin/open "$DEST" >/dev/null 2>&1 || true
            fi
            cleanup
        }

        # Wait for the old app to exit, but never hang forever.
        i=0
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
            if [ "$i" -gt 300 ]; then
                /usr/bin/open "$DEST" >/dev/null 2>&1 || true
                cleanup
                exit 1
            fi
        done

        if ! mv "$DEST" "$BACKUP"; then
            /usr/bin/open "$DEST" >/dev/null 2>&1 || true
            cleanup
            exit 1
        fi

        if ! /usr/bin/ditto "$NEW" "$DEST"; then
            restore_previous
            exit 1
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null

        # Keep the rollback copy until the replacement has reached its own startup. `open`
        # returning zero only means LaunchServices accepted the request; the health breadcrumb
        # is written by the relaunched app after it has confirmed its bundle version.
        if ! /usr/bin/open "$DEST" >/dev/null 2>&1; then
            restore_previous
            exit 1
        fi

        i=0
        while [ ! -f "$HEALTH" ]; do
            sleep 0.1
            i=$((i + 1))
            if [ "$i" -gt 300 ]; then
                # The replacement never reached startup. Restore the known-good bundle and
                # reopen it; the old process will surface the stale breadcrumb as a failure.
                restore_previous
                exit 1
            fi
        done

        rm -rf "$BACKUP"
        cleanup
        exit 0
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
            workDir.path,
            healthMarker.path
        ]
        try process.run()
    }

    private static func cleanupUpdateWorkDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
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
            .appendingPathComponent("ArrasUpdate-\(UUID().uuidString)", isDirectory: true)
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

    private func notifyAvailableUpdate(_ appcast: Appcast) async {
        let identifier = "update-\(appcast.latestVersion)"
        guard reserveNotification(identifier: identifier, key: notifiedVersionKey, value: appcast.latestVersion) else { return }

        let body = Self.updateNotificationBody(version: appcast.latestVersion, releaseNotes: appcast.releaseNotes)
        let accepted = await postNotification(
            identifier: identifier,
            title: "\(Constants.appName) update available",
            body: body
        )
        finishNotification(identifier: identifier, key: notifiedVersionKey, value: appcast.latestVersion, accepted: accepted)
    }

    static func updateNotificationBody(version: String, releaseNotes: String?) -> String {
        let statement = releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usefulStatement = statement.flatMap { $0.isEmpty ? nil : $0 }
            ?? "This release includes the latest fixes and improvements."
        return "Version \(version) is available. \(usefulStatement)"
    }

    private func notifyAutomaticInstallFailure(version: String, reason: String) async {
        // A persistent bad release or an unwritable install location can survive many daily
        // checks. Keep the failure visible in Settings, but do not turn that into a repeated
        // notification for the same version.
        let identifier = "update-failed-\(version)"
        guard reserveNotification(identifier: identifier, key: automaticFailureNotifiedVersionKey, value: version) else { return }

        let accepted = await postNotification(
            identifier: identifier,
            title: "\(Constants.appName) couldn't install the update",
            body: "Version \(version) was found, but it could not be installed. \(reason)"
        )
        finishNotification(identifier: identifier, key: automaticFailureNotifiedVersionKey, value: version, accepted: accepted)
    }

    private func deliverAnnouncement(_ announcement: Appcast.Announcement) async {
        let identifier = "announcement-\(announcement.id)"
        guard reserveNotification(identifier: identifier, key: notifiedAnnouncementKey, value: announcement.id) else { return }

        let accepted = await postNotification(
            identifier: identifier,
            title: announcement.title,
            body: announcement.body,
            url: announcement.url.flatMap(URL.init(string:))
        )
        finishNotification(identifier: identifier, key: notifiedAnnouncementKey, value: announcement.id, accepted: accepted)
    }

    private func reserveNotification(identifier: String, key: String, value: String) -> Bool {
        guard UserDefaults.standard.string(forKey: key) != value,
              notificationRequestsInFlight.insert(identifier).inserted else { return false }
        return true
    }

    private func finishNotification(identifier: String, key: String, value: String, accepted: Bool) {
        notificationRequestsInFlight.remove(identifier)
        if accepted {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func postNotification(identifier: String, title: String, body: String, url: URL? = nil) async -> Bool {
        guard notificationsAvailable else { return false }
        let center = UNUserNotificationCenter.current()
        guard await ensureNotificationAuthorization(center) else { return false }

        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        return await withCheckedContinuation { continuation in
            center.add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func ensureNotificationAuthorization(_ center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    continuation.resume(returning: true)
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                default:
                    continuation.resume(returning: false)
                }
            }
        }
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

    /// SemVer precedence, matching the release workflow: numeric core components, prerelease
    /// identifiers (numeric identifiers sort before text), and stable releases above prereleases.
    /// Build metadata is accepted but intentionally ignored for precedence.
    private struct SemanticVersion {
        private enum Identifier {
            case numeric(String)
            case text(String)
        }

        private let major: String
        private let minor: String
        private let patch: String
        private let prerelease: [Identifier]

        init?(_ raw: String) {
            let buildParts = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            guard buildParts.count <= 2 else { return nil }

            if buildParts.count == 2 {
                let build = String(buildParts[1])
                guard !build.isEmpty,
                      build.split(separator: ".", omittingEmptySubsequences: false)
                        .allSatisfy({ Self.isIdentifier(String($0)) }) else {
                    return nil
                }
            }

            let releaseParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard releaseParts.count <= 2 else { return nil }

            let core = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard core.count == 3,
                  core.allSatisfy(Self.isCoreNumber) else {
                return nil
            }

            major = core[0]
            minor = core[1]
            patch = core[2]

            guard releaseParts.count == 2 else {
                prerelease = []
                return
            }

            let rawIdentifiers = releaseParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !rawIdentifiers.isEmpty else { return nil }

            var parsed: [Identifier] = []
            for rawIdentifier in rawIdentifiers {
                let identifier = String(rawIdentifier)
                guard Self.isIdentifier(identifier) else { return nil }

                if Self.isDigits(identifier) {
                    // Numeric prerelease identifiers must not contain leading zeroes in SemVer.
                    guard identifier.count == 1 || !identifier.hasPrefix("0") else { return nil }
                    parsed.append(.numeric(identifier))
                } else {
                    parsed.append(.text(identifier))
                }
            }
            prerelease = parsed
        }

        private static func isDigits(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
            }
        }

        private static func isCoreNumber(_ value: String) -> Bool {
            isDigits(value) && (value.count == 1 || !value.hasPrefix("0"))
        }

        private static func isIdentifier(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 48...57, 65...90, 97...122: return true
                default: return false
                }
            }
        }

        private static func numericComparison(_ lhs: String, _ rhs: String) -> Int {
            if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
            if lhs == rhs { return 0 }
            return lhs < rhs ? -1 : 1
        }

        private static func identifierComparison(_ lhs: Identifier, _ rhs: Identifier) -> Int {
            switch (lhs, rhs) {
            case let (.numeric(left), .numeric(right)):
                return numericComparison(left, right)
            case (.numeric, .text):
                return -1
            case (.text, .numeric):
                return 1
            case let (.text(left), .text(right)):
                if left == right { return 0 }
                return left < right ? -1 : 1
            }
        }

        func comparison(to other: SemanticVersion) -> Int {
            for (left, right) in [(major, other.major), (minor, other.minor), (patch, other.patch)] {
                let result = Self.numericComparison(left, right)
                if result != 0 { return result }
            }

            if prerelease.isEmpty && other.prerelease.isEmpty { return 0 }
            if prerelease.isEmpty { return 1 }
            if other.prerelease.isEmpty { return -1 }

            for (left, right) in zip(prerelease, other.prerelease) {
                let result = Self.identifierComparison(left, right)
                if result != 0 { return result }
            }
            if prerelease.count == other.prerelease.count { return 0 }
            return prerelease.count < other.prerelease.count ? -1 : 1
        }
    }

    static func isValidVersion(_ version: String) -> Bool {
        SemanticVersion(version) != nil
    }

    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        guard let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) else { return false }
        return left.comparison(to: right) > 0
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
