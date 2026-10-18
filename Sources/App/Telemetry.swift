import Foundation

// The wire types deliberately cannot contain PhotoItem, URLs, media or user text.
enum TelemetryWidgetType: String, Codable, CaseIterable, Sendable {
    case photo, animatedImage = "animated_image", video, slideshow, collage, container
    case linkedFolder = "linked_folder", photosCollection = "photos_collection", livePhoto = "live_photo"
}

enum TelemetryCount: String, Codable, Sendable {
    case zero = "0", one = "1", twoToFour = "2-4", fiveToNine = "5-9"
    case tenToNineteen = "10-19", twentyPlus = "20+"
    init(_ count: Int) {
        switch count {
        case ...0: self = .zero
        case 1: self = .one
        case 2...4: self = .twoToFour
        case 5...9: self = .fiveToNine
        case 10...19: self = .tenToNineteen
        default: self = .twentyPlus
        }
    }
}

struct TelemetryFacts: Equatable, Sendable {
    var counts: [TelemetryWidgetType: Int]
    var widgetCount: Int { counts.values.reduce(0, +) }
    var collageCount: Int { (counts[.collage] ?? 0) + (counts[.container] ?? 0) }
    var kinds: Set<TelemetryWidgetType> { Set(counts.filter { $0.value > 0 }.map(\.key)) }
    var snapshot: TelemetrySnapshot {
        TelemetrySnapshot(widgetCount: TelemetryCount(widgetCount), collageCount: TelemetryCount(collageCount),
                          countsByType: Dictionary(uniqueKeysWithValues: TelemetryWidgetType.allCases.map {
                              ($0.rawValue, TelemetryCount(counts[$0] ?? 0))
                          }))
    }
}

struct TelemetrySnapshot: Codable, Equatable, Sendable {
    let widgetCount: TelemetryCount
    let collageCount: TelemetryCount
    let countsByType: [String: TelemetryCount]
    enum CodingKeys: String, CodingKey {
        case widgetCount = "widget_count", collageCount = "collage_count", countsByType = "counts_by_type"
    }
}

struct TelemetryMetadata: Sendable {
    let version: String
    let build: String
    let osVersion: String
    let architecture: String
    static func numericVersion(_ value: String) -> String {
        value.range(of: #"^\d{1,4}(\.\d{1,4}){0,3}$"#, options: .regularExpression) != nil ? value : "0"
    }
    static var current: Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Self(version: numericVersion(Constants.version),
                    build: numericVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"),
                    osVersion: "\(os.majorVersion).\(os.minorVersion)", architecture: architecture)
    }
}

enum TelemetryEventType: String, Codable, Sendable {
    case firstRun = "first_run", appUpdated = "app_updated", firstWidgetCreated = "first_widget_created"
    case firstCollageCreated = "first_collage_created", firstFeatureUsed = "first_feature_used"
    case dailyConfiguration = "daily_configuration"
}

struct TelemetryEvent: Codable, Equatable, Sendable {
    let eventID: UUID
    let event: TelemetryEventType
    let day: Int // UTC epoch day, never an interaction timestamp.
    let appVersion: String
    let build: String
    let osVersion: String
    let architecture: String
    var existingConfiguration: Bool?
    var previousVersion: String?
    var widgetType: TelemetryWidgetType?
    var configuration: TelemetrySnapshot?
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", event, day, appVersion = "app_version", build, osVersion = "os_version", architecture
        case existingConfiguration = "existing_configuration", previousVersion = "previous_version"
        case widgetType = "widget_type", configuration
    }
    init(_ event: TelemetryEventType, day: Int, metadata: TelemetryMetadata, eventID: UUID = UUID()) {
        self.eventID = eventID; self.event = event; self.day = day
        appVersion = TelemetryMetadata.numericVersion(metadata.version)
        build = TelemetryMetadata.numericVersion(metadata.build)
        osVersion = TelemetryMetadata.numericVersion(metadata.osVersion)
        architecture = metadata.architecture == "arm64" ? "arm64" : "x86_64"
    }
}

