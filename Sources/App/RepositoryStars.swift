import Foundation

struct RepositoryStarsHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

enum RepositoryStarsError: Error { case invalidResponse, oversizedResponse }

private final class RepositoryStarsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A public metadata read, with no account, cookies, credentials or disk cache.
func fetchRepositoryStarsResponse(_ request: URLRequest,
                                  configuration: URLSessionConfiguration = .ephemeral) async throws -> RepositoryStarsHTTPResponse {
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration, delegate: RepositoryStarsRedirectPolicy(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw RepositoryStarsError.invalidResponse }
    var data = Data()
    for try await byte in bytes {
        guard data.count < RepositoryStarsStore.maximumResponseBytes else { throw RepositoryStarsError.oversizedResponse }
        data.append(byte)
    }
    return RepositoryStarsHTTPResponse(status: response.statusCode, data: data)
}

/// Preferences asks on appearance. This actor never starts a timer or writes to
/// the photo library; concurrent appearances share one bounded metadata request.
actor RepositoryStarsStore {
    typealias Transport = @Sendable (URLRequest) async throws -> RepositoryStarsHTTPResponse
    static let shared = RepositoryStarsStore()
    static let maximumResponseBytes = 65_536
    private static let cacheLifetime: TimeInterval = 3600
    private struct Cache {
        let checked: Date
        let count: Int?
    }
    private struct Metadata: Decodable { let stargazers_count: Int }
    private let transport: Transport
    private var cache: Cache?
    private var inFlight: Task<Int?, Never>?

    init(transport: @escaping Transport = { try await fetchRepositoryStarsResponse($0) }) {
        self.transport = transport
    }

    func count(now: Date = Date()) async -> Int? {
        guard !Task.isCancelled else { return nil }
        if let inFlight { return await inFlight.value }
        if let cache {
            let age = now.timeIntervalSince(cache.checked)
            if age >= 0 && age < Self.cacheLifetime { return cache.count }
        }
        let transport = transport
        let task = Task<Int?, Never> {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos\(Constants.repositoryURL.path)")!,
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Arras-GitHub/1", forHTTPHeaderField: "User-Agent")
            request.setValue("en", forHTTPHeaderField: "Accept-Language")
            guard let response = try? await transport(request), response.status == 200,
                  response.data.count <= Self.maximumResponseBytes,
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: response.data),
                  metadata.stargazers_count >= 0 else { return nil }
            return metadata.stargazers_count
        }
        inFlight = task
        let count = await task.value
        // Cache failures too: repeatedly opening Preferences must not hammer an
        // unavailable or rate-limited API. An unknown count leaves the link usable.
        cache = Cache(checked: now, count: count)
        inFlight = nil
        return count
    }
}
