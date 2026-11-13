import Foundation
import CryptoKit

enum ArchiveResourceLimits {
    static let archiveBytes = UInt64(UInt32.max)
    static let entryBytes: UInt64 = 512 * 1024 * 1024
    static let manifestBytes = 16 * 1024 * 1024
    static let fontBytes = 20_000_000
}

enum ArchiveIOError: LocalizedError {
    case tooLarge, tooManyEntries, invalidName, sourceChanged, couldNotCreate
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This backup exceeds the supported size (4 GB total or 512 MB per file). Export fewer widgets at a time."
        case .tooManyEntries: return "This backup contains too many files. Export fewer widgets at a time."
        case .invalidName: return "The backup contains an invalid or excessively long filename."
        case .sourceChanged: return "A stored file changed while the backup was being written. Try exporting again."
        case .couldNotCreate: return "The backup could not be created at that location."
        }
    }
}

/// Validate ZIP32 arithmetic without allocating payload-sized fixtures or truncating integers.
enum ZipSizePolicy {
    struct Entry {
        let nameBytes: Int
        let payloadBytes: UInt64
    }
    struct Layout {
        let offsets: [UInt32]
        let centralOffset: UInt32
        let centralSize: UInt32
        let totalBytes: UInt64
    }

    static func layout(_ entries: [Entry], maximumBytes: UInt64 = ArchiveResourceLimits.archiveBytes) throws -> Layout {
        guard entries.count <= Int(UInt16.max) else { throw ArchiveIOError.tooManyEntries }
        var offsets: [UInt32] = []
        var body: UInt64 = 0
        var central: UInt64 = 0
        func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow, sum <= ArchiveResourceLimits.archiveBytes else { throw ArchiveIOError.tooLarge }
            return sum
        }
        for entry in entries {
            guard entry.nameBytes > 0, entry.nameBytes <= Int(UInt16.max) else { throw ArchiveIOError.invalidName }
            guard entry.payloadBytes <= ArchiveResourceLimits.entryBytes else { throw ArchiveIOError.tooLarge }
            offsets.append(UInt32(body))
            body = try add(body, try add(UInt64(30 + entry.nameBytes + 16), entry.payloadBytes))
            central = try add(central, UInt64(46 + entry.nameBytes))
        }
        let total = try add(try add(body, central), 22)
        guard total <= maximumBytes, central <= UInt64(ArchiveResourceLimits.manifestBytes) else { throw ArchiveIOError.tooLarge }
        return Layout(offsets: offsets, centralOffset: UInt32(body), centralSize: UInt32(central), totalBytes: total)
    }
}

/// STORE-only ZIPs with streaming data descriptors. Older Arras readers already use the
/// central directory's sizes, so they also read these archives without a format migration.
struct SimpleZipWriter {
    private enum Payload {
        case data(Data)
        case file(URL, expectedSHA256: String?)
    }
    private struct Entry {
        let name: String
        let payload: Payload
    }
    private var entries: [Entry] = []

    mutating func addEntry(name: String, data: Data) { entries.append(Entry(name: name, payload: .data(data))) }
    mutating func addFile(name: String, url: URL, expectedSHA256: String? = nil) {
        entries.append(Entry(name: name, payload: .file(url, expectedSHA256: expectedSHA256)))
    }

