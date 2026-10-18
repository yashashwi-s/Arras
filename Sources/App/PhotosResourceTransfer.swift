import Foundation

/// PhotoKit calls back on its own queue; cancellation can arrive on another one.
/// The lock protects the payload, terminal result, continuation and request cancellation.
final class PhotosResourceTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int64
    private var payload = Data()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelRequest: (@Sendable () -> Void)?
    private var needsCancellation = false

    private init(maxBytes: Int64) { self.maxBytes = maxBytes }

    static func read(
        maxBytes: Int64,
        start: (_ receive: @escaping @Sendable (Data) -> Void,
                _ finish: @escaping @Sendable (Error?) -> Void) -> (@Sendable () -> Void)
    ) async throws -> Data {
        guard maxBytes > 0 else { throw PhotosLibraryAssetExportError.sizeLimit(maxBytes) }
        let transfer = PhotosResourceTransfer(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard transfer.install(continuation) else { return }
                let cancel = start({ transfer.receive($0) }, { transfer.finish($0) })
                transfer.registerCancellation(cancel)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private func install(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
        let existing: Result<Data, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let existing { continuation.resume(with: existing); return false }
        return true
    }

    private func registerCancellation(_ cancel: @escaping @Sendable () -> Void) {
        let shouldCancel = lock.withLock {
            if needsCancellation { return true }
            if result == nil { cancelRequest = cancel }
            return false
        }
        if shouldCancel { cancel() }
    }

    private struct Completion {
        let result: Result<Data, Error>
        let continuation: CheckedContinuation<Data, Error>?
        let cancel: (@Sendable () -> Void)?
        func deliver() {
            // Neither PhotoKit nor the continuation is invoked while holding the lock.
            cancel?()
            continuation?.resume(with: result)
        }
    }

    private func completeLocked(_ value: Result<Data, Error>, abort: Bool = false) -> Completion? {
        guard result == nil else { return nil }
        result = value
        needsCancellation = abort
        let delivery = Completion(result: value, continuation: continuation, cancel: abort ? cancelRequest : nil)
        continuation = nil
        cancelRequest = nil
        payload = Data()
        return delivery
    }

    private func receive(_ data: Data) {
        let completion: Completion? = lock.withLock {
            guard result == nil else { return nil }
            guard Int64(payload.count) <= maxBytes - Int64(data.count) else {
                return completeLocked(.failure(PhotosLibraryAssetExportError.sizeLimit(maxBytes)), abort: true)
            }
            payload.append(data)
            return nil
        }
        completion?.deliver()
    }

    private func finish(_ error: Error?) {
        let completion: Completion? = lock.withLock {
            if let error {
                return completeLocked(.failure(PhotosLibraryAssetExportError.unavailable(error.localizedDescription)))
            }
            if payload.isEmpty { return completeLocked(.failure(PhotosLibraryAssetExportError.noResource)) }
            return completeLocked(.success(payload))
        }
        completion?.deliver()
    }

    private func cancel() {
        let completion = lock.withLock { completeLocked(.failure(CancellationError()), abort: true) }
        completion?.deliver()
    }
}