struct TelemetryBatch: Codable, Sendable {
    enum Environment: String, Codable, Sendable { case production, development }
    let schemaVersion: Int
    let environment: Environment
    let installID: UUID
    let events: [TelemetryEvent]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", environment, installID = "install_id", events
    }
}

struct TelemetryHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

struct TelemetryConfiguration: Sendable {
    enum Cadence: Int, Sendable {
        case daily = 1, weekly = 7

        func period(for day: Int) -> Int {
            self == .daily ? day : day - (day + 1) % 7 // Wednesday UTC; first launch still reports promptly.
        }
    }
    static let intendedEndpoint = "https://tryarras.tech/api/telemetry/v1"
    let endpoint: URL
    let environment: TelemetryBatch.Environment
    let dryRun: Bool
    let cadence: Cadence

    init(endpoint: URL, environment: TelemetryBatch.Environment, dryRun: Bool, cadence: Cadence = .daily) {
        self.endpoint = endpoint; self.environment = environment; self.dryRun = dryRun; self.cadence = cadence
    }

    /// Production keeps its historical identity. Development and local inspection
    /// must never acknowledge or consume production milestones.
    func storageDirectory(in library: URL) -> URL {
        let name = dryRun ? "TelemetryDryRun" : (environment == .production ? "Telemetry" : "TelemetryDevelopment")
        return library.appendingPathComponent(name, isDirectory: true)
    }

    static func validatedCadence(_ value: Any?) -> Cadence? {
        guard let value else { return .daily }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return Cadence(rawValue: number.intValue)
    }

    static func validatedEndpoint(_ value: String, allowLocal: Bool = false) -> URL? {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, !host.isEmpty else { return nil }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(host)
        guard parts.scheme == "https" || (allowLocal && loopback && parts.scheme == "http") else { return nil }
        return url
    }

    static var current: Self? {
        #if DEBUG
        if let local = ProcessInfo.processInfo.environment["ARRAS_TELEMETRY_LOCAL_URL"],
           let endpoint = validatedEndpoint(local, allowLocal: true),
           ["127.0.0.1", "localhost", "::1"].contains(endpoint.host ?? "") {
            return Self(endpoint: endpoint, environment: .development, dryRun: false)
        }
        return Self(endpoint: URL(string: intendedEndpoint)!, environment: .development, dryRun: true)
        #else
        guard Bundle.main.object(forInfoDictionaryKey: "ArrasTelemetryEnabled") as? Bool == true,
              let raw = Bundle.main.object(forInfoDictionaryKey: "ArrasTelemetryURL") as? String,
              let endpoint = validatedEndpoint(raw),
              let cadence = validatedCadence(Bundle.main.object(forInfoDictionaryKey: "ArrasTelemetryReportingDays")) else { return nil }
        return Self(endpoint: endpoint, environment: .production, dryRun: false, cadence: cadence)
        #endif
    }
}

/// No cookies, credentials, disk cache, redirects, device-specific user agent or
/// unbounded response body. Each request owns a short-lived ephemeral session.
final class TelemetryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum TelemetryTransportError: Error { case invalidResponse, oversizedResponse }

