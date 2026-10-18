import Foundation
import XCTest
@testable import Arras

final class PhotosResourceTransferTests: XCTestCase {
    func testBackgroundCallbacksAssembleDataAndIgnoreRepeatedCompletion() async throws {
        let data = try await PhotosResourceTransfer.read(maxBytes: 6) { receive, finish in
            DispatchQueue.global().async {
                receive(Data([1, 2, 3]))
                receive(Data([4, 5, 6]))
                finish(nil)
                receive(Data([7]))
                finish(NSError(domain: "late", code: 1))
            }
            return { XCTFail("A completed request must not be cancelled") }
        }
        XCTAssertEqual(data, Data([1, 2, 3, 4, 5, 6]))
    }

    func testSynchronousOversizeCancelsAfterRequestRegistration() async {
        let cancelled = expectation(description: "oversize request cancelled")
        do {
            _ = try await PhotosResourceTransfer.read(maxBytes: 2) { receive, finish in
                receive(Data([1, 2, 3]))
                finish(nil)
                return { cancelled.fulfill() }
            }
            XCTFail("Oversize resource succeeded")
        } catch PhotosLibraryAssetExportError.sizeLimit(let limit) {
            XCTAssertEqual(limit, 2)
        } catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testTaskCancellationStopsPendingRequestWithoutWaitingForPhotoKit() async {
        let started = expectation(description: "request registered")
        let cancelled = expectation(description: "request cancelled")
        let task = Task {
            try await PhotosResourceTransfer.read(maxBytes: 1024) { receive, finish in
                receive(Data([1]))
                started.fulfill()
                return {
                    // PhotoKit may synchronously report completion during cancellation.
                    finish(NSError(domain: "cancelled", code: 1))
                    receive(Data([2]))
                    cancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCancellationRacingCompletionResolvesExactlyOnce() async throws {
        for _ in 0..<50 {
            let started = expectation(description: "racing request started")
            let task = Task {
                try await PhotosResourceTransfer.read(maxBytes: 1) { receive, finish in
                    started.fulfill()
                    DispatchQueue.global().async {
                        receive(Data([9]))
                        finish(nil)
                    }
                    return { finish(NSError(domain: "cancelled", code: 1)) }
                }
            }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            do { let result = try await task.value; XCTAssertEqual(result, Data([9])) }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testEmptyAndFailedDownloadsNeverReturnUsableMedia() async {
        for failed in [false, true] {
            do {
                _ = try await PhotosResourceTransfer.read(maxBytes: 1024) { receive, finish in
                    if failed { receive(Data([1])) }
                    finish(failed ? NSError(domain: "download", code: 1) : nil)
                    return {}
                }
                XCTFail("Empty or failed transfer succeeded")
            } catch { XCTAssertTrue(error is PhotosLibraryAssetExportError) }
        }
    }
}
