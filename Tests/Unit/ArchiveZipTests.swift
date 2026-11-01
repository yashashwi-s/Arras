import AppKit
import CryptoKit
import XCTest
@testable import Arras

final class ArchiveZipTests: XCTestCase {
    private func withFiles(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasZipTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testZipBoundsRejectOversizedCountsNamesPayloadsAndCombinedOffsetsWithoutAllocatingPayloads() throws {
        XCTAssertEqual(try ZipSizePolicy.layout([]).totalBytes, 22)
        let small = ZipSizePolicy.Entry(nameBytes: 1, payloadBytes: 9)
        let size = try ZipSizePolicy.layout([small]).totalBytes
        XCTAssertNoThrow(try ZipSizePolicy.layout([small], maximumBytes: size))
        XCTAssertThrowsError(try ZipSizePolicy.layout([small], maximumBytes: size - 1))
        XCTAssertThrowsError(try ZipSizePolicy.layout(Array(repeating: small, count: 65_536)))
        XCTAssertThrowsError(try ZipSizePolicy.layout([.init(nameBytes: 65_536, payloadBytes: 0)]))
        XCTAssertThrowsError(try ZipSizePolicy.layout([.init(nameBytes: -1, payloadBytes: 0)]))
        XCTAssertThrowsError(try ZipSizePolicy.layout([.init(nameBytes: 1, payloadBytes: UInt64.max)]))
        let video = ZipSizePolicy.Entry(nameBytes: 50, payloadBytes: ArchiveResourceLimits.entryBytes)
        XCTAssertThrowsError(try ZipSizePolicy.layout(Array(repeating: video, count: 9)))
        let longName = ZipSizePolicy.Entry(nameBytes: 65_535, payloadBytes: 0)
        XCTAssertThrowsError(try ZipSizePolicy.layout(Array(repeating: longName, count: 256)))
    }

    func testStreamingWriterPreservesFileBytesAndStandardCRC() throws {
        try withFiles { root in
            let source = root.appendingPathComponent("source")
            let payload = Data("123456789".utf8)
            try payload.write(to: source)
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let destination = root.appendingPathComponent("backup.arras")
            try Data("older backup".utf8).write(to: destination)
            var writer = SimpleZipWriter()
            writer.addFile(name: "images/sample", url: source, expectedSHA256: digest)
            let large = Data(repeating: 0xa5, count: 2 * 1024 * 1024 + 19)
            let largeSource = root.appendingPathComponent("large-source")
            try large.write(to: largeSource)
            writer.addFile(name: "images/large", url: largeSource,
                           expectedSHA256: SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined())
            writer.addEntry(name: "manifest.json", data: Data("manifest".utf8))
            try writer.write(to: destination)
            let reader = try SimpleZipReader.read(from: destination)
            XCTAssertEqual(reader.entryData(named: "images/sample"), payload)
            XCTAssertEqual(reader.entryData(named: "images/large"), large)
            XCTAssertEqual(reader.entryData(named: "manifest.json"), Data("manifest".utf8))
            let archive = try Data(contentsOf: destination)
            let central = Int(uint32(archive, archive.count - 6))
            XCTAssertEqual(uint32(archive, central), 0x0201_4b50)
            XCTAssertEqual(uint32(archive, central + 16), 0xcbf4_3926, "Standard CRC-32 check vector")
            // The public 2.5 reader uses this central size and local name/extra lengths,
            // so its existing STORE path also understands a trailing data descriptor.
            let local = Int(uint32(archive, central + 42))
            let start = local + 30 + Int(uint16(archive, local + 26)) + Int(uint16(archive, local + 28))
            let count = Int(uint32(archive, central + 20))
            XCTAssertEqual(archive.subdata(in: start..<(start + count)), payload)
        }
    }

    func testFileReaderFailsSafelyWhenSourceIsTruncatedAfterOpening() throws {
        try withFiles { root in
            var writer = SimpleZipWriter()
            writer.addEntry(name: "manifest.json", data: Data("sample".utf8))
            let destination = root.appendingPathComponent("backup.arras")
            try writer.write(to: destination)
            let reader = try SimpleZipReader.read(from: destination)
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: 0)
            try handle.close()
            XCTAssertNil(reader.entryData(named: "manifest.json"))
        }
    }

    func testFailedExportKeepsExistingDestination() throws {
        try withFiles { root in
            let source = root.appendingPathComponent("source")
            let before = Data("old file".utf8)
            try before.write(to: source)
            let destination = root.appendingPathComponent("backup.arras")
            let original = Data("existing backup".utf8)
            try original.write(to: destination)
            var writer = SimpleZipWriter()
            writer.addFile(name: "images/sample", url: source,
                           expectedSHA256: SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined())
            try Data("new file".utf8).write(to: source)
            XCTAssertThrowsError(try writer.write(to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertThrowsError(try writer.write(to: destination, maximumBytes: 1))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testReaderRejectsDamagedDirectoryAndOversizedEntryMetadata() throws {
        try withFiles { root in
            var writer = SimpleZipWriter()
            writer.addEntry(name: "manifest.json", data: Data("sample".utf8))
            let destination = root.appendingPathComponent("backup.arras")
            try writer.write(to: destination)
            let archive = try Data(contentsOf: destination)
            XCTAssertThrowsError(try SimpleZipReader(data: archive.dropLast()))
            let central = Int(uint32(archive, archive.count - 6))
            var oversized = archive
            oversized.replaceSubrange((central + 20)..<(central + 24), with: [255, 255, 255, 255])
            XCTAssertThrowsError(try SimpleZipReader(data: oversized))
            var damaged = archive
            damaged.replaceSubrange((archive.count - 10)..<(archive.count - 6), with: [255, 255, 255, 255])
            XCTAssertThrowsError(try SimpleZipReader(data: damaged))
        }
    }

    @MainActor
    func testBackgroundArchiveRoundTripCommitsOnlyWhenRequestedAndBalancesImportScopes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArrasBackgroundArchive-" + UUID().uuidString)
        let manager = PhotoManager(storageDirectory: root)
        defer {
            manager.windows.values.forEach { $0.hidePhoto() }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(manager.addStarterExample(.minimal, makeVisible: false))
        let original = manager.photos.map(\.id)
        let destination = root.appendingPathComponent("backup.arras")
        let report = try await manager.exportLayoutInBackground(to: destination)
        XCTAssertEqual(report.widgetCount, 1)
        XCTAssertFalse(manager.hasPendingMediaImport)
        let preflight = try await manager.preflightImportLayoutInBackground(from: destination)
        defer { preflight.cleanup() }
        XCTAssertEqual(manager.photos.map(\.id), original)
        XCTAssertEqual(preflight.candidates.count, 1)
        XCTAssertFalse(manager.hasPendingMediaImport)
        XCTAssertEqual(try manager.commitImport(preflight, selectedIDs: [0], mode: .merge), 1)
        XCTAssertEqual(manager.photos.count, 2)
        let existing = try Data(contentsOf: destination)
        let cancelled = Task { try await manager.exportLayoutInBackground(to: destination) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled export must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        XCTAssertFalse(manager.hasPendingMediaImport)
        do {
            _ = try await manager.preflightImportLayoutInBackground(from: root.appendingPathComponent("missing.arras"))
            XCTFail("Missing input must fail")
        } catch { XCTAssertFalse(manager.hasPendingMediaImport) }
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
