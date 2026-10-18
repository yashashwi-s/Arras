import Foundation
import XCTest
@testable import Arras

private actor StarsTransportStub {
    private var status = 200
    private var body = Data(#"{"stargazers_count":17}"#.utf8)
    private var failure: URLError.Code?
    private var delay = false
    private var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> RepositoryStarsHTTPResponse {
        requests.append(request)
        if delay { try await Task.sleep(for: .milliseconds(50)) }
        if let failure { throw URLError(failure) }
        return RepositoryStarsHTTPResponse(status: status, data: body)
    }
    func configure(status: Int = 200, body: String = #"{"stargazers_count":17}"#,
                   failure: URLError.Code? = nil, delay: Bool = false) {
        self.status = status; self.body = Data(body.utf8); self.failure = failure; self.delay = delay
    }
    func captured() -> [URLRequest] { requests }
}

private final class StarsResponseProtocol: URLProtocol {
    struct Fixture {
        let status: Int
        let body: Data
    }
    private static let lock = NSLock()
    private static var fixtures: [URL: Fixture] = [:]

    static func register(_ fixture: Fixture, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        fixtures[url] = fixture
    }
    static func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeValue(forKey: url)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = request.url.flatMap { Self.fixtures[$0] }
        Self.lock.unlock()
        guard let fixture, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RepositoryStarsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testOnDemandRequestsShareOneFlightAndCacheWithoutVisitorData() async throws {
        let stub = StarsTransportStub()
        await stub.configure(delay: true)
        let store = RepositoryStarsStore(transport: { try await stub.send($0) })
        let initial = await stub.captured()
        XCTAssertTrue(initial.isEmpty, "Creating the store must not perform a startup request")
        let values = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<20 { group.addTask { await store.count(now: self.now) } }
            var values: [Int?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 20)
        XCTAssertTrue(values.allSatisfy { $0 == 17 })
        let cached = await store.count(now: now.addingTimeInterval(3599))
        XCTAssertEqual(cached, 17)
        let requests = await stub.captured()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/yashashwi-s/Arras")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Arras-GitHub/1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testFailureIsCachedAndRecoversWithoutKeepingAnExpiredCount() async throws {
        let stub = StarsTransportStub(), store = RepositoryStarsStore(transport: { try await stub.send($0) })
        var value = await store.count(now: now)
        XCTAssertEqual(value, 17)
        await stub.configure(status: 429)
        value = await store.count(now: now.addingTimeInterval(3600))
        XCTAssertNil(value)
        await stub.configure(body: #"{"stargazers_count":18}"#)
        value = await store.count(now: now.addingTimeInterval(7199))
        XCTAssertNil(value, "A failure is cached instead of retrying each time the tab opens")
        var requests = await stub.captured()
        XCTAssertEqual(requests.count, 2)
        value = await store.count(now: now.addingTimeInterval(7200))
        XCTAssertEqual(value, 18)
        requests = await stub.captured()
        XCTAssertEqual(requests.count, 3)
    }

    func testRealZeroIsDisplayedButMalformedOrFailedResponsesHaveNoCount() async throws {
        for body in [#"{"stargazers_count":-1}"#, #"{"stargazers_count":"17"}"#,
                     #"{"stargazers_count":1.5}"#, #"{"stargazers_count":null}"#, "{}", "<html>unavailable</html>"] {
            let stub = StarsTransportStub(), store = RepositoryStarsStore(transport: { try await stub.send($0) })
            await stub.configure(body: body)
            let value = await store.count(now: now)
            XCTAssertNil(value, body)
        }
        let zero = RepositoryStarsStore(transport: { _ in
            RepositoryStarsHTTPResponse(status: 200, data: Data(#"{"stargazers_count":0}"#.utf8))
        })
        let zeroValue = await zero.count(now: now)
        XCTAssertEqual(zeroValue, 0)
        let timeout = RepositoryStarsStore(transport: { _ in throw URLError(.timedOut) })
        let unavailable = await timeout.count(now: now)
        XCTAssertNil(unavailable)
    }

    func testClockCorrectionRefreshesTheInMemoryCache() async throws {
        let stub = StarsTransportStub(), store = RepositoryStarsStore(transport: { try await stub.send($0) })
        _ = await store.count(now: now)
        await stub.configure(body: #"{"stargazers_count":19}"#)
        let value = await store.count(now: now.addingTimeInterval(-86400))
        XCTAssertEqual(value, 19)
        let requests = await stub.captured()
        XCTAssertEqual(requests.count, 2)
    }

    func testCancelledViewDoesNotCancelARequestSharedWithAnotherAppearance() async throws {
        let stub = StarsTransportStub()
        await stub.configure(delay: true)
        let store = RepositoryStarsStore(transport: { try await stub.send($0) })
        let owner = Task { await store.count(now: now) }
        while await stub.captured().isEmpty { await Task.yield() }
        owner.cancel()
        let value = await store.count(now: now)
        XCTAssertEqual(value, 17)
        _ = await owner.value
        let requests = await stub.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testNativeTransportBoundsTheResponseAndDisablesPersistentState() async throws {
        for size in [RepositoryStarsStore.maximumResponseBytes, RepositoryStarsStore.maximumResponseBytes + 1] {
            let url = URL(string: "https://stars-fixture.invalid/\(UUID().uuidString)")!
            StarsResponseProtocol.register(.init(status: 200, body: Data(repeating: 32, count: size)), for: url)
            defer { StarsResponseProtocol.remove(url) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StarsResponseProtocol.self]
            do {
                let response = try await fetchRepositoryStarsResponse(URLRequest(url: url), configuration: config)
                XCTAssertEqual(size, RepositoryStarsStore.maximumResponseBytes)
                XCTAssertEqual(response.data.count, size)
            } catch {
                guard case RepositoryStarsError.oversizedResponse = error else { throw error }
                XCTAssertGreaterThan(size, RepositoryStarsStore.maximumResponseBytes)
            }
            XCTAssertNil(config.httpCookieStorage)
            XCTAssertNil(config.urlCredentialStorage)
            XCTAssertNil(config.urlCache)
        }
    }
}
