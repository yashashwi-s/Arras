import AppKit
import CryptoKit
import UserNotifications
import XCTest
@testable import Arras

private final class HeldUpdaterFeed: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: HeldUpdaterFeed] = [:]
    let identifier = UUID().uuidString
    let started: XCTestExpectation
    let expectedURL: URL
    private let lock = NSLock()
    private var pending: URLProtocol?
    private var requestCount = 0

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    init(started: XCTestExpectation, expectedURL: URL) {
        self.started = started
        self.expectedURL = expectedURL
        Self.registryLock.lock()
        Self.registry[identifier] = self
        Self.registryLock.unlock()
    }

    static func find(_ request: URLRequest) -> HeldUpdaterFeed? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return request.value(forHTTPHeaderField: "X-Arras-Updater-Test").flatMap { registry[$0] }
    }

    func capture(_ value: URLProtocol) {
        lock.lock()
        pending = value
        requestCount += 1
        lock.unlock()
        started.fulfill()
    }

    func release(payload: Data? = nil) throws {
        lock.lock()
        let value = pending
        pending = nil
        lock.unlock()
        let feed = try XCTUnwrap(value)
        let url = try XCTUnwrap(feed.request.url)
        let body = payload ?? Data(#"{"latestVersion":"99.0.0","downloadURL":"https://example.invalid/release","sha256":"00"}"#.utf8)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"]))
        feed.client?.urlProtocol(feed, didReceive: response, cacheStoragePolicy: .notAllowed)
        feed.client?.urlProtocol(feed, didLoad: body)
        feed.client?.urlProtocolDidFinishLoading(feed)
    }

    func unregister() {
        Self.registryLock.lock()
        Self.registry.removeValue(forKey: identifier)
        Self.registryLock.unlock()
    }
}

private final class HeldUpdaterFeedProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Every request stays inside this protocol, including a malformed fixture.
        guard let feed = HeldUpdaterFeed.find(request), request.url == feed.expectedURL else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        feed.capture(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class TestUpdaterNotifications: UpdaterNotifications {
    weak var delegate: UNUserNotificationCenterDelegate?
    var authorizationStarted: XCTestExpectation?
    var holdStatus = false
    var holdAuthorization = false
    var status: UNAuthorizationStatus = .authorized
    var authorizationGranted = true
    var submissionAccepted = true
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var permissionRequests = 0
    private var statusRequest: CheckedContinuation<UNAuthorizationStatus, Never>?
    private var authorization: CheckedContinuation<Bool, Never>?

    func registerDelegate(_ delegate: UNUserNotificationCenterDelegate) { self.delegate = delegate }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard holdStatus else { return status }
        return await withCheckedContinuation { continuation in
            statusRequest = continuation
            authorizationStarted?.fulfill()
        }
    }

    func requestAuthorization() async -> Bool {
        permissionRequests += 1
        guard holdAuthorization else { return authorizationGranted }
        return await withCheckedContinuation { continuation in
            authorization = continuation
            authorizationStarted?.fulfill()
        }
    }

    func finishStatusCheck() throws {
        let continuation = try XCTUnwrap(statusRequest)
        statusRequest = nil
        continuation.resume(returning: status)
    }

    func finishAuthorization() throws {
        let continuation = try XCTUnwrap(authorization)
        authorization = nil
        continuation.resume(returning: authorizationGranted)
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        requests.append(request)
        return submissionAccepted
    }
}

