import AppKit
import XCTest
@testable import Arras

private actor TelemetryStub {
    var requests: [URLRequest] = []
    var uploadStatus = 204
    var control = Data(#"{"schema_version":1,"enabled":true}"#.utf8)
    var failure: URLError.Code?
    var delay = false
    func send(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
        requests.append(request)
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if let failure { throw URLError(failure) }
        return TelemetryHTTPResponse(status: request.httpMethod == "GET" ? 200 : uploadStatus,
                                     data: request.httpMethod == "GET" ? control : Data())
    }
    func configure(status: Int = 204, control: String? = nil, failure: URLError.Code? = nil, delay: Bool = false) {
        uploadStatus = status; self.failure = failure; self.delay = delay
        if let control { self.control = Data(control.utf8) }
    }
    func count(_ method: String) -> Int { requests.filter { $0.httpMethod == method }.count }
    func uploads() -> [Data] { requests.compactMap(\.httpBody) }
}

final class TelemetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let meta = TelemetryMetadata(version: "2.4.6", build: "19", osVersion: "27.0", architecture: "arm64")
    private let config = TelemetryConfiguration(endpoint: URL(string: "https://example.invalid/api/telemetry/v1")!, environment: .development, dryRun: false)
    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasTelemetryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func engine(_ directory: URL, stub: TelemetryStub = TelemetryStub(), metadata: TelemetryMetadata? = nil) throws -> TelemetryEngine {
        try TelemetryEngine(directory: directory, metadata: metadata ?? meta, configuration: config, transport: { try await stub.send($0) })
    }

    func testRandomIdentityPersistsAndSeparateInstallsDiffer() async throws {
        let dir = try root(), first = try engine(dir), second = try engine(dir), other = try engine(root())
        XCTAssertEqual(first.installID, second.installID)
        XCTAssertNotEqual(first.installID, other.installID)
        XCTAssertEqual(first.installID.uuid.6 >> 4, 4)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("install-id").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testIdentityRegeneratesOnlyWhenIdentityFileRemoved() throws {
        let dir = try root(), first = try engine(dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("install-id"))
        XCTAssertNotEqual(first.installID, try engine(dir).installID)
        try Data("private user text".utf8).write(to: dir.appendingPathComponent("install-id"))
        XCTAssertThrowsError(try engine(dir))
    }
    func testMilestonesAndDailySnapshotsDeduplicateAcrossRelaunchAndClockChanges() async throws {
        let dir = try root(), first = try engine(dir)
        await first.start(with: TelemetryFacts(counts: [:]), now: now)
        let facts = TelemetryFacts(counts: [.photo: 3, .container: 1])
        for _ in 0..<100 { await first.observe(facts, now: now) }
        await first.observe(facts, now: now.addingTimeInterval(-86400))
        let second = try engine(dir)
        await second.start(with: facts, now: now)
        let batch = await second.pendingBatch()
        for event in [TelemetryEventType.firstRun, .firstWidgetCreated, .firstCollageCreated, .dailyConfiguration] {
            XCTAssertEqual(batch.events.filter { $0.event == event }.count, 1)
        }
        XCTAssertEqual(batch.events.filter { $0.event == .firstFeatureUsed }.count, 2)
        await second.observe(facts, now: now.addingTimeInterval(86400))
        let next = await second.pendingBatch()
        XCTAssertEqual(next.events.filter { $0.event == .dailyConfiguration }.count, 2)
    }
    func testExistingInstallsDoNotMasqueradeAsNewWidgetConversions() async throws {
        let service = try engine(root())
        await service.start(with: TelemetryFacts(counts: [.collage: 1]), now: now)
        let events = await service.pendingBatch().events
        XCTAssertEqual(events.first?.existingConfiguration, true)
        XCTAssertFalse(events.contains { [.firstWidgetCreated, .firstCollageCreated, .firstFeatureUsed].contains($0.event) })
    }
    func testVersionTransitionsPersistWithoutRepeatingOnSameVersionRelaunch() async throws {
        let dir = try root(), first = try engine(dir)
        await first.start(with: TelemetryFacts(counts: [:]), now: now)
        let updatedMeta = TelemetryMetadata(version: "2.5.0", build: "20", osVersion: "27.0", architecture: "arm64")
        let second = try engine(dir, metadata: updatedMeta)
        await second.start(with: TelemetryFacts(counts: [:]), now: now)
        let third = try engine(dir, metadata: updatedMeta)
        await third.start(with: TelemetryFacts(counts: [:]), now: now)
        let events = await third.pendingBatch().events.filter { $0.event == .appUpdated }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.previousVersion, "2.4.6")
        XCTAssertEqual(events.first?.appVersion, "2.5.0")
    }
    func testOfflineAndTimeoutBackoffPersistsAcrossRelaunch() async throws {
        for code in [URLError.Code.notConnectedToInternet, .timedOut] {
            let dir = try root(), stub = TelemetryStub()
            await stub.configure(failure: code)
            let first = try engine(dir, stub: stub)
            await first.start(with: TelemetryFacts(counts: [:]), now: now)
            for _ in 0..<30 { await first.flush(now: now) }
            let second = try engine(dir, stub: stub)
            await second.start(with: TelemetryFacts(counts: [:]), now: now)
            await second.flush(now: now.addingTimeInterval(60))
            let initialAttempts = await stub.count("GET")
            XCTAssertEqual(initialAttempts, 1)
            for hours in [6.0, 12, 18, 23] { await second.flush(now: now.addingTimeInterval(hours * 3600)) }
            let attempts = await stub.count("GET")
            // UTC rollover may permit a new day's attempt, but never a burst.
            XCTAssertLessThanOrEqual(attempts, 4)
            let empty = await awaitBatchEmpty(second)
            XCTAssertFalse(empty)
        }
    }
    private func awaitBatchEmpty(_ service: TelemetryEngine) async -> Bool { await service.pendingBatch().events.isEmpty }
    func testSuccessfulDeliveryOccursAtMostOncePerUTCDayAndRetriesKeepIDs() async throws {
        let stub = TelemetryStub(), service = try engine(root(), stub: stub)
        await stub.configure(status: 503)
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        await service.flush(now: now)
        await stub.configure()
        await service.flush(now: now.addingTimeInterval(6 * 3600))
        let sent = await stub.uploads()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1])
        await service.observe(TelemetryFacts(counts: [.photo: 1]), now: now.addingTimeInterval(6 * 3600))
        for _ in 0..<20 { await service.flush(now: now.addingTimeInterval(7 * 3600)) }
        let count = await stub.count("POST")
        XCTAssertEqual(count, 2)
    }
    func testRepeatedOutageBackoffSurvivesRelaunchAndResetsOnSuccess() async throws {
        let directory = try root(), stub = TelemetryStub()
        await stub.configure(status: 503)
        let first = try engine(directory, stub: stub)
        await first.start(with: TelemetryFacts(counts: [:]), now: now)
        await first.flush(now: now)
        await first.flush(now: now.addingTimeInterval(6 * 3600))
        let relaunched = try engine(directory, stub: stub)
        await relaunched.flush(now: now.addingTimeInterval(12 * 3600))
        var count = await stub.count("POST")
        XCTAssertEqual(count, 2)
        await relaunched.flush(now: now.addingTimeInterval(18 * 3600))
        await relaunched.flush(now: now.addingTimeInterval(24 * 3600))
        count = await stub.count("POST")
        XCTAssertEqual(count, 3)
        await stub.configure()
        await relaunched.flush(now: now.addingTimeInterval(42 * 3600))
        count = await stub.count("POST")
        XCTAssertEqual(count, 4)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any])
        XCTAssertEqual(state["failedAttempts"] as? Int, 0)
    }

    func testRecoveredWeeklyDeliveryClearsOutageDelayWithoutAllowingSameWeekRepeat() async throws {
        let wednesday = Date(timeIntervalSince1970: 20733 * 86400 + 3600)
        let weekly = TelemetryConfiguration(endpoint: config.endpoint, environment: .development, dryRun: false, cadence: .weekly)
        let directory = try root(), stub = TelemetryStub()
        let first = try TelemetryEngine(directory: directory, metadata: meta, configuration: weekly,
                                        transport: { try await stub.send($0) })
        await stub.configure(status: 503)
        await first.start(with: TelemetryFacts(counts: [.photo: 1]), now: wednesday)
        for hour in [0, 6, 18, 42, 90] {
            await first.flush(now: wednesday.addingTimeInterval(TimeInterval(hour * 3600)))
        }
        var uploads = await stub.count("POST")
        XCTAssertEqual(uploads, 5)

        let tuesday = wednesday.addingTimeInterval(13 * 86400)
        await stub.configure()
        await first.observe(TelemetryFacts(counts: [.photo: 2]), now: tuesday)
        await first.flush(now: tuesday)
        uploads = await stub.count("POST")
        XCTAssertEqual(uploads, 6)
        var pending = await first.pendingBatch()
        XCTAssertTrue(pending.events.isEmpty)

        let relaunched = try TelemetryEngine(directory: directory, metadata: meta, configuration: weekly,
                                             transport: { try await stub.send($0) })
        XCTAssertEqual(first.installID, relaunched.installID)
        let facts = TelemetryFacts(counts: [.photo: 3, .collage: 1])
        await relaunched.start(with: facts, now: tuesday.addingTimeInterval(3600))
        pending = await relaunched.pendingBatch()
        XCTAssertFalse(pending.events.isEmpty)
        await relaunched.flush(now: tuesday.addingTimeInterval(3600))
        uploads = await stub.count("POST")
        XCTAssertEqual(uploads, 6, "A successful recovery still suppresses the rest of its UTC week")

        let nextWednesday = wednesday.addingTimeInterval(14 * 86400)
        await relaunched.observe(facts, now: nextWednesday)
        await relaunched.flush(now: nextWednesday)
        uploads = await stub.count("POST")
        XCTAssertEqual(uploads, 7, "A successful recovery must not leave another week of outage backoff")
        pending = await relaunched.pendingBatch()
        XCTAssertTrue(pending.events.isEmpty)
    }

    func testWeeklyBoundaryIsWednesdayUTCIncludingMonthAndYearTransitions() {
        let utc = ISO8601DateFormatter()
        for (before, after) in [
            ("2026-10-20T23:59:59Z", "2026-10-21T00:00:00Z"),
            ("2026-09-30T23:59:59Z", "2026-10-01T00:00:00Z"),
            ("2026-12-31T23:59:59Z", "2027-01-01T00:00:00Z")
        ] {
            let beforeDay = TelemetryEngine.day(utc.date(from: before)!)
            let afterDay = TelemetryEngine.day(utc.date(from: after)!)
            let difference = TelemetryConfiguration.Cadence.weekly.period(for: afterDay)
                - TelemetryConfiguration.Cadence.weekly.period(for: beforeDay)
            XCTAssertEqual(difference, before.hasPrefix("2026-10-20") ? 7 : 0)
        }
    }

    func testConcurrentFlushesShareOneInFlightRequest() async throws {
        let stub = TelemetryStub(), service = try engine(root(), stub: stub)
        await stub.configure(delay: true)
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await service.flush(now: self.now) } }
        }
        let count = await stub.count("POST")
        XCTAssertEqual(count, 1)
    }

    func testWeeklyCadenceCoalescesAndPersistsOneDeliveryPerUTCWeek() async throws {
        let wednesday = Date(timeIntervalSince1970: 20733 * 86400 + 3600)
        let weekly = TelemetryConfiguration(endpoint: config.endpoint, environment: .development, dryRun: false, cadence: .weekly)
        let dir = try root(), stub = TelemetryStub()
        let first = try TelemetryEngine(directory: dir, metadata: meta, configuration: weekly, transport: { try await stub.send($0) })
        await first.start(with: TelemetryFacts(counts: [.photo: 1]), now: wednesday)
        await first.observe(TelemetryFacts(counts: [.photo: 4]), now: wednesday.addingTimeInterval(86400))
        let pending = await first.pendingBatch()
        let snapshots = pending.events.filter { $0.event == .dailyConfiguration }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.configuration?.widgetCount, .twoToFour)
        await first.flush(now: wednesday.addingTimeInterval(86400))
        let relaunched = try TelemetryEngine(directory: dir, metadata: meta, configuration: weekly, transport: { try await stub.send($0) })
        await relaunched.start(with: TelemetryFacts(counts: [.photo: 5]), now: wednesday.addingTimeInterval(6 * 86400))
        await relaunched.flush(now: wednesday.addingTimeInterval(6 * 86400))
        var uploads = await stub.count("POST")
        XCTAssertEqual(uploads, 1)
        await relaunched.observe(TelemetryFacts(counts: [.photo: 5]), now: wednesday.addingTimeInterval(7 * 86400))
        await relaunched.flush(now: wednesday.addingTimeInterval(7 * 86400))
        uploads = await stub.count("POST")
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(first.installID, relaunched.installID)

        // Switching an already delivered daily install to weekly cannot repeat
        // its first-run event or deliver another snapshot in that same week.
        let oldDir = try root(), oldStub = TelemetryStub()
        let old = try engine(oldDir, stub: oldStub)
        await old.start(with: TelemetryFacts(counts: [:]), now: wednesday)
        await old.flush(now: wednesday)
        let changed = try TelemetryEngine(directory: oldDir, metadata: meta, configuration: weekly, transport: { try await oldStub.send($0) })
        await changed.start(with: TelemetryFacts(counts: [:]), now: wednesday.addingTimeInterval(2 * 86400))
        await changed.flush(now: wednesday.addingTimeInterval(2 * 86400))
        uploads = await oldStub.count("POST")
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(old.installID, changed.installID)
    }
    func testRemoteKillSwitchDiscardsQueueWithoutUploading() async throws {
        let stub = TelemetryStub(), service = try engine(root(), stub: stub)
        await stub.configure(control: #"{"schema_version":1,"enabled":false}"#)
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        await service.flush(now: now)
        let posts = await stub.count("POST"), batch = await service.pendingBatch()
        XCTAssertEqual(posts, 0); XCTAssertTrue(batch.events.isEmpty)
        await service.flush(now: now.addingTimeInterval(3600))
        let gets = await stub.count("GET"); XCTAssertEqual(gets, 1)
    }
    func testMalformedControlResponsesFailClosed() async throws {
        for body in [#"{"enabled":true}"#, #"{"schema_version":true,"enabled":true}"#,
                     #"{"schema_version":2,"enabled":true}"#, #"{"schema_version":1,"enabled":1}"#,
                     #"{"schema_version":1,"enabled":true,"extra":"private"}"#] {
            let stub = TelemetryStub(), service = try engine(root(), stub: stub)
            await stub.configure(control: body)
            await service.start(with: TelemetryFacts(counts: [:]), now: now)
            await service.flush(now: now)
            let count = await stub.count("POST"); XCTAssertEqual(count, 0)
        }
    }
    func testPermanentRejectionDropsBatchButTemporaryRejectionRetainsIt() async throws {
        for status in [400, 413, 415, 422, 429, 500, 503, 302] {
            let stub = TelemetryStub(), service = try engine(root(), stub: stub)
            await stub.configure(status: status)
            await service.start(with: TelemetryFacts(counts: [:]), now: now)
            await service.flush(now: now)
            let batch = await service.pendingBatch()
            XCTAssertEqual(batch.events.isEmpty, [400, 413, 415, 422].contains(status))
        }
    }
    func testQueueAndAgeAreBoundedAfterLongOfflineUse() async throws {
        let service = try engine(root())
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        for day in 1...100 { await service.observe(TelemetryFacts(counts: [.photo: day]), now: now.addingTimeInterval(Double(day) * 86400)) }
        let batch = await service.pendingBatch()
        XCTAssertLessThanOrEqual(batch.events.count, 8)
        XCTAssertLessThanOrEqual(batch.events.count, TelemetryEngine.maximumQueueSize)
    }
    func testDryRunNeverCallsTransportAndRequestsContainNoCookiesOrPrivateHeaders() async throws {
        let stub = TelemetryStub()
        let dry = TelemetryConfiguration(endpoint: config.endpoint, environment: .development, dryRun: true)
        let service = try TelemetryEngine(directory: root(), metadata: meta, configuration: dry, transport: { try await stub.send($0) })
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        await service.flush(now: now)
        let count = await stub.count("GET"); XCTAssertEqual(count, 0)
        let online = try engine(root(), stub: stub)
        await online.start(with: TelemetryFacts(counts: [:]), now: now)
        await online.flush(now: now)
        let requests = await stub.requests
        XCTAssertEqual(requests.first?.timeoutInterval, 10)
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Arras-Telemetry/1")
        }
    }
    func testDamagedOrUnsafeTelemetryStateFailsClosed() async throws {
        let dir = try root(), service = try engine(dir)
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        let file = dir.appendingPathComponent("state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var queue = try XCTUnwrap(state["queue"] as? [[String: Any]])
        queue[0]["app_version"] = "/Users/private/photos/name.jpg"
        state["queue"] = queue
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        XCTAssertThrowsError(try engine(dir))
        try Data("damaged".utf8).write(to: file)
        XCTAssertThrowsError(try engine(dir))
    }
    func testUnsafePersistedSchedulingStateFailsClosedWithoutChangingFiles() async throws {
        let directory = try root(), service = try engine(directory)
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        let stateFile = directory.appendingPathComponent("state.json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any])
        let identity = try Data(contentsOf: directory.appendingPathComponent("install-id"))
        let photoFile = directory.appendingPathComponent("photos.json")
        let photoData = Data("unrelated photo storage".utf8)
        try photoData.write(to: photoFile)
        let invalid: [(String, Int)] = [
            ("snapshotDay", Int.max), ("successDay", Int.max), ("attemptDay", -1),
            ("attempts", -1), ("attempts", TelemetryEngine.maximumAttemptsPerDay + 1),
            ("failedAttempts", -1), ("failedAttempts", Int.max), ("nextAttempt", -1)
        ]
        for (key, value) in invalid {
            var state = original
            state[key] = value
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try data.write(to: stateFile)
            XCTAssertThrowsError(try engine(directory), "Damaged \(key)=\(value) must disable telemetry")
            XCTAssertEqual(try Data(contentsOf: stateFile), data, "Do not rewrite damaged telemetry state")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("install-id")), identity)
            XCTAssertEqual(try Data(contentsOf: photoFile), photoData)
        }
        var state = original
        var events = try XCTUnwrap(state["queue"] as? [[String: Any]])
        events[0]["day"] = Int.max
        state["queue"] = events
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: stateFile)
        XCTAssertThrowsError(try engine(directory), "Event days must also be safe for scheduling arithmetic")
        XCTAssertEqual(try Data(contentsOf: stateFile), data)
        XCTAssertEqual(try Data(contentsOf: photoFile), photoData)
    }
    func testMaximumOutageBackoffRemainsValidAcrossRelaunch() async throws {
        let directory = try root(), stub = TelemetryStub()
        await stub.configure(status: 503)
        var next = now
        for attempt in 1...8 {
            let service = try engine(directory, stub: stub)
            await service.start(with: .init(counts: [.photo: 1]), now: next)
            await service.flush(now: next)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("state.json"))
            ) as? [String: Any])
            XCTAssertEqual(state["failedAttempts"] as? Int, min(attempt, 6))
            let deadline = try XCTUnwrap(state["nextAttempt"] as? TimeInterval)
            let delay = min(7 * 86400, TelemetryEngine.retryInterval * pow(2, Double(min(attempt - 1, 5))))
            XCTAssertEqual(deadline - next.timeIntervalSince1970, delay, accuracy: 0.001)
            await service.flush(now: Date(timeIntervalSince1970: deadline - 1))
            let uploads = await stub.count("POST")
            XCTAssertEqual(uploads, attempt, "Relaunch must preserve the capped backoff")
            next = Date(timeIntervalSince1970: deadline)
        }
    }
    func testTelemetryStorageFailureCannotTriggerNetworkOrAffectPhotoData() async throws {
        let dir = try root(), stub = TelemetryStub(), service = try engine(dir, stub: stub)
        let photoData = Data("photos stay local".utf8), photoFile = dir.appendingPathComponent("photos.json")
        try photoData.write(to: photoFile)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state.json"), withIntermediateDirectories: false)
        await service.start(with: TelemetryFacts(counts: [:]), now: now)
        await service.flush(now: now)
        let count = await stub.count("GET"); XCTAssertEqual(count, 0)
        XCTAssertEqual(try Data(contentsOf: photoFile), photoData)
    }
    func testEndpointValidationAndNumericDimensionsExcludeArbitraryText() {
        XCTAssertEqual(TelemetryConfiguration.validatedCadence(nil), .daily)
        XCTAssertEqual(TelemetryConfiguration.validatedCadence(7), .weekly)
        for value: Any in [true, "7", 2, 7.5] {
            XCTAssertNil(TelemetryConfiguration.validatedCadence(value))
        }
        for url in ["http://example.com/a", "https://user:secret@example.com", "file:///photos", "https://example.com/a?private=name", "https://example.com/#secret"] {
            XCTAssertNil(TelemetryConfiguration.validatedEndpoint(url, allowLocal: true))
        }
        XCTAssertNotNil(TelemetryConfiguration.validatedEndpoint("http://127.0.0.1:3000/api/telemetry/v1", allowLocal: true))
        XCTAssertEqual(TelemetryMetadata.numericVersion("name / path.jpg"), "0")
        XCTAssertEqual(TelemetryCount(24), .twentyPlus)
        XCTAssertEqual(TelemetryCount(4), .twoToFour)
    }
    @MainActor
    func testPayloadAllowlistExcludesEveryPrivateModelField() async throws {
        let manager = PhotoManager(storageDirectory: try root())
        var photo = PhotoItem(filename: "private-filename.jpg")
        photo.customName = "private-user-text"; photo.displayIdentifier = "private-display-serial"
        photo.frameString = "{{111, 222}, {333, 444}}"; photo.isVisible = false
        var collage = PhotoItem(filename: "")
        var settings = DesktopCollageSettings()
        settings.caption = "private-caption"
        settings.labels = [CollageTextLabel(text: "private-label")]
        collage.desktopCollage = settings
        photo.collageParentID = collage.id
        manager.photos = [photo, collage]
        XCTAssertEqual(manager.telemetryFacts.counts[.collage], 1)
        XCTAssertEqual(manager.telemetryFacts.counts[.photo], 1)
        let service = try engine(root())
        await service.start(with: manager.telemetryFacts, now: now)
        let data = try JSONEncoder().encode(await service.pendingBatch())
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["private-", "filename", "frameString", "/Users/", "{{111, 222}", "clipboard", "bookmark", "displayIdentifier", "customName"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema_version", "install_id", "environment", "events"])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let snapshot = try XCTUnwrap(events.first { $0["event"] as? String == "daily_configuration" }?["configuration"] as? [String: Any])
        XCTAssertEqual(Set(snapshot.keys), ["widget_count", "collage_count", "counts_by_type"])
        XCTAssertEqual(snapshot["widget_count"] as? String, "2-4")
        XCTAssertEqual(snapshot["collage_count"] as? String, "1")
    }
}

