import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import Arras

final class VideoMediaTests: XCTestCase {
    func testLivePhotoModelCarriesStillAndPairedMovie() throws {
        let media = PhotoMedia(
            kind: .livePhoto,
            pairedVideoFilename: "paired.mov"
        )
        let decoded = try JSONDecoder().decode(PhotoMedia.self, from: JSONEncoder().encode(media))
        XCTAssertEqual(decoded.kind, .livePhoto)
        XCTAssertEqual(decoded.pairedVideoFilename, "paired.mov")
        XCTAssertNil(decoded.posterFilename)
        XCTAssertTrue(decoded.isMuted)
    }

    func testStandaloneVideoTracksGeneratedPosterAsTransformed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasVideoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("clip with spaces.mov")
        try writeSyntheticVideo(to: source)

        let prepared = try XCTUnwrap(PhotoIngest.prepareVideo(contentsOf: source, in: directory))
        let poster = try XCTUnwrap(prepared.media.posterFilename)

        XCTAssertEqual(prepared.mediaFidelityByFilename[prepared.filename], .sourceBytes)
        XCTAssertEqual(prepared.mediaFidelityByFilename[poster], .transformed)
        XCTAssertEqual(prepared.originalName, "clip with spaces")
        XCTAssertNotNil(PhotoContent.load(
            from: prepared.url,
            posterURL: prepared.posterURL,
            pairedVideoURL: nil
        ))
    }

    private func writeSyntheticVideo(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(bytes, 0x7f, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        input.markAsFinished()

        let completed = expectation(description: "video writer")
        writer.finishWriting { completed.fulfill() }
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video writer did not complete")
    }
}
