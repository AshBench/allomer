import Darwin
import Foundation

enum EPUBZipNormalizer {
    private static let localSignature: UInt32 = 0x0403_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50

    static func removeMimetypeExtraField(at archive: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        guard fileSize >= 52, fileSize <= 512 * 1024 * 1024 else { throw invalid() }

        let local = try read(input, at: 0, count: 30)
        guard uint32(local, 0) == localSignature else { throw invalid() }
        let nameLength = Int(uint16(local, 26))
        let extraLength = Int(uint16(local, 28))
        let name = try read(input, at: 30, count: nameLength)
        guard name == Data("mimetype".utf8) else { throw invalid() }
        if extraLength == 0 { return }

        let end = try endRecord(input, fileSize: fileSize)
        let centralOffset = Int(uint32(end.data, 16))
        let centralSize = Int(uint32(end.data, 12))
        let entryCount = Int(uint16(end.data, 10))
        let skippedStart = 30 + nameLength
        let skippedEnd = skippedStart + extraLength
        guard entryCount > 0, entryCount <= 10_000, skippedEnd <= centralOffset,
              centralOffset + centralSize == end.offset else { throw invalid() }

        var central = try read(input, at: UInt64(centralOffset), count: centralSize)
        var cursor = 0
        for index in 0..<entryCount {
            guard cursor + 46 <= central.count, uint32(central, cursor) == centralSignature else { throw invalid() }
            let pathLength = Int(uint16(central, cursor + 28))
            let fieldLength = Int(uint16(central, cursor + 30))
            let commentLength = Int(uint16(central, cursor + 32))
            let recordLength = 46 + pathLength + fieldLength + commentLength
            guard cursor + recordLength <= central.count else { throw invalid() }
            let localOffset = Int(uint32(central, cursor + 42))
            if index == 0 {
                guard localOffset == 0,
                      central.subdata(in: cursor + 46..<cursor + 46 + pathLength) == name else { throw invalid() }
            } else {
                guard localOffset >= skippedEnd else { throw invalid() }
                setUInt32(UInt32(localOffset - extraLength), in: &central, at: cursor + 42)
            }
            cursor += recordLength
        }
        guard cursor == central.count else { throw invalid() }

        var finalRecord = end.data
        setUInt32(UInt32(centralOffset - extraLength), in: &finalRecord, at: 16)
        var header = local
        header[28] = 0
        header[29] = 0

        let temporary = archive.deletingLastPathComponent()
            .appendingPathComponent("epub-normalized-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: temporary) }
        }
        try output.write(contentsOf: header)
        try output.write(contentsOf: name)
        try copy(input, from: UInt64(skippedEnd), count: centralOffset - skippedEnd, to: output)
        try output.write(contentsOf: central)
        try output.write(contentsOf: finalRecord)
        try output.synchronize()
        try output.close()
        try input.close()
        guard try FileVersion(temporary).size == Int64(fileSize) - Int64(extraLength) else { throw invalid() }
        guard rename(temporary.path, archive.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        complete = true
    }

    private static func endRecord(_ input: FileHandle, fileSize: UInt64) throws -> (offset: Int, data: Data) {
        let length = Int(min(fileSize, 65_557))
        let start = Int(fileSize) - length
        let tail = try read(input, at: UInt64(start), count: length)
        guard tail.count >= 22 else { throw invalid() }
        for offset in stride(from: tail.count - 22, through: 0, by: -1) where uint32(tail, offset) == endSignature {
            let commentLength = Int(uint16(tail, offset + 20))
            if offset + 22 + commentLength == tail.count {
                return (start + offset, tail.subdata(in: offset..<tail.count))
            }
        }
        throw invalid()
    }

    private static func copy(_ input: FileHandle, from offset: UInt64, count: Int,
                             to output: FileHandle) throws {
        try input.seek(toOffset: offset)
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try input.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            guard !data.isEmpty else { throw invalid() }
            try output.write(contentsOf: data)
            remaining -= data.count
        }
    }

    private static func read(_ input: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw invalid() }
        try input.seek(toOffset: offset)
        let data = try input.read(upToCount: count) ?? Data()
        guard data.count == count else { throw invalid() }
        return data
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func setUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func invalid() -> ConversionError {
        .message("The EPUB ZIP structure could not be normalized.")
    }
}