    func write(to url: URL, maximumBytes: UInt64 = ArchiveResourceLimits.archiveBytes) throws {
        try Task.checkCancellation()
        let sizes = try entries.map { entry -> ZipSizePolicy.Entry in
            let size: UInt64
            switch entry.payload {
            case .data(let data): size = UInt64(data.count)
            case .file(let source, _):
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize, count >= 0 else {
                    throw ArchiveIOError.sourceChanged
                }
                size = UInt64(count)
            }
            return ZipSizePolicy.Entry(nameBytes: entry.name.utf8.count, payloadBytes: size)
        }
        let layout = try ZipSizePolicy.layout(sizes, maximumBytes: maximumBytes)
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? manager.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("backup.zip")
        guard manager.createFile(atPath: temporary.path, contents: nil) else { throw ArchiveIOError.couldNotCreate }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var central = Data()

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let name = Data(entry.name.utf8)
            var header = Data()
            header.appendUInt32LE(0x0403_4b50)
            header.appendUInt16LE(20)
            header.appendUInt16LE(0x0808) // UTF-8 name and trailing CRC/size descriptor.
            header.appendUInt16LE(0)
            header.appendUInt16LE(0)
            header.appendUInt16LE(0x21)
            header.appendUInt32LE(0); header.appendUInt32LE(0); header.appendUInt32LE(0)
            header.appendUInt16LE(UInt16(name.count)); header.appendUInt16LE(0)
            header.append(name)
            try output.write(contentsOf: header)
            var checksum = ZipCRC32()
            var hash = SHA256()
            var count: UInt64 = 0
            func consume(_ data: Data) throws {
                try Task.checkCancellation()
                count += UInt64(data.count)
                guard count <= sizes[index].payloadBytes else { throw ArchiveIOError.sourceChanged }
                checksum.update(data); hash.update(data: data)
                try output.write(contentsOf: data)
            }
            switch entry.payload {
            case .data(let data): try consume(data)
            case .file(let source, _):
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                while true {
                    let consumed = try autoreleasepool {
                        guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
                        try consume(chunk)
                        return true
                    }
                    if !consumed { break }
                }
            }
            guard count == sizes[index].payloadBytes else { throw ArchiveIOError.sourceChanged }
            if case .file(_, let expected?) = entry.payload {
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw ArchiveIOError.sourceChanged }
            }
            var descriptor = Data()
            descriptor.appendUInt32LE(0x0807_4b50); descriptor.appendUInt32LE(checksum.value)
            descriptor.appendUInt32LE(UInt32(count)); descriptor.appendUInt32LE(UInt32(count))
            try output.write(contentsOf: descriptor)

            central.appendUInt32LE(0x0201_4b50)
            central.appendUInt16LE(20); central.appendUInt16LE(20); central.appendUInt16LE(0x0808)
            central.appendUInt16LE(0); central.appendUInt16LE(0); central.appendUInt16LE(0x21)
            central.appendUInt32LE(checksum.value)
            central.appendUInt32LE(UInt32(count)); central.appendUInt32LE(UInt32(count))
            central.appendUInt16LE(UInt16(name.count))
            central.appendUInt16LE(0); central.appendUInt16LE(0); central.appendUInt16LE(0); central.appendUInt16LE(0)
            central.appendUInt32LE(0); central.appendUInt32LE(layout.offsets[index]); central.append(name)
        }
        try output.write(contentsOf: central)
        var end = Data()
        end.appendUInt32LE(0x0605_4b50); end.appendUInt16LE(0); end.appendUInt16LE(0)
        end.appendUInt16LE(UInt16(entries.count)); end.appendUInt16LE(UInt16(entries.count))
        end.appendUInt32LE(layout.centralSize); end.appendUInt32LE(layout.centralOffset); end.appendUInt16LE(0)
        try output.write(contentsOf: end)
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) }
        else { try manager.moveItem(at: temporary, to: url) }
    }
}