final class UpdaterTests: XCTestCase {
    @MainActor
    func testUpdateNotificationResponseOpensAndReusesSettingsWithoutInstalling() async throws {
        for automaticFailure in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasUpdateNotice-" + UUID().uuidString)
            let manager = PhotoManager(storageDirectory: root)
            let owner = AppDelegate(manager: manager)
            let previousOwner = AppDelegate.current
            AppDelegate.current = owner
            defer {
                owner.settingsWindow?.close()
                owner.settingsWindow = nil
                AppDelegate.current = previousOwner
                try? FileManager.default.removeItem(at: root)
            }
            let notifications = TestUpdaterNotifications()
            let (updater, defaults, feed) = try scheduledFixture(notifications: notifications)
            defaults.removeObject(forKey: "lastNotifiedVersion")
            defaults.removeObject(forKey: "lastAutomaticUpdateFailureVersion")
            updater.checkFrequency = .hourly
            updater.automaticUpdatesEnabled = automaticFailure
            var payload: [String: Any] = ["latestVersion": "99.0.0", "downloadURL": "https://example.invalid/release"]
            if automaticFailure { payload["minimumOSVersion"] = "999.0" }
            let check = Task { await updater.check(userInitiated: false) }
            await fulfillment(of: [feed.started], timeout: 3)
            try feed.release(payload: JSONSerialization.data(withJSONObject: payload))
            await check.value
            let request = try XCTUnwrap(notifications.requests.first)
            XCTAssertEqual(notifications.requests.count, 1)
            let destination = request.content.userInfo["arras-action"] as? String
            let url = request.content.userInfo["url"] as? String
            let phase = updater.phase

            updater.handleNotificationResponse(actionIdentifier: UNNotificationDismissActionIdentifier,
                                               destination: destination, url: url)
            XCTAssertNil(owner.settingsWindow, "Dismissing an update banner must not open Settings")
            updater.handleNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                               destination: destination, url: url)
            XCTAssertTrue(owner.settingsWindow?.isVisible == true, "Clicking an update or failure banner should open its controls")
            XCTAssertEqual(owner.settingsNavigation.selection, .preferences)
            if let window = owner.settingsWindow {
                let deadline = Date().addingTimeInterval(2)
                while owner.settingsNavigation.updatesRequest != nil && Date() < deadline {
                    window.contentView?.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertNil(owner.settingsNavigation.updatesRequest, "The displayed Preferences view should reveal Updates")
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(preferencesScrollView(in: content))
                let document = try XCTUnwrap(scroll.documentView)
                let top = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentView.bounds.height)
                XCTAssertNotEqual(scroll.contentView.bounds.minY, top, accuracy: 1,
                                  "Updates navigation should move the actual Preferences viewport below its opening position")
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let capture = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: content.bounds.size))
                capture.name = automaticFailure ? "Update failure Preferences viewport" : "Update available Preferences viewport"
                capture.lifetime = .keepAlways
                add(capture)
                owner.settingsNavigation.selection = .privacy
                owner.showSettingsWindow()
                XCTAssertEqual(owner.settingsNavigation.selection, .privacy, "Ordinary Settings reopening preserves the chosen tab")
                window.orderOut(nil)
                updater.handleNotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                   destination: destination, url: url)
                XCTAssertTrue(owner.settingsWindow === window)
                XCTAssertTrue(window.isVisible)
                XCTAssertEqual(owner.settingsNavigation.selection, .preferences)
            }
            XCTAssertEqual(updater.phase, phase, "Clicking a banner must not start installation or a new check")
            XCTAssertEqual(feed.requests, 1)
            XCTAssertEqual(updater.automaticUpdatesEnabled, automaticFailure)
        }
    }

    @MainActor
    private func preferencesScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = preferencesScrollView(in: child) { return scroll }
        }
        return nil
    }

    @MainActor
    private func scheduledFixture(notifications: (any UpdaterNotifications)? = nil) throws -> (Updater, UserDefaults, HeldUpdaterFeed) {
        let suite = "ArrasScheduledUpdateTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let feed = HeldUpdaterFeed(started: expectation(description: "Private update feed requested"),
                                   expectedURL: Updater.appcastURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldUpdaterFeedProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Arras-Updater-Test": feed.identifier]
        let session = URLSession(configuration: configuration)
        // A regressed automatic path must fail its assertion without prompting for notifications.
        defaults.set("99.0.0", forKey: "lastAutomaticUpdateFailureVersion")
        defaults.set("99.0.0", forKey: "lastNotifiedVersion")
        addTeardownBlock {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            feed.unregister()
        }
        return (Updater(defaults: defaults, session: session, notifications: notifications), defaults, feed)
    }

    @MainActor
    func testChangedPreferencesCancelNotificationsWhileAuthorizationIsPending() async throws {
        try await exerciseNotificationPreferenceChanges(holdingStatus: false)
    }

    @MainActor
    func testChangedPreferencesAvoidPermissionPromptAfterDelayedStatusCheck() async throws {
        try await exerciseNotificationPreferenceChanges(holdingStatus: true)
    }

    @MainActor
    private func exerciseNotificationPreferenceChanges(holdingStatus: Bool) async throws {
        let cases = [("available", false, true), ("failure", true, true), ("announcement", false, true),
                     ("available", false, false), ("failure", true, false)]
        for (kind, automatic, selectNever) in cases {
            let notifications = TestUpdaterNotifications()
            notifications.status = .notDetermined
            notifications.holdStatus = holdingStatus
            notifications.holdAuthorization = !holdingStatus
            let started = expectation(description: "\(kind) notification authorization started")
            notifications.authorizationStarted = started
            let (updater, defaults, feed) = try scheduledFixture(notifications: notifications)
            for key in ["lastNotifiedVersion", "lastAutomaticUpdateFailureVersion", "lastNotifiedAnnouncementID"] {
                defaults.removeObject(forKey: key)
            }
            updater.checkFrequency = .hourly
            updater.automaticUpdatesEnabled = automatic
            var payload: [String: Any] = ["latestVersion": "99.0.0", "downloadURL": "https://example.invalid/release", "sha256": "00"]
            if kind == "failure" { payload["minimumOSVersion"] = "999.0" }
            if kind == "announcement" {
                payload["announcement"] = ["id": "fixture", "title": "Test announcement", "body": "Sample message"]
            }
            let check = Task { await updater.check(userInitiated: false) }
            await fulfillment(of: [feed.started], timeout: 3)
            try feed.release(payload: JSONSerialization.data(withJSONObject: payload))
            await fulfillment(of: [started], timeout: 3)
            if selectNever { updater.checkFrequency = .never }
            else { updater.automaticUpdatesEnabled.toggle() }
            if holdingStatus { try notifications.finishStatusCheck() }
            else { try notifications.finishAuthorization() }
            await check.value
            if holdingStatus {
                XCTAssertEqual(notifications.permissionRequests, 0,
                               "Changed preferences must prevent a new permission prompt; kind=\(kind), selected Never=\(selectNever)")
            }
            XCTAssertTrue(notifications.requests.isEmpty,
                          "Changed preferences must suppress a pending \(kind) notification; selected Never=\(selectNever)")
            for key in ["lastNotifiedVersion", "lastAutomaticUpdateFailureVersion", "lastNotifiedAnnouncementID"] {
                XCTAssertNil(defaults.object(forKey: key), "A suppressed notification must not be acknowledged: \(key)")
            }
            XCTAssertEqual(feed.requests, 1)
        }
    }

    @MainActor
    func testManualCheckCanDeliverAnnouncementWithScheduleNever() async throws {
        let notifications = TestUpdaterNotifications()
        notifications.status = .notDetermined
        let (updater, defaults, feed) = try scheduledFixture(notifications: notifications)
        updater.checkFrequency = .never
        updater.automaticUpdatesEnabled = false
        let payload: [String: Any] = ["latestVersion": updater.currentVersion, "downloadURL": "https://example.invalid/release",
            "announcement": ["id": "manual", "title": "Test announcement", "body": "Sample message", "url": "https://example.invalid/announcement"]]
        let check = Task { await updater.check(userInitiated: true) }
        await fulfillment(of: [feed.started], timeout: 3)
        try feed.release(payload: JSONSerialization.data(withJSONObject: payload))
        await check.value
        let request = try XCTUnwrap(notifications.requests.first)
        XCTAssertEqual(notifications.requests.count, 1)
        XCTAssertEqual(notifications.permissionRequests, 1)
        XCTAssertEqual(request.identifier, "announcement-manual")
        XCTAssertEqual(request.content.title, "Test announcement")
        XCTAssertEqual(request.content.body, "Sample message")
        XCTAssertEqual(request.content.userInfo["url"] as? String, "https://example.invalid/announcement")
        XCTAssertEqual(defaults.string(forKey: "lastNotifiedAnnouncementID"), "manual")
        XCTAssertTrue(notifications.delegate === updater)
        XCTAssertEqual(updater.phase, .upToDate)
    }

    @MainActor
    func testNotificationAcknowledgementRequiresPermissionAndAcceptedSubmission() async throws {
        let cases: [(UNAuthorizationStatus, Bool, Bool)] = [(.denied, false, true), (.notDetermined, false, true),
            (.authorized, true, false), (.notDetermined, true, false), (.authorized, true, true), (.notDetermined, true, true)]
        for (status, granted, accepted) in cases {
            let notifications = TestUpdaterNotifications()
            notifications.status = status
            notifications.authorizationGranted = granted
            notifications.submissionAccepted = accepted
            let (updater, defaults, feed) = try scheduledFixture(notifications: notifications)
            defaults.removeObject(forKey: "lastNotifiedVersion")
            updater.checkFrequency = .hourly
            updater.automaticUpdatesEnabled = false
            let check = Task { await updater.check(userInitiated: false) }
            await fulfillment(of: [feed.started], timeout: 3)
            try feed.release()
            await check.value
            XCTAssertEqual(notifications.permissionRequests, status == .notDetermined ? 1 : 0)
            XCTAssertEqual(notifications.requests.count, granted ? 1 : 0)
            XCTAssertEqual(defaults.string(forKey: "lastNotifiedVersion"), granted && accepted ? "99.0.0" : nil)
        }
    }

    @MainActor
    func testNeverCancelsScheduledFeedAlreadyInFlight() async throws {
        let (updater, defaults, feed) = try scheduledFixture()
        updater.checkFrequency = .hourly
        updater.automaticUpdatesEnabled = true
        let check = Task { await updater.check(userInitiated: false) }
        await fulfillment(of: [feed.started], timeout: 3)
        updater.checkFrequency = .never
        try feed.release()
        await check.value
        XCTAssertEqual(updater.phase, .idle)
        XCTAssertNil(updater.latestKnownVersion)
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheck"))
        XCTAssertEqual(feed.requests, 1)
    }

    @MainActor
    func testManualCheckRemainsAvailableWithScheduleNever() async throws {
        let (updater, _, feed) = try scheduledFixture()
        updater.checkFrequency = .never
        updater.automaticUpdatesEnabled = false
        let check = Task { await updater.check(userInitiated: true) }
        await fulfillment(of: [feed.started], timeout: 3)
        try feed.release()
        await check.value
        XCTAssertEqual(updater.phase, .available(version: "99.0.0", notes: nil))
        XCTAssertEqual(updater.latestKnownVersion, "99.0.0")
        XCTAssertNotNil(updater.lastChecked)
    }

    @MainActor
    func testNeverStopsADeferredAutomaticInstallation() async throws {
        let (updater, _, feed) = try scheduledFixture()
        updater.checkFrequency = .hourly
        updater.automaticUpdatesEnabled = false
        let check = Task { await updater.check(userInitiated: true) }
        await fulfillment(of: [feed.started], timeout: 3)
        try feed.release()
        await check.value
        updater.automaticUpdatesEnabled = true
        updater.checkFrequency = .never
        await updater.installPendingUpdate(automatically: true)
        XCTAssertEqual(updater.phase, .available(version: "99.0.0", notes: nil))
        XCTAssertEqual(feed.requests, 1)
    }

    @MainActor
    func testAutomaticInstallationWaitsForManualImportAndResumesAfterPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasUpdateImport-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: root)
        let delegate = AppDelegate(manager: manager)
        let previousOwner = AppDelegate.current
        // Keep SwiftUI's application-delegate wrapper installed, as in production.
        AppDelegate.current = delegate
        defer {
            AppDelegate.current = previousOwner
            manager.windows.values.forEach { $0.hidePhoto() }
            manager.windows.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
        let (updater, _, feed) = try scheduledFixture()
        updater.checkFrequency = .hourly
        updater.automaticUpdatesEnabled = false
        let check = Task { await updater.check(userInitiated: true) }
        await fulfillment(of: [feed.started], timeout: 3)
        try feed.release()
        await check.value

        let preparing = expectation(description: "Manual sample import is preparing")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        manager.prepareImportedData = { data, directory, name in
            preparing.fulfill()
            precondition(release.wait(timeout: .now() + 5) == .success)
            return PhotoIngest.prepare(data: data, in: directory, originalName: name)
        }
        let data = try StarterArtwork.animatedGIFData()
        let importing = Task { @MainActor in await manager.importPhotos(data: [data]) }
        await fulfillment(of: [preparing], timeout: 3)
        XCTAssertTrue(manager.hasPendingMediaImport)
        updater.automaticUpdatesEnabled = true
        await updater.installPendingUpdate(automatically: true)
        XCTAssertEqual(updater.phase, .available(version: "99.0.0", notes: nil),
                       "Automatic installation must defer until the manual import is durable")
        release.signal()
        let result = await importing.value
        XCTAssertEqual(result.acceptedCount, 1)
        XCTAssertFalse(manager.hasPendingMediaImport)
        await updater.installPendingUpdate(automatically: true)
        // The fixture deliberately advertises a non-archive URL, preventing replacement.
        XCTAssertEqual(updater.phase, .failed("The available update is not a downloadable archive."),
                       "An automatic attempt must be eligible again after the import ends")
    }

    @MainActor
    func testAutomaticInstallationWaitsUntilTheRuntimeOwnerIsReady() async throws {
        let (updater, _, feed) = try scheduledFixture()
        updater.checkFrequency = .hourly
        updater.automaticUpdatesEnabled = false
        let check = Task { await updater.check(userInitiated: true) }
        await fulfillment(of: [feed.started], timeout: 3)
        try feed.release()
        await check.value
        let owner = try XCTUnwrap(AppDelegate.current)
        AppDelegate.current = nil
        defer { AppDelegate.current = owner }
        XCTAssertThrowsError(try ArrasIntentBridge.manager())
        updater.automaticUpdatesEnabled = true
        await updater.installPendingUpdate(automatically: true)
        XCTAssertEqual(updater.phase, .available(version: "99.0.0", notes: nil))
        AppDelegate.current = owner
        XCTAssertTrue(try ArrasIntentBridge.manager() === owner.manager)
    }

    @MainActor
    func testAutomaticInstallationWaitsForPhotoAndCollageGesturesThenResumes() async throws {
        for target in ["photo", "collage", "member"] {
            for resizing in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasUpdateGesture-" + UUID().uuidString)
                let manager = PhotoManager(storageDirectory: root)
                let owner = AppDelegate(manager: manager)
                let previousOwner = AppDelegate.current
                AppDelegate.current = owner
                defer {
                    AppDelegate.current = previousOwner
                    manager.cancelCollageInteractions(endAppearancePreviews: true)
                    manager.windows.values.forEach { $0.hidePhoto() }
                    manager.windows.removeAll()
                    manager.collageLabelWindows.values.forEach { $0.close() }
                    manager.collageLabelWindows.removeAll()
                    try? FileManager.default.removeItem(at: root)
                }
                XCTAssertTrue(manager.addStarterExample(target == "photo" ? .minimal : .galleryWall))
                let item = try XCTUnwrap(manager.photos.first { target == "collage" ? $0.desktopCollage != nil : $0.desktopCollage == nil })
                let window = try XCTUnwrap(manager.windows[item.id])
                let surface = try XCTUnwrap(window.contentView)
                let frame = window.photoFrame
                let start = resizing ? CGPoint(x: frame.maxX - 2, y: frame.maxY - 2)
                    : (target == "collage" ? CGPoint(x: frame.minX + 6, y: frame.midY) : CGPoint(x: frame.midX, y: frame.midY))
                let (updater, _, feed) = try scheduledFixture()
                updater.checkFrequency = .hourly
                updater.automaticUpdatesEnabled = false
                let check = Task { await updater.check(userInitiated: true) }
                await fulfillment(of: [feed.started], timeout: 3)
                try feed.release()
                await check.value
                updater.automaticUpdatesEnabled = true

                surface.mouseDown(with: try testMouseEvent(.leftMouseDown, in: window, at: start))
                XCTAssertFalse(manager.collageDrags.isEmpty && manager.collageMoveSnapshots.isEmpty && manager.collageResizeSnapshots.isEmpty,
                               "The native handler must begin a real gesture: \(target), resize=\(resizing)")
                await updater.installPendingUpdate(automatically: true)
                XCTAssertEqual(updater.phase, .available(version: "99.0.0", notes: nil),
                               "Do not automatically install while the pointer is held: \(target), resize=\(resizing)")

                let end = CGPoint(x: start.x + 20, y: start.y + 12)
                surface.mouseDragged(with: try testMouseEvent(.leftMouseDragged, in: window, at: end, modifiers: .option))
                await updater.installPendingUpdate(automatically: true)
                XCTAssertEqual(updater.phase, .available(version: "99.0.0", notes: nil),
                               "Do not interrupt live movement/resizing: \(target), resize=\(resizing)")
                if resizing { surface.cancelOperation(nil) }
                else { surface.mouseUp(with: try testMouseEvent(.leftMouseUp, in: window, at: end)) }
                let deadline = Date().addingTimeInterval(2)
                while !manager.collageFlights.isEmpty && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(manager.collageDrags.isEmpty && manager.collageMoveSnapshots.isEmpty
                              && manager.collageResizeSnapshots.isEmpty && manager.collageFlights.isEmpty)
                await updater.installPendingUpdate(automatically: true)
                // The held feed deliberately uses a non-ZIP URL, so eligibility
                // is observable without replacing or terminating the test app.
                XCTAssertEqual(updater.phase, .failed("The available update is not a downloadable archive."),
                               "A completed or cancelled gesture must release update deferral")
                XCTAssertEqual(feed.requests, 1)
            }
        }
    }

    func testArchivePreparationRejectsChecksumBeforeExtracting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("update.zip")
        try Data("Not an archive".utf8).write(to: archive)
        XCTAssertThrowsError(try Updater.prepareArchive(archive, checksum: String(repeating: "0", count: 64), version: "2.5.0")) { error in
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("expanded").path))
    }

    func testArchivePreparationAcceptsTheSignedHostBundleOffMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("update.zip")
        let bundle = Bundle.main.bundleURL
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let staged = try await Task.detached(priority: .utility) {
            XCTAssertFalse(Thread.isMainThread)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--keepParent", bundle.path, archive.path]
            try zip.run(); zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0)
            let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            return try Updater.prepareArchive(archive, checksum: digest, version: version)
        }.value
        XCTAssertEqual(staged.deletingLastPathComponent().lastPathComponent, "expanded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/Arras").path))
    }

    @MainActor
    func testStartupHealthRequiresMatchingVersionAndSuccessfulMarkerWrite() throws {
        let suite = "ArrasUpdateHealth-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("health")
        defaults.set(marker.path, forKey: Updater.updateHealthMarkerKey)
        defaults.set("0.0.0", forKey: Updater.justUpdatedKey)
        Updater.markUpdateHealthyIfNeeded(defaults: defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(defaults.string(forKey: Updater.updateHealthMarkerKey), marker.path)
        defaults.set(Constants.version, forKey: Updater.justUpdatedKey)
        Updater.markUpdateHealthyIfNeeded(defaults: defaults)
        XCTAssertEqual(try String(contentsOf: marker), "healthy\n")
        XCTAssertNil(defaults.string(forKey: Updater.updateHealthMarkerKey))
        let unavailable = directory.appendingPathComponent("missing/health")
        defaults.set(unavailable.path, forKey: Updater.updateHealthMarkerKey)
        Updater.markUpdateHealthyIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: Updater.updateHealthMarkerKey), unavailable.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
    }

    @MainActor
    func testVersionComparisonUsesSemVerPrecedence() {
        XCTAssertTrue(Updater.compare("2.4.10", isNewerThan: "2.4.9"))
        XCTAssertTrue(Updater.compare("3.0.0", isNewerThan: "2.99.99"))
        XCTAssertFalse(Updater.compare("2.4.3", isNewerThan: "2.4.4"))
        XCTAssertTrue(Updater.compare("2.4.0", isNewerThan: "2.4.0-rc.1"))
        XCTAssertTrue(Updater.compare("2.4.0-rc.10", isNewerThan: "2.4.0-rc.2"))
        XCTAssertTrue(Updater.compare("2.4.0-rc.2", isNewerThan: "2.4.0-rc.1"))
        XCTAssertTrue(Updater.compare("2.4.0-rc.1", isNewerThan: "2.4.0-rc"))
        XCTAssertFalse(Updater.compare("2.4.0+build.2", isNewerThan: "2.4.0+build.1"))
        XCTAssertFalse(Updater.compare("2.4", isNewerThan: "2.3.0"))
        XCTAssertFalse(Updater.isValidVersion("2.4"))
        XCTAssertFalse(Updater.isValidVersion("2.4.0-rc..1"))
    }

    @MainActor
    func testUpdateEndpointsAvoidCheckRedirectAndUniquelyTrackDownloads() throws {
        XCTAssertEqual(Updater.appcastURL.host, "raw.githubusercontent.com")

        let source = try XCTUnwrap(URL(string: "https://github.com/example/app/releases/download/v2.4.5/App.zip?source=arras-updater&version=2.4.5"))
        let requestID = UUID(uuidString: "A4A8BCDF-193B-4A13-8416-E92C66391055")!
        let tracked = Updater.trackedDownloadURL(source, requestID: requestID)
        let components = try XCTUnwrap(URLComponents(url: tracked, resolvingAgainstBaseURL: false))

        XCTAssertEqual(tracked.pathExtension, "zip")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "source" })?.value, "arras-updater")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "version" })?.value, "2.4.5")
        XCTAssertEqual(components.queryItems?.filter { $0.name == "request" }.map(\.value), [requestID.uuidString.lowercased()])
    }

    @MainActor
    func testAutomaticUpdatesDefaultOnAndHonorSelectedCadence() throws {
        let suite = "ArrasUpdaterDefaultsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = Updater(defaults: defaults)

        XCTAssertTrue(updater.automaticUpdatesEnabled)
        XCTAssertEqual(updater.checkFrequency, .daily)
        XCTAssertEqual(updater.activeCheckFrequency, .daily)

        updater.checkFrequency = .weekly
        XCTAssertEqual(updater.activeCheckFrequency, .weekly)
        updater.checkFrequency = .never
        XCTAssertEqual(updater.activeCheckFrequency, .never)
        updater.checkFrequency = .weekly
        updater.automaticUpdatesEnabled = false
        XCTAssertEqual(updater.activeCheckFrequency, .weekly)
        updater.checkFrequency = .hourly
        updater.automaticUpdatesEnabled = true
        XCTAssertEqual(updater.activeCheckFrequency, .hourly)
    }

    func testLastCheckedPhrasingUsesCurrentTime() {
        let checked = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UpdateCheckPhrasing.lastChecked(checked, now: checked), "Checked just now.")
        XCTAssertNotEqual(UpdateCheckPhrasing.lastChecked(checked, now: checked.addingTimeInterval(7200)), "Checked just now.")
    }

    @MainActor
    func testUpdateDueChecksRespectCadenceAndFailureRetryFloor() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(86400), lastAttempt: now.addingTimeInterval(86400), interval: 3600, now: now))
        XCTAssertTrue(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(-3600), lastAttempt: nil, interval: Updater.CheckFrequency.hourly.rawValue, now: now))
        XCTAssertFalse(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(-3600), lastAttempt: now.addingTimeInterval(-60), interval: 3600, now: now))
        XCTAssertTrue(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(-3600), lastAttempt: now.addingTimeInterval(-900), interval: 3600, now: now))
        XCTAssertFalse(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(-3600), lastAttempt: nil, interval: Updater.CheckFrequency.daily.rawValue, now: now))
        XCTAssertFalse(Updater.backgroundCheckIsDue(lastChecked: nil, lastAttempt: nil, interval: 0, now: now))
        XCTAssertFalse(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(-60), lastAttempt: nil, interval: 86400, now: now))
        XCTAssertFalse(Updater.backgroundCheckIsDue(lastChecked: nil, lastAttempt: now.addingTimeInterval(-899), interval: 86400, now: now))
        XCTAssertTrue(Updater.backgroundCheckIsDue(lastChecked: nil, lastAttempt: now.addingTimeInterval(-901), interval: 86400, now: now))
        XCTAssertTrue(Updater.backgroundCheckIsDue(lastChecked: now.addingTimeInterval(-86401), lastAttempt: now.addingTimeInterval(-901), interval: 86400, now: now))
    }

    @MainActor
    func testUpdateNotificationBodyIncludesVersionAndUsefulReleaseStatement() {
        XCTAssertEqual(
            Updater.updateNotificationBody(version: "2.5.0", releaseNotes: "Improves Spaces and fixes import reliability."),
            "Version 2.5.0 is available. Improves Spaces and fixes import reliability."
        )
        XCTAssertTrue(
            Updater.updateNotificationBody(version: "2.5.0", releaseNotes: nil)
                .contains("latest fixes and improvements")
        )
    }

    @MainActor
    func testAvailableUpdateStatusIncludesReleaseNotesForAssistiveTechnologies() {
        let status = UpdateStatusPhrasing.availableUpdate(
            version: "2.5.0",
            notes: "Improves Spaces and fixes import reliability.",
            currentVersion: "2.4.5"
        )

        XCTAssertEqual(
            status,
            "Version 2.5.0 is available. You have 2.4.5. Improves Spaces and fixes import reliability."
        )
    }

    @MainActor
    func testMismatchedUpdateBreadcrumbSurfacesARealFailure() {
        let updater = Updater.shared
        updater.announceInstallResult(expectedVersion: "99.0.0")

        guard case .failed(let message) = updater.phase else {
            XCTFail("A breadcrumb for a version that did not launch must not report success")
            return
        }
        XCTAssertTrue(message.contains("99.0.0"))
        XCTAssertTrue(message.contains(Constants.version))
    }


}