extension TelemetryTests {
    func testDevelopmentAndDryRunCannotConsumeProductionState() async throws {
        let library = try root()
        let production = TelemetryConfiguration(endpoint: config.endpoint, environment: .production, dryRun: false)
        let development = TelemetryConfiguration(endpoint: config.endpoint, environment: .development, dryRun: false)
        let dryRun = TelemetryConfiguration(endpoint: config.endpoint, environment: .development, dryRun: true)
        let productionDirectory = production.storageDirectory(in: library)
        XCTAssertEqual(productionDirectory, library.appendingPathComponent("Telemetry", isDirectory: true))
        let stub = TelemetryStub()
        let original = try TelemetryEngine(directory: productionDirectory, metadata: meta, configuration: production,
                                          transport: { try await stub.send($0) })
        await original.start(with: .init(counts: [:]), now: now)
        let originalState = try Data(contentsOf: productionDirectory.appendingPathComponent("state.json"))
        for configuration in [development, dryRun] {
            let other = try TelemetryEngine(directory: configuration.storageDirectory(in: library), metadata: meta,
                                            configuration: configuration, transport: { try await stub.send($0) })
            await other.start(with: .init(counts: [:]), now: now)
            await other.flush(now: now)
            XCTAssertNotEqual(original.installID, other.installID)
            XCTAssertEqual(try Data(contentsOf: productionDirectory.appendingPathComponent("state.json")), originalState)
        }
        let resumed = try TelemetryEngine(directory: productionDirectory, metadata: meta, configuration: production,
                                         transport: { try await stub.send($0) })
        XCTAssertEqual(original.installID, resumed.installID)
        await resumed.start(with: .init(counts: [:]), now: now)
        await resumed.flush(now: now)
        let uploads = await stub.uploads().map { try! JSONDecoder().decode(TelemetryBatch.self, from: $0) }
        XCTAssertEqual(uploads.filter { $0.environment == .production }.count, 1)
        XCTAssertTrue(uploads.last!.events.contains { $0.event == .firstRun })
    }

