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

    @MainActor
    func testVideoClockAdvancesWithDockHelperAndResumesAfterRealCoverage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasPlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.mov")
        try writeSyntheticVideo(to: url, frames: 90)
        let poster = try XCTUnwrap(VideoMediaSupport.posterImage(for: url))
        let surface = PhotoImageLayer()
        surface.apply(.video(VideoPlaybackContent(url: url, poster: poster, pairedVideoURL: nil)))
        defer { surface.releaseVideoResources() }
        let player = try XCTUnwrap(surface.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first?.player)
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let content = CGRect(x: 400, y: 300, width: 240, height: 160)
        let target = CoverageWindow(id: 100, bounds: content, layer: WidgetDepth.floating.windowLevel.rawValue, alpha: 1)
        let helper = CoverageWindow(id: 17, bounds: display, layer: 20, alpha: 1, ownerPID: 500)
        let cover = CoverageWindow(id: 18, bounds: content, layer: target.layer + 1, alpha: 1, ownerPID: 600)
        func applyCoverage(_ windows: [CoverageWindow], environment: RuntimeActivityEnvironment = RuntimeActivityEnvironment()) {
            let covered = WindowCoveragePolicy.isCovered(windowID: target.id, contentBounds: content,
                windows: windows, dockPIDs: [500], displayBounds: [display])
            let decision = RuntimeActivityPolicy.decision(for: RuntimeActivityInput(isOccluded: covered, environment: environment))
            surface.setPlaybackEnabled(decision.allowsExpensiveAnimation)
        }
        func waitForAdvance(from time: Double) {
            let deadline = Date().addingTimeInterval(5)
            while player.currentTime().seconds <= time + 0.1 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
            XCTAssertGreaterThan(player.currentTime().seconds, time + 0.1,
                                 "AVPlayer's clock must advance, not just report a playing label")
        }

        // Both normal and Floating targets must survive the reported shell helper.
        // The real AVPlayer clock below covers video, beyond the existing slideshow policy checks.
        applyCoverage([helper, target])
        XCTAssertEqual(surface.videoPlaybackStatus, .playing)
        XCTAssertTrue(player.isMuted)
        waitForAdvance(from: 0)
        applyCoverage([helper, cover, target])
        XCTAssertEqual(surface.videoPlaybackStatus, .paused)
        XCTAssertEqual(player.rate, 0)
        let paused = player.currentTime().seconds
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.05)
        applyCoverage([helper, target])
        XCTAssertEqual(surface.videoPlaybackStatus, .playing)
        waitForAdvance(from: paused)

        var conserving = RuntimeActivityEnvironment()
        conserving.isLowPowerModeEnabled = true
        applyCoverage([helper, target], environment: conserving)
        XCTAssertEqual(surface.videoPlaybackStatus, .paused, "The Dock fix must retain energy policy")
        applyCoverage([helper, target])
        waitForAdvance(from: player.currentTime().seconds)
    }

    private func writeSyntheticVideo(to url: URL, frames: Int = 1) throws {
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
        for frame in 0..<frames {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()

        let completed = expectation(description: "video writer")
        writer.finishWriting { completed.fulfill() }
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Video writer did not complete")
    }
}