func sendTelemetryRequest(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 15
    let session = URLSession(configuration: config, delegate: TelemetryRedirectPolicy(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw TelemetryTransportError.invalidResponse }
    var data = Data()
    for try await byte in bytes {
        guard data.count < 4096 else { throw TelemetryTransportError.oversizedResponse }
        data.append(byte)
    }
    return TelemetryHTTPResponse(status: http.statusCode, data: data)
}

actor TelemetryEngine {
    typealias Transport = @Sendable (URLRequest) async throws -> TelemetryHTTPResponse
    static let maximumQueueSize = 32
    static let retryInterval: TimeInterval = 6 * 3600
    static let maximumAttemptsPerDay = 3
    static let maximumAgeDays = 7
    private static let maximumBackoffExponent = 5

    private struct State: Codable {
        var queue: [TelemetryEvent] = []
        var lastVersion: String?
        var firstWidget = false
        var firstCollage = false
        var features: Set<TelemetryWidgetType> = []
        var snapshotDay: Int?
        var successDay: Int?
        var attemptDay: Int?
        var attempts = 0
        var failedAttempts: Int?
        var nextAttempt: TimeInterval = 0
        var frozenEventIDs: Set<UUID>?
    }
    private var state: State
    private let stateURL: URL
    nonisolated let installID: UUID
    private let metadata: TelemetryMetadata
    private let configuration: TelemetryConfiguration
    private let transport: Transport
    private var inFlight = false
    private var storageFailed = false

    init(directory: URL, metadata: TelemetryMetadata, configuration: TelemetryConfiguration,
         transport: @escaping Transport = { try await sendTelemetryRequest($0) }) throws {
        self.metadata = metadata; self.configuration = configuration; self.transport = transport
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let identityURL = directory.appendingPathComponent("install-id")
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let raw = try String(contentsOf: identityURL, encoding: .utf8)
            guard let id = UUID(uuidString: raw) else { throw TelemetryTransportError.invalidResponse }
            installID = id
        } else {
            let id = UUID()
            try Data(id.uuidString.utf8).write(to: identityURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
            installID = id
        }
        stateURL = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            // A damaged telemetry store fails closed. It never touches photos.json
            // or silently resets milestones into another first-run event storm.
            let data = try Data(contentsOf: stateURL)
            guard data.count <= 65_536 else { throw TelemetryTransportError.oversizedResponse }
            state = try JSONDecoder().decode(State.self, from: data)
            guard state.queue.count <= Self.maximumQueueSize,
                  state.queue.allSatisfy(Self.validStoredEvent),
                  [state.snapshotDay, state.successDay, state.attemptDay].compactMap({ $0 }).allSatisfy(Self.validStoredDay),
                  (0...Self.maximumAttemptsPerDay).contains(state.attempts),
                  state.failedAttempts.map({ (0...(Self.maximumBackoffExponent + 1)).contains($0) }) ?? true,
                  state.nextAttempt.isFinite, state.nextAttempt >= 0,
                  state.lastVersion.map({ TelemetryMetadata.numericVersion($0) == $0 }) ?? true else {
                throw TelemetryTransportError.invalidResponse
            }
        } else { state = State() }
        // Older stores did not distinguish attempted records. Conservatively
        // freeze their queued events if any request has already been attempted.
        if state.frozenEventIDs == nil {
            state.frozenEventIDs = state.attemptDay == nil ? [] : Set(state.queue.map(\.eventID))
        }
    }

    private static func validStoredDay(_ day: Int) -> Bool {
        // Keep decoded days safe for week offsets and retention arithmetic.
        // Reject damage before start/flush can run; never reset the saved state.
        day >= 0 && day <= Int.max - Self.maximumAgeDays
    }

    private static func validStoredEvent(_ event: TelemetryEvent) -> Bool {
        guard [event.appVersion, event.build, event.osVersion].allSatisfy({ TelemetryMetadata.numericVersion($0) == $0 }),
              event.osVersion.range(of: #"^\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil,
              ["arm64", "x86_64"].contains(event.architecture), validStoredDay(event.day),
              event.previousVersion.map({ TelemetryMetadata.numericVersion($0) == $0 }) ?? true else { return false }
        if let snapshot = event.configuration,
           Set(snapshot.countsByType.keys) != Set(TelemetryWidgetType.allCases.map(\.rawValue)) { return false }
        switch event.event {
        case .firstRun: return event.existingConfiguration != nil && event.previousVersion == nil && event.widgetType == nil && event.configuration == nil
        case .appUpdated: return event.previousVersion != nil && event.existingConfiguration == nil && event.widgetType == nil && event.configuration == nil
        case .firstFeatureUsed: return event.widgetType != nil && event.existingConfiguration == nil && event.previousVersion == nil && event.configuration == nil
        case .dailyConfiguration: return event.configuration != nil && event.existingConfiguration == nil && event.previousVersion == nil && event.widgetType == nil
        case .firstWidgetCreated, .firstCollageCreated: return event.configuration == nil && event.existingConfiguration == nil && event.previousVersion == nil && event.widgetType == nil
        }
    }

    static func day(_ date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 86400)) }

    func start(with facts: TelemetryFacts, now: Date = Date()) {
        guard !storageFailed else { return }
        let day = Self.day(now)
        let version = TelemetryMetadata.numericVersion(metadata.version)
        if state.lastVersion == nil {
            var first = TelemetryEvent(.firstRun, day: day, metadata: metadata)
            first.existingConfiguration = facts.widgetCount > 0
            enqueue(first)
            // Existing configurations are adoption, not new first-use conversions.
            state.firstWidget = facts.widgetCount > 0
            state.firstCollage = facts.collageCount > 0
            state.features = facts.kinds
        } else if state.lastVersion != version {
            var update = TelemetryEvent(.appUpdated, day: day, metadata: metadata)
            update.previousVersion = state.lastVersion.map(TelemetryMetadata.numericVersion)
            enqueue(update)
        }
        state.lastVersion = version
        observe(facts, now: now)
        save()
    }

    func observe(_ facts: TelemetryFacts, now: Date = Date()) {
        guard !storageFailed else { return }
        let day = Self.day(now)
        let period = configuration.cadence.period(for: day)
        let previous = state.queue
        let frozenIDs = state.frozenEventIDs ?? []
        let oldSnapshotDay = state.snapshotDay
        if facts.widgetCount > 0 && !state.firstWidget {
            enqueue(TelemetryEvent(.firstWidgetCreated, day: day, metadata: metadata)); state.firstWidget = true
        }
        if facts.collageCount > 0 && !state.firstCollage {
            enqueue(TelemetryEvent(.firstCollageCreated, day: day, metadata: metadata)); state.firstCollage = true
        }
        for kind in TelemetryWidgetType.allCases where facts.kinds.contains(kind) && !state.features.contains(kind) {
            var event = TelemetryEvent(.firstFeatureUsed, day: day, metadata: metadata)
            event.widgetType = kind; enqueue(event); state.features.insert(kind)
        }
        if let snapshotDay = state.snapshotDay, period == configuration.cadence.period(for: snapshotDay),
           let index = state.queue.lastIndex(where: { $0.event == .dailyConfiguration && configuration.cadence.period(for: $0.day) == period && !frozenIDs.contains($0.eventID) }) {
            // Until delivery begins, coalesce configuration changes into the same
            // daily record. This makes the first-use snapshot useful without
            // creating an event for every import or edit.
            var snapshot = TelemetryEvent(.dailyConfiguration, day: day, metadata: metadata, eventID: state.queue[index].eventID)
            snapshot.configuration = facts.snapshot
            state.queue[index] = snapshot
            // A future weekly build also coalesces daily records retained from an
            // older build in this period; it never sends seven daily snapshots.
            if configuration.cadence == .weekly {
                state.queue.removeAll { $0.event == .dailyConfiguration && configuration.cadence.period(for: $0.day) == period && $0.eventID != snapshot.eventID && !frozenIDs.contains($0.eventID) }
            }
        } else if state.snapshotDay.map({ period > configuration.cadence.period(for: $0) }) ?? true {
            var snapshot = TelemetryEvent(.dailyConfiguration, day: day, metadata: metadata)
            snapshot.configuration = facts.snapshot; enqueue(snapshot); state.snapshotDay = day
        }
        prune(day: day)
        if previous != state.queue || oldSnapshotDay != state.snapshotDay { save() }
    }

    private func enqueue(_ event: TelemetryEvent) {
        state.queue.append(event)
        if state.queue.count > Self.maximumQueueSize { state.queue.removeFirst(state.queue.count - Self.maximumQueueSize) }
    }
    private func prune(day: Int) {
        state.queue.removeAll { day - $0.day > Self.maximumAgeDays || $0.day > day + 1 }
    }
    private func save() {
        state.frozenEventIDs = (state.frozenEventIDs ?? []).intersection(Set(state.queue.map(\.eventID)))
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            storageFailed = true
            #if DEBUG
            NSLog("Arras telemetry paused: local telemetry state could not be saved.")
            #endif
        }
    }

    func pendingBatch() -> TelemetryBatch {
        TelemetryBatch(schemaVersion: 1, environment: configuration.environment, installID: installID, events: state.queue)
    }

    func flush(now: Date = Date()) async {
        let day = Self.day(now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard !storageFailed, !inFlight,
              state.successDay.map({ configuration.cadence.period(for: day) > configuration.cadence.period(for: $0) }) ?? true,
              now.timeIntervalSince1970 >= state.nextAttempt else { return }
        if state.attemptDay != day { state.attemptDay = day; state.attempts = 0 }
        prune(day: day)
        guard !state.queue.isEmpty, state.attempts < Self.maximumAttemptsPerDay,
              let payload = try? encoder.encode(pendingBatch()), payload.count <= 16_384 else { return }
        inFlight = true
        defer { inFlight = false }
        let ids = Set(state.queue.map(\.eventID))
        state.frozenEventIDs = (state.frozenEventIDs ?? []).union(ids)
        // Persist the attempt before suspending. A crash/relaunch cannot evade backoff.
        state.attemptDay = day; state.attempts += 1
        // Persist growing backoff before delivery so outages, quota exhaustion and
        // relaunches cannot leave every installation retrying four times a day.
        let failures = min(Self.maximumBackoffExponent, max(0, state.failedAttempts ?? 0))
        state.nextAttempt = now.timeIntervalSince1970 + min(7 * 86400, Self.retryInterval * pow(2, Double(failures)))
        state.failedAttempts = failures + 1
        save()
        guard !storageFailed else { return }
        #if DEBUG
        NSLog("Arras telemetry payload (\(configuration.dryRun ? "local inspection" : "development")): %@",
              String(data: payload, encoding: .utf8) ?? "")
        #endif
        if configuration.dryRun {
            acknowledge(ids, day: day)
            return
        }
        do {
            var control = request(method: "GET")
            control.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let switchResponse = try await transport(control)
            guard switchResponse.status == 200,
                  let object = try JSONSerialization.jsonObject(with: switchResponse.data) as? [String: Any],
                  Set(object.keys) == ["schema_version", "enabled"],
                  let control = try? JSONDecoder().decode(RemoteControl.self, from: switchResponse.data),
                  control.schema_version == 1 else { return }
            if !control.enabled {
                state.failedAttempts = 0
                // Remote disable discards queued data and waits a day before checking again.
                state.queue.removeAll(); state.nextAttempt = now.timeIntervalSince1970 + 86400; save()
                return
            }
            var upload = request(method: "POST")
            upload.httpBody = payload
            upload.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let response = try await transport(upload)
            if response.status == 204 {
                acknowledge(ids, day: day)
            } else if [400, 413, 415, 422].contains(response.status) {
                state.queue.removeAll { ids.contains($0.eventID) }; save()
            } else if response.status == 410 {
                state.failedAttempts = 0
                state.queue.removeAll(); state.nextAttempt = now.timeIntervalSince1970 + 86400; save()
            }
        } catch {
            // Deliberately omit localized errors: networking errors can include URLs
            // and system diagnostics. Failure has no path back into the app model.
            #if DEBUG
            NSLog("Arras telemetry delivery deferred.")
            #endif
        }
    }

    private struct RemoteControl: Decodable {
        let schema_version: Int
        let enabled: Bool
    }

    private func request(method: String) -> URLRequest {
        var request = URLRequest(url: configuration.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Arras-Telemetry/1", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func acknowledge(_ ids: Set<UUID>, day: Int) {
        state.queue.removeAll { ids.contains($0.eventID) }
        state.failedAttempts = 0
        // A successful delivery ends outage backoff. successDay still enforces
        // the daily/weekly limit, including after relaunch.
        state.nextAttempt = 0
        state.successDay = day; save()
    }
}