    func testAttemptedSnapshotIsImmutableAcrossEditsAndRelaunch() async throws {
        let directory = try root(), stub = TelemetryStub()
        let start = Date(timeIntervalSince1970: 20734 * 86400 + 3600)
        let first = try engine(directory, stub: stub)
        await stub.configure(status: 503)
        await first.start(with: .init(counts: [.photo: 1]), now: start)
        await first.flush(now: start)
        let sent = try JSONDecoder().decode(TelemetryBatch.self, from: await stub.uploads()[0])
        await first.observe(.init(counts: [.photo: 9]), now: start.addingTimeInterval(60))
        let second = try engine(directory, stub: stub)
        await second.start(with: .init(counts: [.photo: 20]), now: start.addingTimeInterval(120))
        await stub.configure()
        await second.flush(now: start.addingTimeInterval(6 * 3600))
        let retry = try JSONDecoder().decode(TelemetryBatch.self, from: await stub.uploads()[1])
        XCTAssertEqual(retry.events, sent.events, "An accepted request with a lost response must retry the identical events")
        await second.observe(.init(counts: [.photo: 20]), now: start.addingTimeInterval(86400))
        let next = await second.pendingBatch()
        XCTAssertEqual(next.events.first { $0.event == .dailyConfiguration }?.configuration?.widgetCount, .twentyPlus)
    }

    func testOldAttemptedQueueMigratesWithoutChangingSnapshot() async throws {
        let directory = try root(), stub = TelemetryStub()
        let first = try engine(directory, stub: stub)
        await stub.configure(status: 503)
        await first.start(with: .init(counts: [.photo: 1]), now: now)
        await first.flush(now: now)
        let path = directory.appendingPathComponent("state.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        legacy.removeValue(forKey: "frozenEventIDs")
        try JSONSerialization.data(withJSONObject: legacy).write(to: path)
        let second = try engine(directory, stub: stub)
        await second.start(with: .init(counts: [.photo: 9]), now: now)
        let batch = await second.pendingBatch()
        XCTAssertEqual(batch.events.first { $0.event == .dailyConfiguration }?.configuration?.widgetCount, .one)
    }
}
