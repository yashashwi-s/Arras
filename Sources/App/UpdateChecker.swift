import Foundation
import AppKit
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
    let downloadURL: String
    let releaseNotes: String?
    let minimumOSVersion: String?
    let announcement: Announcement?
}

/// Polls a JSON manifest on every launch (and every few hours) so a new version
/// or a one-off message can be pushed to everyone running the app.
///
/// This deliberately avoids APNs: `aps-environment` is a restricted entitlement
/// that needs an Apple-issued provisioning profile embedded in the bundle, and a
/// Developer ID build claiming it without one is killed at launch.
@MainActor
final class UpdateChecker: NSObject, UNUserNotificationCenterDelegate {

    static let shared = UpdateChecker()

    /// Edit this file in the repo to broadcast to every user.
    private let appcastURL = URL(string: "https://raw.githubusercontent.com/yashashwi-s/Tableau/main/appcast.json")!

    private let checkInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    // Persisted so a given update/announcement only nags once.
    private let notifiedVersionKey = "lastNotifiedVersion"
    private let notifiedAnnouncementKey = "lastNotifiedAnnouncementID"
    private let lastCheckKey = "lastUpdateCheck"

    private var pendingURL: URL?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Lifecycle

    func start() {
        guard notificationsAvailable else { return }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task { await check(userInitiated: false) }

        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    /// `UNUserNotificationCenter.current()` traps when the process has no bundle
    /// registered with LaunchServices — e.g. the app was launched straight from a
    /// mounted DMG. Bail out rather than take the whole launch down with us.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Check

    /// - Parameter userInitiated: when true, always reports a result (including
    ///   "you're up to date") and ignores the already-notified bookkeeping.
    func check(userInitiated: Bool) async {
        var request = URLRequest(url: appcastURL)
        // raw.githubusercontent sits behind a CDN; skip every cache on the way.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        guard let appcast = await fetch(request) else {
            if userInitiated { presentAlert(title: "Couldn’t check for updates", body: "Please try again later.") }
            return
        }

        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        if let announcement = appcast.announcement {
            deliverAnnouncement(announcement, userInitiated: userInitiated)
        }

        let isNewer = Self.compare(appcast.latestVersion, isNewerThan: currentVersion)

        guard isNewer else {
            if userInitiated {
                presentAlert(title: "You’re up to date", body: "\(Constants.appName) \(currentVersion) is the latest version.")
            }
            return
        }

        if !userInitiated {
            // Only surface each version once, so a launch loop isn't a nag loop.
            guard UserDefaults.standard.string(forKey: notifiedVersionKey) != appcast.latestVersion else { return }
            UserDefaults.standard.set(appcast.latestVersion, forKey: notifiedVersionKey)
        }

        let url = URL(string: appcast.downloadURL)

        if userInitiated {
            presentUpdateAlert(appcast: appcast, url: url)
        } else {
            var body = "Version \(appcast.latestVersion) is available."
            if let notes = appcast.releaseNotes, !notes.isEmpty { body += " \(notes)" }
            postNotification(
                identifier: "update-\(appcast.latestVersion)",
                title: "\(Constants.appName) update available",
                body: body,
                url: url
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

    private func deliverAnnouncement(_ announcement: Appcast.Announcement, userInitiated: Bool) {
        guard UserDefaults.standard.string(forKey: notifiedAnnouncementKey) != announcement.id else { return }
        UserDefaults.standard.set(announcement.id, forKey: notifiedAnnouncementKey)

        postNotification(
            identifier: "announcement-\(announcement.id)",
            title: announcement.title,
            body: announcement.body,
            url: announcement.url.flatMap(URL.init(string:))
        )
    }

    // MARK: - Delivery

    private func postNotification(identifier: String, title: String, body: String, url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func presentUpdateAlert(appcast: Appcast, url: URL?) {
        let alert = NSAlert()
        alert.messageText = "\(Constants.appName) \(appcast.latestVersion) is available"
        alert.informativeText = appcast.releaseNotes ?? "You’re running \(currentVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - UNUserNotificationCenterDelegate

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
}