struct SimpleZipReader {
    private struct IndexedEntry {
        let localHeaderOffset: Int
        let compressedSize: Int
        let method: UInt16
        let flags: UInt16
        let checksum: UInt32
    }
    private enum Source {
        case data(Data)
        case file(FileSource)
        var count: Int {
            switch self { case .data(let data): return data.count; case .file(let file): return file.count }
        }
        func read(at offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else { throw LayoutArchiveError.notAZipFile }
            switch self {
            case .data(let data): return data.subdata(in: offset..<(offset + count))
            case .file(let file): return try file.read(at: offset, count: count)
            }
        }
    }
    private final class FileSource {
        let count: Int
        private let handle: FileHandle
        private let lock = NSLock()
        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            let size = try handle.seekToEnd()
            guard size <= ArchiveResourceLimits.archiveBytes else { throw ArchiveIOError.tooLarge }
            count = Int(size)
        }
        deinit { try? handle.close() }
        func read(at offset: Int, count: Int) throws -> Data {
            try lock.withLock {
                try handle.seek(toOffset: UInt64(offset))
                var data = Data()
                while data.count < count {
                    try Task.checkCancellation()
                    guard let chunk = try handle.read(upToCount: min(1024 * 1024, count - data.count)), !chunk.isEmpty else {
                        throw ArchiveIOError.sourceChanged
                    }
                    data.append(chunk)
                }
                return data
            }
        }
    }
    private let source: Source
    private let centralOffset: Int
    private var index: [String: IndexedEntry] = [:]

    static func read(from url: URL) throws -> Self {
        try Self(source: .file(FileSource(url)))
    }

    func entrySize(named name: String) -> Int? { index[name]?.compressedSize }

    init(data: Data) throws {
        guard UInt64(data.count) <= ArchiveResourceLimits.archiveBytes else { throw ArchiveIOError.tooLarge }
        try self.init(source: .data(Data(data)))
    }

    private init(source: Source) throws {
        self.source = source
        let tailOffset = max(0, source.count - 22 - 65535)
        let tail = try source.read(at: tailOffset, count: source.count - tailOffset)
        guard let end = Self.findEndOfCentralDirectory(in: tail) else { throw LayoutArchiveError.notAZipFile }
        let count = Int(tail.readUInt16LE(at: end + 10))
        guard tail.readUInt16LE(at: end + 4) == 0, tail.readUInt16LE(at: end + 6) == 0,
              Int(tail.readUInt16LE(at: end + 8)) == count else { throw LayoutArchiveError.notAZipFile }
        let centralSize = Int(tail.readUInt32LE(at: end + 12))
        let centralOffset = Int(tail.readUInt32LE(at: end + 16))
        guard centralOffset <= end + tailOffset, centralSize <= end + tailOffset - centralOffset else { throw LayoutArchiveError.notAZipFile }
        guard centralSize <= ArchiveResourceLimits.manifestBytes else { throw ArchiveIOError.tooLarge }
        self.centralOffset = centralOffset
        let bytes = try source.read(at: centralOffset, count: centralSize)
        let centralEnd = bytes.count
        var offset = 0
        for _ in 0..<count {
            guard offset + 46 <= centralEnd, bytes.readUInt32LE(at: offset) == 0x0201_4b50 else { throw LayoutArchiveError.notAZipFile }
            let method = bytes.readUInt16LE(at: offset + 10)
            let flags = bytes.readUInt16LE(at: offset + 8)
            let checksum = bytes.readUInt32LE(at: offset + 16)
            let size = Int(bytes.readUInt32LE(at: offset + 20))
            let expandedSize = Int(bytes.readUInt32LE(at: offset + 24))
            let nameLength = Int(bytes.readUInt16LE(at: offset + 28))
            let extraLength = Int(bytes.readUInt16LE(at: offset + 30))
            let commentLength = Int(bytes.readUInt16LE(at: offset + 32))
            let localOffset = Int(bytes.readUInt32LE(at: offset + 42))
            let start = offset + 46
            let next = start + nameLength + extraLength + commentLength
            guard next <= centralEnd, UInt64(size) <= ArchiveResourceLimits.entryBytes else { throw ArchiveIOError.tooLarge }
            guard nameLength > 0, let name = String(bytes: bytes[start..<(start + nameLength)], encoding: .utf8),
                  !name.contains("\0"), index[name] == nil, method != 0 || size == expandedSize else {
                throw LayoutArchiveError.notAZipFile
            }
            index[name] = IndexedEntry(localHeaderOffset: localOffset, compressedSize: size, method: method,
                                       flags: flags, checksum: checksum)
            offset = next
        }
        guard offset == centralEnd else { throw LayoutArchiveError.notAZipFile }
    }

    private func payloadRange(named name: String) throws -> (range: Range<Int>, checksum: UInt32)? {
        guard let entry = index[name], entry.method == 0, entry.flags & 1 == 0 else { return nil }
        let header = try source.read(at: entry.localHeaderOffset, count: 30)
        guard header.readUInt32LE(at: 0) == 0x0403_4b50,
              header.readUInt16LE(at: 6) == entry.flags,
              header.readUInt16LE(at: 8) == entry.method else { return nil }
        let nameLength = Int(header.readUInt16LE(at: 26))
        let extraLength = Int(header.readUInt16LE(at: 28))
        let start = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard start <= centralOffset, entry.compressedSize <= centralOffset - start else { return nil }
        let localName = try source.read(at: entry.localHeaderOffset + 30, count: nameLength)
        guard localName.elementsEqual(name.utf8) else { return nil }
        return (start..<(start + entry.compressedSize), entry.checksum)
    }

    func entryData(named name: String) -> Data? {
        guard let entry = try? payloadRange(named: name),
              let payload = try? source.read(at: entry.range.lowerBound, count: entry.range.count) else { return nil }
        var checksum = ZipCRC32()
        checksum.update(payload)
        return checksum.value == entry.checksum ? payload : nil
    }

    /// Extract a STORE entry to a fresh staging path. The reader verifies the
    /// bytes as they stream and removes partial output on any failure.
    func extractEntry(named name: String, to url: URL, record: ArchiveMediaRecord? = nil) throws {
        try Task.checkCancellation()
        guard let entry = try payloadRange(named: name),
              record.map({ $0.byteCount == entry.range.count }) ?? true else { throw LayoutArchiveError.notAZipFile }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path),
              manager.createFile(atPath: url.path, contents: nil) else { throw ArchiveIOError.couldNotCreate }
        var complete = false
        defer { if !complete { try? manager.removeItem(at: url) } }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var checksum = ZipCRC32()
        var hash = SHA256()
        var offset = entry.range.lowerBound
        while offset < entry.range.upperBound {
            try Task.checkCancellation()
            // Foundation can retain autoreleased file buffers until the enclosing task finishes.
            try autoreleasepool {
                let chunk = try source.read(at: offset, count: min(1024 * 1024, entry.range.upperBound - offset))
                checksum.update(chunk)
                if record != nil { hash.update(data: chunk) }
                try output.write(contentsOf: chunk)
                offset += chunk.count
            }
        }
        guard checksum.value == entry.checksum else { throw LayoutArchiveError.notAZipFile }
        if let record {
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == record.sha256 else { throw LayoutArchiveError.notAZipFile }
        }
        try Task.checkCancellation()
        try output.close()
        complete = true
    }

    private static func findEndOfCentralDirectory(in bytes: Data) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let floor = max(0, bytes.count - 22 - 65535)
        var offset = bytes.count - 22
        while offset >= floor {
            if bytes.readUInt32LE(at: offset) == 0x0605_4b50,
               offset + 22 + Int(bytes.readUInt16LE(at: offset + 20)) == bytes.count { return offset }
            offset -= 1
        }
        return nil
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
    }
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff))
    }
    func readUInt16LE(at offset: Int) -> UInt16 { UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8) }
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}

private struct ZipCRC32 {
    private var state: UInt32 = 0xffff_ffff
    var value: UInt32 { state ^ 0xffff_ffff }
    private static let table: [UInt32] = (0...255).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 != 0) ? (0xedb8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    mutating func update(_ data: Data) {
        for byte in data { state = Self.table[Int((state ^ UInt32(byte)) & 0xff)] ^ (state >> 8) }
    }
}
