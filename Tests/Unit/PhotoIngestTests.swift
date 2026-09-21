import AppKit
import XCTest
@testable import Arras

final class PhotoIngestTests: XCTestCase {
    func testOversizedTransparentPNGIsDownsampledAsPNG() throws {
        let source = try pngImageData(width: 3000, height: 2, alpha: 0)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let prepared = try XCTUnwrap(PhotoIngest.prepare(data: source, in: directory))

        XCTAssertEqual(prepared.url.pathExtension, "png")
        let stored = try Data(contentsOf: prepared.url)
        let image = try XCTUnwrap(NSBitmapImageRep(data: stored))
        XCTAssertTrue(try XCTUnwrap(image.cgImage).hasAlphaChannel)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(max(image.pixelsWide, image.pixelsHigh), 2560)
    }

    func testOversizedOpaqueImageIsDownsampledAsJPEG() throws {
        let bitmap = try makeBitmap(width: 3000, height: 2, alpha: nil)
        let source = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let prepared = try XCTUnwrap(PhotoIngest.prepare(data: source, in: directory))

        XCTAssertEqual(prepared.url.pathExtension, "jpg")
        let stored = try Data(contentsOf: prepared.url)
        XCTAssertNotNil(NSBitmapImageRep(data: stored))
    }

    @MainActor
    func testNSImageStillEncodingPreservesTransparencyButKeepsOpaqueJPEG() throws {
        let transparent = try makeImage(width: 16, height: 16, alpha: 0)
        let opaque = try makeImage(width: 16, height: 16, alpha: nil)

        let transparentResult = try XCTUnwrap(PhotoManager.encodeImportedStill(transparent))
        XCTAssertEqual(transparentResult.fileExtension, "png")
        let storedTransparent = try XCTUnwrap(NSBitmapImageRep(data: transparentResult.data))
        XCTAssertTrue(try XCTUnwrap(storedTransparent.cgImage).hasAlphaChannel)
        XCTAssertEqual(try XCTUnwrap(storedTransparent.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)

        let opaqueResult = try XCTUnwrap(PhotoManager.encodeImportedStill(opaque))
        XCTAssertEqual(opaqueResult.fileExtension, "jpg")
    }

    private func pngImageData(width: Int, height: Int, alpha: UInt8) throws -> Data {
        let image = try makeBitmap(width: width, height: height, alpha: alpha)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func makeImage(width: Int, height: Int, alpha: UInt8?) throws -> NSImage {
        let bitmap = try makeBitmap(width: width, height: height, alpha: alpha)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func makeBitmap(width: Int, height: Int, alpha: UInt8?) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: alpha == nil ? 3 : 4,
            hasAlpha: alpha != nil,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let samples = alpha == nil ? 3 : 4
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * samples
                bytes[offset] = 255
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
                if let alpha { bytes[offset + 3] = alpha }
            }
        }
        return bitmap
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrasPhotoIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
