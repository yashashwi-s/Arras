import Foundation

/// A one-shot file download that reports progress.
///
/// `URLSession.download(from:)` returns nothing until the transfer completes, and
/// iterating `URLSession.bytes` a byte at a time costs one `await` per byte —
/// unusable for a multi-megabyte app bundle. The delegate API is the only route
/// that gives incremental progress at a sane cost.
final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Downloads `url` to `destination`, calling `onProgress` with 0...1.
    static func run(
        url: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let task = DownloadTask(destination: destination, onProgress: onProgress)
        try await task.start(url: url)
    }

    private func start(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        // Without this the session retains us forever and the process never
        // releases the connection.
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes this file the moment we return, so the move has to
        // happen here rather than back on the calling task.
        let result: Result<Void, Error>
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw Updater.UpdateError.message("The download failed (HTTP \(response.statusCode)).")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch {
            result = .failure(error)
        }

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is resumed in didFinishDownloadingTo; this only catches failures.
        guard let error else { return }
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }
}

